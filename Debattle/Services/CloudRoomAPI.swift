import Foundation

struct CloudRoomCapture: Codable, Equatable, Sendable {
    let captureID: String
    let maxAudioSeconds: Int
}

struct CloudRoomTranscription: Decodable, Sendable {
    let room: DebateRoom
}

struct CloudRoomVerdict: Decodable, Sendable {
    let room: DebateRoom
    let verdict: RoundVerdict
}

struct CloudRoomJudgeStatus: Decodable, Sendable {
    let state: String
    let completedSteps: Int
    let totalSteps: Int
    let message: String
    let room: DebateRoom?
    let verdict: RoundVerdict?
    let code: String?
}

enum CloudRoomError: LocalizedError, Equatable {
    case consentRequired, authentication, connection, unavailable, quota, staleCapture, invalidResponse, tooLong, noAudio, changedRound, roundCapacity
    var errorDescription: String? {
        switch self {
        case .authentication: "Your Debattle session expired. Reconnect and sign in again before using cloud AI."
        case .changedRound: "The room transcript changed during judging. Review the updated transcript, then request a new judgment."
        case .roundCapacity: "This complete round exceeds the cloud processing budget. No partial-round verdict was generated."
        case .consentRequired: "Cloud AI needs permission from every speaker whose speech it reviews. Voice debates remain available without cloud AI."
        case .connection: "Cloud AI could not reach Debattle. Check your connection and try again."
        case .unavailable: "Cloud AI is unavailable right now. Your voice debate can continue; no AI result was generated."
        case .quota: "The shared AI allowance is temporarily exhausted. Voice debates still work. Try AI again later."
        case .staleCapture: "This recording no longer belongs to an active, authorized speech. It was discarded without adding a transcript."
        case .invalidResponse: "The AI response could not be verified. No result was saved."
        case .tooLong: "This speech exceeded the cloud recording limit. No partial speech was submitted."
        case .noAudio: "No microphone audio was captured for this speech."
        }
    }
}

/// Authenticated, room-scoped cloud requests. No provider credential enters the app.
final class CloudRoomAPI: Sendable {
    static let maximumAudioSeconds = 960
    static let maximumResponseBytes = 1_048_576
    let connection: CloudPracticeConnection
    private let session: URLSession

    init(connection: CloudPracticeConnection, configuration: URLSessionConfiguration? = nil) {
        self.connection = connection
        let configuration = (configuration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.timeoutIntervalForRequest = 540
        configuration.timeoutIntervalForResource = 600
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: RoomRedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func setConsent(roomID: String, enabled: Bool) async throws -> DebateRoom {
        let result: RoomEnvelope = try await request(roomID: roomID, suffix: "consent", body: JSONEncoder().encode(ConsentRequest(enabled: enabled)), contentType: "application/json")
        guard result.room.id == roomID else { throw CloudRoomError.invalidResponse }
        return result.room
    }

    func startCapture(roomID: String, turnID: String) async throws -> CloudRoomCapture {
        let result: CloudRoomCapture = try await request(roomID: roomID, suffix: "captures", body: JSONEncoder().encode(CaptureRequest(turnID: turnID)), contentType: "application/json")
        guard Self.validIdentifier(result.captureID), (1...Self.maximumAudioSeconds).contains(result.maxAudioSeconds) else { throw CloudRoomError.invalidResponse }
        return result
    }

    func cancelCapture(roomID: String, captureID: String) async {
        guard Self.validIdentifier(captureID) else { return }
        let _: RoomEnvelope? = try? await request(roomID: roomID, suffix: "captures/\(captureID)", method: "DELETE", body: Data("{}".utf8), contentType: "application/json")
    }

    func transcribe(roomID: String, capture: CloudRoomCapture, wav: Data) async throws -> DebateRoom {
        guard Self.validIdentifier(capture.captureID), wav.count > 44,
              wav.count <= capture.maxAudioSeconds * 48_000 + 44 else { throw CloudRoomError.tooLong }
        let result: CloudRoomTranscription = try await request(roomID: roomID, suffix: "transcribe", query: [URLQueryItem(name: "captureID", value: capture.captureID)], body: wav, contentType: "audio/wav")
        guard result.room.id == roomID else { throw CloudRoomError.invalidResponse }
        return result.room
    }

    func judge(roomID: String, method: String = "POST") async throws -> CloudRoomJudgeStatus {
        let response: CloudRoomJudgeStatus = try await request(roomID: roomID, suffix: "judge", method: method,
            body: method == "GET" ? nil : Data("{}".utf8), contentType: "application/json")
        guard ["idle", "running", "complete", "failed", "cancelled"].contains(response.state),
              response.completedSteps >= 0, response.totalSteps >= 0, response.message.utf8.count <= 2_000 else {
            throw CloudRoomError.invalidResponse
        }
        return response
    }

    func cancelJudge(roomID: String) async {
        let _: CloudRoomJudgeStatus? = try? await request(roomID: roomID, suffix: "judge", method: "DELETE", body: Data("{}".utf8), contentType: "application/json")
    }

    static func validate(_ response: CloudRoomJudgeStatus, roomID: String) throws -> CloudRoomVerdict {
        guard response.state == "complete", let room = response.room, var verdict = response.verdict,
              room.id == roomID else { throw CloudRoomError.invalidResponse }
        let prepared = try RoundJudgeValidation.prepare(room)
        try RoundJudgeValidation.validate(verdict, against: prepared)
        // Bind saved results to the exact server snapshot displayed on this device.
        verdict.transcriptDigest = try RoundJudgeValidation.transcriptDigest(room)
        return CloudRoomVerdict(room: room, verdict: verdict)
    }

    static func validIdentifier(_ value: String) -> Bool {
        value.range(of: "^[a-zA-Z0-9_.-]{1,100}$", options: .regularExpression) != nil
    }

    private func request<T: Decodable & Sendable>(roomID: String, suffix: String, method: String = "POST", query: [URLQueryItem] = [], body: Data?, contentType: String) async throws -> T {
        try Task.checkCancellation()
        let base = connection.baseURL
        guard Self.validIdentifier(roomID), ["https", "http"].contains(base.scheme?.lowercased() ?? ""),
              base.host != nil, base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              !connection.token.isEmpty, !connection.token.contains("\r"), !connection.token.contains("\n") else { throw CloudRoomError.connection }
        var components = URLComponents(url: base.appendingPathComponent("v1/rooms/\(roomID)/ai/\(suffix)"), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 540)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("room-v1", forHTTPHeaderField: "X-Debattle-Cloud-Consent")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw CloudRoomError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else {
                switch response.statusCode {
                case 401: throw CloudRoomError.authentication
                case 403: throw CloudRoomError.consentRequired
                case 409, 410: throw suffix == "judge" ? CloudRoomError.changedRound : CloudRoomError.staleCapture
                case 413: throw suffix == "judge" ? CloudRoomError.roundCapacity : CloudRoomError.tooLong
                case 429: throw CloudRoomError.quota
                case 422: throw RoundJudgeError.incomplete("Every scheduled speech needs enough submitted text. Wait for pending transcription, then review Room transcript.")
                default: throw CloudRoomError.unavailable
                }
            }
            guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw CloudRoomError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumResponseBytes else { throw CloudRoomError.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard let result = try? JSONDecoder().decode(T.self, from: data) else { throw CloudRoomError.invalidResponse }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as CloudRoomError { throw error }
        catch let error as RoundJudgeError { throw error }
        catch { throw CloudRoomError.connection }
    }

    private struct ConsentRequest: Encodable { let enabled: Bool }
    private struct CaptureRequest: Encodable { let turnID: String }
    private struct RoomEnvelope: Decodable, Sendable { let room: DebateRoom }
}
