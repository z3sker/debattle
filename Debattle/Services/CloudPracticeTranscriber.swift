import AVFoundation
import Foundation
import Observation

/// Canonical RIFF/WAVE: PCM16 little-endian, mono, 24 kHz, a 44-byte header.
enum CloudPracticeWAV {
    static let sampleRate = 24_000
    static let maximumFrames = sampleRate * CloudPracticeAPI.maximumAudioSeconds

    static func encode(pcm: Data) throws -> Data {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { throw CloudPracticeError.noAudio }
        guard pcm.count <= maximumFrames * 2 else { throw CloudPracticeError.audioTooLong }
        var data = Data()
        data.reserveCapacity(44 + pcm.count)
        func word(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func dword(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); dword(UInt32(36 + pcm.count))
        data.append(contentsOf: "WAVEfmt ".utf8); dword(16)
        word(1); word(1); dword(UInt32(sampleRate)); dword(UInt32(sampleRate * 2)); word(2); word(16)
        data.append(contentsOf: "data".utf8); dword(UInt32(pcm.count)); data.append(pcm)
        return data
    }

    static func validate(_ data: Data) throws {
        guard data.count <= CloudPracticeAPI.maximumWAVBytes else { throw CloudPracticeError.audioTooLong }
        guard data.count > 44, data.count.isMultiple(of: 2) else { throw CloudPracticeError.invalidAudio }
        let header = [UInt8](data.prefix(44))
        func word(_ offset: Int) -> UInt16 { UInt16(header[offset]) | UInt16(header[offset + 1]) << 8 }
        func dword(_ offset: Int) -> UInt32 {
            UInt32(header[offset]) | UInt32(header[offset + 1]) << 8 | UInt32(header[offset + 2]) << 16 | UInt32(header[offset + 3]) << 24
        }
        guard Array(header[0..<4]) == Array("RIFF".utf8), Array(header[8..<16]) == Array("WAVEfmt ".utf8),
              Array(header[36..<40]) == Array("data".utf8), dword(4) == UInt32(data.count - 8),
              dword(16) == 16, word(20) == 1, word(22) == 1, dword(24) == UInt32(sampleRate),
              dword(28) == UInt32(sampleRate * 2), word(32) == 2, word(34) == 16,
              dword(40) == UInt32(data.count - 44) else { throw CloudPracticeError.invalidAudio }
    }
}

/// VoiceService invokes append on its serial conversion queue, never the realtime
/// audio thread. The lock exclusively owns recording state and PCM bytes; no audio
/// buffer escapes the callback and no recording is written to a file.
final class CloudPracticeAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pcm = Data()
    private var active = false
    private var generation = UUID()
    private var failure: CloudPracticeError?
    private let maximumFrames: Int

    init(maximumFrames: Int = CloudPracticeWAV.maximumFrames) {
        self.maximumFrames = min(max(1, maximumFrames), CloudPracticeWAV.maximumFrames)
    }

    func start(generation: UUID) {
        lock.withLock {
            self.generation = generation
            pcm = Data()
            failure = nil
            active = true
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) -> (UUID, CloudPracticeError)? {
        lock.withLock {
            guard active else { return nil }
            guard buffer.format.sampleRate == Double(CloudPracticeWAV.sampleRate), buffer.format.channelCount == 1,
                  buffer.format.commonFormat == .pcmFormatFloat32, let samples = buffer.floatChannelData?[0] else {
                return fail(.invalidAudio)
            }
            // The UI timer may finish slightly after its seven-minute deadline.
            // Retain exactly the allowed prefix instead of losing the entire speech.
            let frames = min(Int(buffer.frameLength), maximumFrames - pcm.count / 2)
            guard frames > 0 else { return nil }
            // Convert directly into bounded bytes; sanitize NaN/infinity before converting to Int.
            var chunk = Data(count: frames * 2)
            chunk.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                for index in 0..<frames {
                    let input = samples[index].isFinite ? samples[index] : 0
                    let sample = Int16(max(-32_768, min(32_767, Int((max(-1, min(1, input)) * 32_768).rounded()))))
                    let bits = UInt16(bitPattern: sample)
                    bytes[index * 2] = UInt8(truncatingIfNeeded: bits)
                    bytes[index * 2 + 1] = UInt8(truncatingIfNeeded: bits >> 8)
                }
            }
            pcm.append(chunk)
            return nil
        }
    }

    func finish() throws -> Data {
        try lock.withLock {
            active = false
            defer { pcm = Data() }
            if let failure { throw failure }
            return try CloudPracticeWAV.encode(pcm: pcm)
        }
    }

    func cancel() {
        lock.withLock { active = false; pcm = Data(); failure = nil; generation = UUID() }
    }

    private func fail(_ error: CloudPracticeError) -> (UUID, CloudPracticeError) {
        active = false
        pcm = Data()
        failure = error
        return (generation, error)
    }
}

/// Collects local microphone samples. Only explicit finish() may upload; cancel()
/// discards the recording and cancels an in-flight upload without publishing a result.
@MainActor @Observable
final class CloudPracticeTranscriber: PracticeTranscribing {
    let usesCloudProcessing = true
    private(set) var partialText = ""
    private(set) var isRecording = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let api: CloudPracticeAPI
    @ObservationIgnored private nonisolated let audio = CloudPracticeAudioBuffer()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var language = "en"
    @ObservationIgnored private var uploadTask: Task<String, Error>?

    init(api: CloudPracticeAPI) { self.api = api }

    func start(language: String) async throws {
        cancel()
        try Task.checkCancellation()
        self.language = try CloudPracticeAPI.languageCode(language)
        partialText = ""
        errorMessage = nil
        let attempt = UUID()
        generation = attempt
        audio.start(generation: attempt)
        isRecording = true
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        guard let (attempt, error) = audio.append(buffer) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.generation == attempt else { return }
            self.errorMessage = error.localizedDescription
            self.isRecording = false
        }
    }

    func finish() async -> String {
        guard !Task.isCancelled else { cancel(); return "" }
        let attempt = generation
        let task: Task<String, Error>
        if let pending = uploadTask {
            task = pending
        } else {
            guard isRecording else { return partialText }
            isRecording = false
            do {
                let wav = try audio.finish()
                let api = api, language = language
                task = Task { try Task.checkCancellation(); return try await api.transcribe(wav: wav, language: language) }
                uploadTask = task
            } catch {
                errorMessage = error.localizedDescription
                return ""
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard generation == attempt, !Task.isCancelled else { return "" }
            uploadTask = nil
            guard !result.isEmpty else { errorMessage = "No speech was recognized. Try again or paste your transcript."; return "" }
            partialText = result
            return result
        } catch {
            guard generation == attempt else { return "" }
            uploadTask = nil
            if !(error is CancellationError), !Task.isCancelled { errorMessage = error.localizedDescription }
            return ""
        }
    }

    func cancel() {
        generation = UUID()
        audio.cancel()
        uploadTask?.cancel()
        uploadTask = nil
        isRecording = false
    }
}
