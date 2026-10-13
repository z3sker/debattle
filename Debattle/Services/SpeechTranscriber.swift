import AVFoundation
import Foundation
import Observation
import Speech
import OSLog

/// A current device capability snapshot, separate from permission to record.
/// Language support is queried from Speech, not inferred from Apple Intelligence.
enum SpeechCapability: Equatable, Sendable {
    case available
    case unsupportedLanguage(String)
    case onDeviceUnavailable(String)
    case temporarilyUnavailable(String)

    var isAvailable: Bool { self == .available }

    var message: String {
        switch self {
        case .available:
            "This device reports support for on-device transcription. Recording can still fail when the speech service starts. Microphone and speech permissions are checked when you start."
        case .unsupportedLanguage(let language):
            "Apple's speech recognizer does not support \(language) in this device configuration. You can still debate by voice in this language or paste a speech in Practice."
        case .onDeviceUnavailable(let language):
            "On-device transcription for \(language) is not available in this device configuration. You can still debate by voice or paste a speech in Practice. Debattle does not use cloud transcription."
        case .temporarilyUnavailable(let language):
            "The speech service for \(language) is temporarily unavailable. Try again later, or paste a speech in Practice. Voice debates still work; Debattle does not use cloud transcription."
        }
    }

    var error: TranscriptionError? {
        switch self {
        case .available: nil
        case .unsupportedLanguage(let language): .unsupportedLanguage(language)
        case .onDeviceUnavailable(let language): .onDeviceUnavailable(language)
        case .temporarilyUnavailable(let language): .temporarilyUnavailable(language)
        }
    }

    /// Pure classification permits tests without querying a device's speech assets.
    static func classify(language: String, localeSupported: Bool = true, recognizerExists: Bool,
                         supportsOnDeviceRecognition: Bool, isAvailable: Bool) -> SpeechCapability {
        guard localeSupported, recognizerExists else { return .unsupportedLanguage(language) }
        guard supportsOnDeviceRecognition else { return .onDeviceUnavailable(language) }
        guard isAvailable else { return .temporarilyUnavailable(language) }
        return .available
    }

    static func supportsLocale(_ requestedIdentifier: String, in supportedIdentifiers: Set<String>) -> Bool {
        // Normalize BCP-47/ICU separators without dropping region/script information.
        // Accepting merely the same language could select the wrong regional recognizer.
        func normalized(_ value: String) -> String {
            value.replacingOccurrences(of: "_", with: "-").lowercased()
        }
        let requested = normalized(requestedIdentifier)
        return supportedIdentifiers.contains { normalized($0) == requested }
    }
}

/// A bounded diagnostic that never includes a framework error's description or userInfo.
enum SpeechFailureDiagnostic {
    static func identifier(domain: String?, code: Int) -> String {
        let identifierCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let safeDomain: String
        if let domain, !domain.isEmpty, domain.utf8.count <= 64,
           domain.unicodeScalars.allSatisfy({ identifierCharacters.contains($0) }) {
            safeDomain = domain
        } else {
            // Reject invalid text in full; filtering it could expose pieces of private prose.
            safeDomain = "SpeechError"
        }
        return "\(safeDomain) (\(code))"
    }

    /// Used directly for runtime callback failures and testable without starting Speech.
    static func message(domain: String?, code: Int, isSimulator: Bool) -> String {
        let explanation = isSimulator
            ? "On-device speech recognition failed in this simulator. Its speech model may be unavailable. Try again, or test on an iPhone with on-device recognition for this language. You can also paste a speech."
            : "On-device speech recognition stopped. Try again, or check Debattle's speech recognition permission in Settings. You can also paste a speech. Language support depends on this device's speech service."
        return "\(explanation) Diagnostic: \(identifier(domain: domain, code: code))."
    }
}

enum TranscriptionError: LocalizedError, Equatable {
    case permissionDenied
    case unsupportedLanguage(String)
    case onDeviceUnavailable(String)
    case temporarilyUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Speech recognition is off. Enable it for Debattle in Settings to include your speech in feedback. Voice still works."
        case .unsupportedLanguage(let language):
            SpeechCapability.unsupportedLanguage(language).message
        case .onDeviceUnavailable(let language):
            SpeechCapability.onDeviceUnavailable(language).message
        case .temporarilyUnavailable(let language):
            SpeechCapability.temporarilyUnavailable(language).message
        }
    }
}

/// A turn-scoped, explicitly on-device transcriber. Only the local speaker's microphone
/// should be appended. It never transcribes remote playback or opts into Apple servers.
@MainActor @Observable
final class SpeechTranscriber: PracticeTranscribing {
    private(set) var partialText = ""
    private(set) var isAvailable = false
    private(set) var isRecording = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var chunks: [RecognitionChunk] = []
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var rotationTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated let sink = SpeechBufferSink()
    private static let logger = Logger(subsystem: "app.debattle.ios", category: "SpeechTranscriber")

    private static func runtimeFailureMessage(domain: String?, code: Int) -> String {
        #if targetEnvironment(simulator)
        SpeechFailureDiagnostic.message(domain: domain, code: code, isSimulator: true)
        #else
        SpeechFailureDiagnostic.message(domain: domain, code: code, isSimulator: false)
        #endif
    }

    static func localeIdentifier(for language: String) -> String {
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return switch value.lowercased() {
        case "en", "english": "en-US"
        case "ru", "russian", "русский": "ru-RU"
        case "es", "spanish", "español": "es-ES"
        case "kk", "kazakh", "қазақша": "kk-KZ"
        case "fr", "french": "fr-FR"
        case "de", "german": "de-DE"
        case "ar", "arabic": "ar-SA"
        case "zh", "chinese": "zh-CN"
        case "ja", "japanese": "ja-JP"
        case "pt", "portuguese": "pt-BR"
        case "hi", "hindi": "hi-IN"
        case "tr", "turkish": "tr-TR"
        default: value
        }
    }

    /// No authorization request, microphone access, recognition task or model download.
    /// This snapshot can change; start rechecks it after speech permission is granted.
    static func capability(for language: String) -> SpeechCapability {
        inspectCapability(for: language).capability
    }

    private static func inspectCapability(for language: String) -> (recognizer: SFSpeechRecognizer?, capability: SpeechCapability) {
        let identifier = localeIdentifier(for: language)
        let localeSupported = SpeechCapability.supportsLocale(identifier, in: Set(SFSpeechRecognizer.supportedLocales().map(\.identifier)))
        // init(locale:) can fall back to the keyboard's dictation language. Reject an
        // unsupported requested locale first instead of transcribing another language.
        guard localeSupported else { return (nil, .unsupportedLanguage(language)) }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier))
        return (recognizer, SpeechCapability.classify(language: language, localeSupported: localeSupported,
            recognizerExists: recognizer != nil, supportsOnDeviceRecognition: recognizer?.supportsOnDeviceRecognition == true,
            isAvailable: recognizer?.isAvailable == true))
    }

    func start(language: String) async throws {
        cancel()
        partialText = ""
        errorMessage = nil
        let session = UUID()
        sessionID = session
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard sessionID == session else { throw CancellationError() }
        guard authorization == .authorized else {
            let error = TranscriptionError.permissionDenied
            errorMessage = error.localizedDescription
            throw error
        }
        let inspected = Self.inspectCapability(for: language)
        if let error = inspected.capability.error {
            errorMessage = error.localizedDescription
            throw error
        }
        guard let recognizer = inspected.recognizer else {
            let error = TranscriptionError.temporarilyUnavailable(language)
            errorMessage = error.localizedDescription
            throw error
        }
        recognizer.queue = OperationQueue.main
        self.recognizer = recognizer
        isAvailable = true
        isRecording = true
        beginChunk(session: session)
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
                guard let self, self.sessionID == session, self.isRecording else { return }
                // Short requests avoid the recognizer's duration limit on long debate speeches.
                // Swapping the sink before ending the old request keeps audio flowing.
                self.beginChunk(session: session)
            }
        }
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        sink.append(buffer)
    }

    /// Allows a bounded finalization period and returns all finalized and partial chunks.
    /// The caller persists this once for the turn, rather than persisting partial hypotheses.
    func finish() async -> String {
        let session = sessionID
        rotationTask?.cancel()
        rotationTask = nil
        isRecording = false
        sink.replace(with: nil)
        for _ in 0..<15 {
            guard sessionID == session else { return "" }
            if chunks.allSatisfy(\.finished) { break }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        guard sessionID == session else { return "" }
        let result = assembledText()
        for chunk in chunks { chunk.task?.cancel() }
        chunks.removeAll()
        recognizer = nil
        sessionID = UUID()
        partialText = result
        return result
    }

    func cancel() {
        sessionID = UUID()
        rotationTask?.cancel()
        rotationTask = nil
        isRecording = false
        isAvailable = false
        sink.replace(with: nil)
        for chunk in chunks { chunk.task?.cancel() }
        chunks.removeAll()
        recognizer = nil
    }

    private func beginChunk(session: UUID) {
        guard let recognizer, isRecording else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        let id = UUID()
        chunks.append(RecognitionChunk(id: id))
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Read framework values before hopping executors; the result itself is not Sendable.
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            // Keep only diagnostic identifiers. Neither transcripts, localized error
            // descriptions nor error userInfo are written to logs.
            let failureDomain = error.map { ($0 as NSError).domain }
            let failureCode = error.map { ($0 as NSError).code }
            Task { @MainActor in
                guard let self, self.sessionID == session,
                      let index = self.chunks.firstIndex(where: { $0.id == id }) else { return }
                if let text { self.chunks[index].text = text }
                if final || failureDomain != nil {
                    self.chunks[index].finished = true
                    self.chunks[index].task = nil
                }
                self.partialText = self.assembledText()
                // A completed older chunk is expected after rotation. If the current request
                // stops unexpectedly, mark transcription incomplete without interrupting voice.
                if let failureDomain, let failureCode, index == self.chunks.count - 1, self.isRecording {
                    self.isRecording = false
                    self.rotationTask?.cancel()
                    self.sink.replace(with: nil)
                    Self.logger.error("On-device recognition failed. Domain: \(failureDomain, privacy: .public); code: \(failureCode, privacy: .public)")
                    self.errorMessage = Self.runtimeFailureMessage(domain: failureDomain, code: failureCode)
                } else if final, index == self.chunks.count - 1, self.isRecording {
                    self.beginChunk(session: session)
                }
            }
        }
        if let index = chunks.firstIndex(where: { $0.id == id }) { chunks[index].task = task }
        sink.replace(with: request)
    }

    private func assembledText() -> String {
        chunks.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct RecognitionChunk {
    let id: UUID
    var text = ""
    var finished = false
    var task: SFSpeechRecognitionTask?
}

/// append and endAudio are serialized even when a turn ends while a buffer is in flight.
/// VoiceService invokes this sink from its processing queue, never its realtime tap.
private final class SpeechBufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
    }

    func replace(with newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock {
            request?.endAudio()
            request = newRequest
        }
    }
}
