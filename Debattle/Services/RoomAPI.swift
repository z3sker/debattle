import Foundation
import Security

struct GuestSession: Codable, Sendable {
    let token: String
    let participantID: String
    let displayName: String
    var authProvider: String? = nil
    var expiresAt: Double? = nil
    /// Apple’s opaque identifier stays in this device’s Keychain; it is never sent to room members.
    var localAppleUserID: String? = nil

    var isExpired: Bool { expiresAt.map { $0 <= Date().timeIntervalSince1970 } ?? false }
}

struct APIError: LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var errorDescription: String? { message }
}

@MainActor final class RoomAPI {
    let baseURL: URL
    var token: String?
    private let session: URLSession

    init(baseURL: URL, token: String? = nil, configuration: URLSessionConfiguration? = nil) {
        self.baseURL = baseURL
        self.token = token
        let configuration = configuration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        self.session = URLSession(configuration: configuration, delegate: RoomRedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError(message: "The server returned an unreadable response.") }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error ?? "Request failed (\(response.statusCode))."
            throw APIError(message: message, statusCode: response.statusCode)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError(message: "The server response could not be read. Check that the app and server versions match.") }
    }

    func stream(roomID: String) -> URLSessionWebSocketTask {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/rooms/\(roomID)/stream"), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "audioCodec", value: "pcm16")]
        var request = URLRequest(url: components.url!)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return session.webSocketTask(with: request)
    }

    struct ServerError: Decodable { let error: String }
    struct RoomsResponse: Decodable { let rooms: [DebateRoom] }
    struct RoomResponse: Decodable { let room: DebateRoom }
    struct Acknowledgement: Decodable { }
}

/// A configured room endpoint must not forward guest credentials or transcript bodies
/// to another destination (including an HTTPS-to-HTTP redirect). The operator should
/// publish the final API URL directly; a 3xx response is reported as an API error.
final class RoomRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum SecureSessionStore {
    private static let service = "app.debattle.guest-session"
    static func read(server: String) -> GuestSession? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: server, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(GuestSession.self, from: data)
    }
    static func write(_ session: GuestSession, server: String) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: server]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
    static func remove(server: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: server] as CFDictionary)
    }
}
