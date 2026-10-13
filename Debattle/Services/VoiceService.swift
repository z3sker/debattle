import AVFoundation
import Foundation
import Observation

enum VoiceError: LocalizedError {
    case microphoneDenied
    case noInput
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is off. Enable it for Debattle in Settings to speak."
        case .noInput: "No microphone is available. Connect an audio input and try again."
        case .unsupportedFormat: "This audio route does not support live voice. Try the built-in microphone or headphones."
        }
    }
}

/// The negotiated transport uses mono PCM16 little-endian at 24 kHz. Network framing,
/// speaker authorization and reconnects belong to the room connection, not the audio engine.
@MainActor @Observable
final class VoiceService {
    private(set) var isConnected = false
    private(set) var isMicrophoneEnabled = false
    private(set) var level: Float = 0
    private(set) var errorMessage: String?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioPlayerNode?
    @ObservationIgnored private var capture: VoiceCapturePipeline?
    @ObservationIgnored private var hasInputTap = false
    @ObservationIgnored private var queuedFrames = 0
    @ObservationIgnored private var playbackGeneration = UUID()
    @ObservationIgnored private var operationGeneration = UUID()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var audioHandler: (@Sendable (Data) -> Void)?
    @ObservationIgnored private var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    @ObservationIgnored private let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false
    )!

    func startReceiving() async throws {
        guard !isConnected else { return }
        errorMessage = nil
        do {
            let session = AVAudioSession.sharedInstance()
            // Listeners use a playback-only session; joining a room does not open input.
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setPreferredSampleRate(24_000)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: wireFormat)
            self.engine = engine
            self.player = player
            engine.prepare()
            try engine.start()
            player.play()
            isConnected = true
            installObservers()
        } catch {
            stop()
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// The buffer callback executes on a serial audio processing queue, never the render thread.
    /// The buffer is valid only during the callback; append it synchronously to a speech request.
    func startMicrophone(
        onAudio: @escaping @Sendable (Data) -> Void,
        onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil
    ) async throws {
        audioHandler = onAudio
        bufferHandler = onBuffer
        try await setMicrophoneEnabled(true)
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard enabled else {
            operationGeneration = UUID()
            capture?.setEnabled(false)
            isMicrophoneEnabled = false
            level = 0
            if hasInputTap, let engine {
                do {
                    engine.inputNode.removeTap(onBus: 0)
                    hasInputTap = false
                    engine.stop()
                    capture = nil
                    try engine.inputNode.setVoiceProcessingEnabled(false)
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                    try engine.start()
                    player?.play()
                } catch {
                    stop()
                    errorMessage = "Playback could not resume after muting. Reconnect audio."
                    throw error
                }
            }
            return
        }
        guard !isMicrophoneEnabled else { return }
        let operation = UUID()
        operationGeneration = operation
        let permitted = await AVAudioApplication.requestRecordPermission()
        guard operationGeneration == operation else { throw CancellationError() }
        guard permitted else {
            errorMessage = VoiceError.microphoneDenied.localizedDescription
            throw VoiceError.microphoneDenied
        }
        do {
            if !isConnected { try await startReceiving() }
            guard operationGeneration == operation else { throw CancellationError() }
            guard let engine else { throw VoiceError.noInput }
            if !hasInputTap {
                // Voice processing performs acoustic echo cancellation. Configure it while stopped.
                engine.stop()
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat,
                                                                options: [.defaultToSpeaker, .allowBluetoothHFP])
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.inputNode.setVoiceProcessingEnabled(true)
                let inputFormat = engine.inputNode.outputFormat(forBus: 0)
                guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                    throw VoiceError.noInput
                }
                let pipeline = try VoiceCapturePipeline(inputFormat: inputFormat, outputFormat: wireFormat)
                pipeline.onAudio = audioHandler
                pipeline.onBuffer = bufferHandler
                pipeline.onLevel = { [weak self] value in
                    Task { @MainActor in
                        guard self?.isMicrophoneEnabled == true else { return }
                        self?.level = value
                    }
                }
                pipeline.setEnabled(true)
                capture = pipeline
                engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                    pipeline.enqueue(buffer)
                }
                hasInputTap = true
                engine.prepare()
                try engine.start()
                player?.play()
            } else {
                capture?.onAudio = audioHandler
                capture?.onBuffer = bufferHandler
                capture?.setEnabled(true)
            }
            isMicrophoneEnabled = true
            errorMessage = nil
        } catch {
            stop()
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func receiveAudio(_ data: Data) {
        guard isConnected, let player, !data.isEmpty,
              data.count.isMultiple(of: MemoryLayout<Int16>.size), data.count <= 16_384 else { return }
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard let buffer = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            for index in 0..<frameCount {
                let bits = raw.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self).littleEndian
                samples[index] = Float(Int16(bitPattern: bits)) / 32_768
            }
        }
        // Drop stale buffered voice if a slow connection builds over half a second of latency.
        if queuedFrames + frameCount > 12_000 {
            playbackGeneration = UUID()
            player.stop()
            queuedFrames = 0
            player.play()
        }
        let generation = playbackGeneration
        queuedFrames += frameCount
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation else { return }
                self.queuedFrames = max(0, self.queuedFrames - frameCount)
            }
        }
    }

    func stop() {
        operationGeneration = UUID()
        capture?.setEnabled(false)
        if hasInputTap { engine?.inputNode.removeTap(onBus: 0) }
        hasInputTap = false
        player?.stop()
        engine?.stop()
        capture = nil
        player = nil
        engine = nil
        playbackGeneration = UUID()
        queuedFrames = 0
        isConnected = false
        isMicrophoneEnabled = false
        level = 0
        audioHandler = nil
        bufferHandler = nil
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                self?.stop()
                self?.errorMessage = "Voice was interrupted. Reconnect audio when you are ready."
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                    || reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue else { return }
            Task { @MainActor in
                guard self?.isConnected == true else { return }
                self?.stop()
                self?.errorMessage = "Your audio device changed. Reconnect audio to use the new route."
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
                self?.errorMessage = "The audio service restarted. Reconnect audio to continue."
            }
        })
    }
}

/// A bounded pool keeps conversion, allocation, speech recognition and networking off
/// AVAudioEngine's render thread. The tap only tries the lock, copies into a preallocated
/// buffer, and submits it. If all eight buffers are busy, it drops audio instead of blocking.
private final class VoiceCapturePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.debattle.voice-conversion", qos: .userInitiated)
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private var pool: [CaptureBufferSlot]
    private var enabled = false
    private var generation = 0
    private var _onAudio: (@Sendable (Data) -> Void)?
    private var _onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    private var lastLevelUpdate: TimeInterval = 0

    var onAudio: (@Sendable (Data) -> Void)? {
        get { lock.withLock { _onAudio } }
        set { lock.withLock { _onAudio = newValue } }
    }
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { lock.withLock { _onBuffer } }
        set { lock.withLock { _onBuffer = newValue } }
    }

    init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) throws {
        guard inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw VoiceError.unsupportedFormat
        }
        self.converter = converter
        self.outputFormat = outputFormat
        pool = (0..<8).compactMap { _ in
            AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 8192).map(CaptureBufferSlot.init)
        }
        guard pool.count == 8 else { throw VoiceError.unsupportedFormat }
    }

    func setEnabled(_ value: Bool) {
        lock.withLock { enabled = value; generation += 1 }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard lock.try() else { return }
        guard enabled, let slot = pool.popLast() else { lock.unlock(); return }
        let currentGeneration = generation
        lock.unlock()
        let copy = slot.buffer
        guard buffer.frameLength <= copy.frameCapacity,
              let source = buffer.floatChannelData, let destination = copy.floatChannelData else {
            lock.withLock { pool.append(slot) }
            return
        }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(destination[channel], source[channel], Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }
        queue.async { [self, slot] in
            defer { lock.withLock { pool.append(slot) } }
            let copy = slot.buffer
            let callbacks = lock.withLock { () -> ((@Sendable (Data) -> Void)?, (@Sendable (AVAudioPCMBuffer) -> Void)?)? in
                guard enabled, generation == currentGeneration else { return nil }
                return (_onAudio, _onBuffer)
            }
            guard let callbacks else { return }
            let capacity = AVAudioFrameCount(ceil(Double(copy.frameLength) * outputFormat.sampleRate / copy.format.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            slot.resetConverterInput()
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                slot.converterInput(status: inputStatus)
            }
            guard status != .error, error == nil, output.frameLength > 0,
                  let samples = output.floatChannelData?[0] else { return }
            guard lock.withLock({ enabled && generation == currentGeneration }) else { return }
            callbacks.1?(output)
            callbacks.0?(VoicePCM16.encode(UnsafeBufferPointer(start: samples, count: Int(output.frameLength))))
            let now = Date.timeIntervalSinceReferenceDate
            if now - lastLevelUpdate >= 0.1 {
                var sum: Float = 0
                for index in 0..<Int(output.frameLength) { sum += samples[index] * samples[index] }
                onLevel?(min(1, sqrt(sum / Float(output.frameLength)) * 5))
                lastLevelUpdate = now
            }
        }
    }
}

/// Ownership moves from the pool to the tap to the serial conversion queue and back.
/// The buffer is never read or written by two owners simultaneously. This wrapper does
/// not make arbitrary AVAudioPCMBuffer sharing safe; it encodes this pool's lease contract.
private final class CaptureBufferSlot: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    private let inputLock = NSLock()
    private var suppliedToConverter = false

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func resetConverterInput() {
        inputLock.withLock { suppliedToConverter = false }
    }

    func converterInput(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        // Conversion runs off the realtime audio thread. Serialize this state explicitly
        // because AVAudioConverter's imported callback is @Sendable.
        inputLock.withLock {
            guard !suppliedToConverter else { status.pointee = .noDataNow; return nil }
            suppliedToConverter = true
            status.pointee = .haveData
            return buffer
        }
    }
}

/// Explicit little-endian conversion keeps the negotiated wire format independent
/// of the device architecture and halves Float32 transport bandwidth.
enum VoicePCM16 {
    static func encode(_ samples: UnsafeBufferPointer<Float>) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for (index, value) in samples.enumerated() {
                let finite = value.isFinite ? value : 0
                let sample = Int16(max(-32_768, min(32_767, Int((max(-1, min(1, finite)) * 32_768).rounded()))))
                let bits = UInt16(bitPattern: sample)
                bytes[index * 2] = UInt8(truncatingIfNeeded: bits)
                bytes[index * 2 + 1] = UInt8(truncatingIfNeeded: bits >> 8)
            }
        }
        return data
    }
}
