import Foundation

struct CloudPracticeConnection: Equatable, Sendable {
    let baseURL: URL
    let token: String
}

struct CloudPracticeStatus: Codable, Equatable, Sendable {
    let available: Bool
    let provider: String
    let message: String
    let maxAudioSeconds: Int
}

struct CloudPracticeObservation: Codable, Equatable, Sendable {
    let quote: String
    let explanation: String
}

struct CloudPracticeFeedback: Codable, Equatable, Sendable {
    let summary: String
    let strengths: [CloudPracticeObservation]
    let improvements: [CloudPracticeObservation]
    let reviewedText: String
    let provider: String
    let model: String
}

enum CloudPracticeError: Error, LocalizedError, Equatable, Sendable {
    case invalidConnection, unsupportedLanguage, invalidAudio, audioTooLong, noAudio, invalidMotion
    case responseTooLarge, invalidResponse, authentication, consentRequired, unavailable, rateLimited, network

    var errorDescription: String? {
        switch self {
        case .invalidConnection: "Connect to the configured Debattle server before using cloud Practice."
        case .unsupportedLanguage: "Choose one of Debattle's supported Practice languages. Cloud transcription and coaching accuracy vary by language."
        case .invalidAudio: "This recording could not be prepared for cloud transcription. Please record your speech again."
        case .audioTooLong: "Cloud recordings are limited to seven minutes. This recording was discarded; please try a shorter speech."
        case .noAudio: "No microphone audio was captured. Please record your speech again, or paste a transcript."
        case .invalidMotion: "Enter a debate motion of 1–500 characters before requesting cloud feedback."
        case .responseTooLarge, .invalidResponse: "The cloud response could not be verified. No result was saved. Please try again."
        case .authentication: "Your server session has expired. Reconnect to the Debattle server and try again."
        case .consentRequired: "Cloud Practice is not authorized for this request. Review its consent settings before trying again."
        case .unavailable: "Cloud Practice is unavailable on this server right now. Try again later or choose on-device Practice."
        case .rateLimited: "The shared cloud allowance is temporarily exhausted. Please try again later."
        case .network: "Cloud Practice could not reach the server. Check your connection and try again."
        }
    }
}

/// Created only after the user opts into cloud Practice. Credentials and speech go
/// solely to the configured Debattle endpoint; a provider key never enters the app.
final class CloudPracticeAPI: Sendable {
    static let maximumAudioSeconds = 420
    static let maximumWAVBytes = 20_160_044
    static let maximumResponseBytes = 262_144
    let connection: CloudPracticeConnection
    private let session: URLSession

    init(connection: CloudPracticeConnection, configuration: URLSessionConfiguration? = nil) {
        self.connection = connection
        let configuration = (configuration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 240
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: RoomRedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func status() async throws -> CloudPracticeStatus {
        let result: CloudPracticeStatus = try await request(path: "v1/ai/status")
        guard result.provider.lowercased() == "groq", !result.message.isEmpty, result.message.utf8.count <= 2_000,
              (1...Self.maximumAudioSeconds).contains(result.maxAudioSeconds) else { throw CloudPracticeError.invalidResponse }
        return result
    }

    func transcribe(wav: Data, language: String) async throws -> String {
        try CloudPracticeWAV.validate(wav)
        let code = try Self.languageCode(language)
        let result: TranscriptionResponse = try await request(path: "v1/ai/transcribe", language: code,
                                                             body: wav, contentType: "audio/wav")
        guard result.provider.lowercased() == "groq", !result.model.isEmpty, result.model.utf8.count <= 200,
              result.text.utf8.count <= 200_000 else { throw CloudPracticeError.invalidResponse }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func feedback(motion: String, language: String, transcript: String) async throws -> CloudPracticeFeedback {
        let code = try Self.languageCode(language)
        let source = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.count >= 80 else { throw JudgeError.tooLittleSpeech }
        guard !motion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, motion.utf16.count <= 500 else { throw CloudPracticeError.invalidMotion }
        guard source.utf8.count <= 200_000 else { throw CloudPracticeError.invalidResponse }
        // The judge only reviews this prefix; do not transmit the rest of the draft.
        let excerpt = Self.excerpt(from: source)
        let body = try JSONEncoder().encode(FeedbackRequest(motion: motion, language: code, transcript: excerpt))
        let result: CloudPracticeFeedback = try await request(path: "v1/ai/feedback", body: body, contentType: "application/json")
        try Self.validate(result, source: source)
        return result
    }

    static func languageCode(_ language: String) throws -> String {
        switch language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "english", "en", "en-us": "en"
        case "russian", "ru", "ru-ru", "русский": "ru"
        case "spanish", "es", "es-es", "español": "es"
        case "kazakh", "kk", "kk-kz", "қазақша": "kk"
        case "french", "fr", "fr-fr": "fr"
        case "german", "de", "de-de": "de"
        case "arabic", "ar", "ar-sa": "ar"
        case "chinese", "zh", "zh-cn": "zh"
        case "japanese", "ja", "ja-jp": "ja"
        case "portuguese", "pt", "pt-br": "pt"
        case "hindi", "hi", "hi-in": "hi"
        case "turkish", "tr", "tr-tr": "tr"
        default: throw CloudPracticeError.unsupportedLanguage
        }
    }

    static func excerpt(from source: String) -> String {
        var scalars = String.UnicodeScalarView()
        var bytes = 0
        for scalar in source.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            let size = scalar.utf8.count
            guard bytes + size <= 2_200 else { break }
            scalars.append(scalar)
            bytes += size
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check every quotation, rather than silently dropping unsupported observations.
    /// Exact evidence is not independent fact-checking or validation of model judgment.
    static func validate(_ feedback: CloudPracticeFeedback, source: String) throws {
        let excerpt = feedback.reviewedText
        guard feedback.provider.lowercased() == "groq", !feedback.model.isEmpty, feedback.model.utf8.count <= 200,
              !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              excerpt.utf8.count <= 2_200,
              Data(excerpt.utf8) == Data(Self.excerpt(from: source).utf8),
              !feedback.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              feedback.summary.utf16.count <= 1_200,
              (1...3).contains(feedback.strengths.count), (1...3).contains(feedback.improvements.count) else {
            throw CloudPracticeError.invalidResponse
        }
        for item in feedback.strengths + feedback.improvements {
            guard !item.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.quote.utf16.count <= 400,
                  Data(excerpt.utf8).range(of: Data(item.quote.utf8)) != nil,
                  !item.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.explanation.utf16.count <= 1_200 else { throw JudgeError.unverifiableEvidence }
        }
    }

    private func request<T: Decodable & Sendable>(path: String, language: String? = nil,
                                                  body: Data? = nil, contentType: String? = nil) async throws -> T {
        try Task.checkCancellation()
        let base = connection.baseURL
        guard ["https", "http"].contains(base.scheme?.lowercased() ?? ""), base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              !connection.token.isEmpty, !connection.token.contains("\r"), !connection.token.contains("\n"),
              var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw CloudPracticeError.invalidConnection
        }
        if let language { components.queryItems = [URLQueryItem(name: "language", value: language)] }
        guard let url = components.url else { throw CloudPracticeError.invalidConnection }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue("practice-v1", forHTTPHeaderField: "X-Debattle-Cloud-Consent")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw CloudPracticeError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else {
                switch response.statusCode {
                case 401: throw CloudPracticeError.authentication
                case 403: throw CloudPracticeError.consentRequired
                case 429: throw CloudPracticeError.rateLimited
                case 300..<400: throw CloudPracticeError.invalidConnection
                case 413: throw CloudPracticeError.audioTooLong
                case 400, 422: throw CloudPracticeError.invalidResponse
                default: throw CloudPracticeError.unavailable
                }
            }
            guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw CloudPracticeError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumResponseBytes else { throw CloudPracticeError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard let result = try? JSONDecoder().decode(T.self, from: data) else { throw CloudPracticeError.invalidResponse }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as CloudPracticeError {
            throw error
        } catch {
            throw CloudPracticeError.network
        }
    }

    private struct FeedbackRequest: Encodable { let motion: String; let language: String; let transcript: String }
    private struct TranscriptionResponse: Decodable, Sendable { let text: String; let provider: String; let model: String }
}
