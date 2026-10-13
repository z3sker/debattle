import AVFoundation
import Foundation

/// Bounded in-memory PCM copied from VoiceService's existing converted microphone
/// callback. Every instance belongs to exactly one server-authorized capture ticket.
/// It never owns a microphone and never uploads by itself.
final class CloudRoomAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pcm = Data()
    private var active = true
    private var failure: CloudRoomError?
    private let maximumFrames: Int

    init(maximumSeconds: Int) {
        maximumFrames = min(max(1, maximumSeconds), CloudRoomAPI.maximumAudioSeconds) * 24_000
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard active else { return }
            guard buffer.format.sampleRate == 24_000, buffer.format.channelCount == 1,
                  buffer.format.commonFormat == .pcmFormatFloat32, let samples = buffer.floatChannelData?[0] else {
                fail(.invalidResponse); return
            }
            let frames = Int(buffer.frameLength)
            guard frames <= maximumFrames - pcm.count / 2 else { fail(.tooLong); return }
            var chunk = Data(count: frames * 2)
            chunk.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                for index in 0..<frames {
                    let value = samples[index].isFinite ? samples[index] : 0
                    let signed = Int16(max(-32_768, min(32_767, Int((max(-1, min(1, value)) * 32_768).rounded()))))
                    let bits = UInt16(bitPattern: signed)
                    bytes[index * 2] = UInt8(truncatingIfNeeded: bits)
                    bytes[index * 2 + 1] = UInt8(truncatingIfNeeded: bits >> 8)
                }
            }
            pcm.append(chunk)
        }
    }

    func finish() throws -> Data {
        try lock.withLock {
            active = false
            defer { pcm = Data() }
            if let failure { throw failure }
            guard !pcm.isEmpty else { throw CloudRoomError.noAudio }
            var wav = Data()
            wav.reserveCapacity(pcm.count + 44)
            func word(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) } }
            func dword(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) } }
            wav.append(contentsOf: "RIFF".utf8); dword(UInt32(pcm.count + 36))
            wav.append(contentsOf: "WAVEfmt ".utf8); dword(16)
            word(1); word(1); dword(24_000); dword(48_000); word(2); word(16)
            wav.append(contentsOf: "data".utf8); dword(UInt32(pcm.count)); wav.append(pcm)
            return wav
        }
    }

    func cancel() { lock.withLock { active = false; pcm = Data(); failure = nil } }
    private func fail(_ error: CloudRoomError) { active = false; pcm = Data(); failure = error }
}
