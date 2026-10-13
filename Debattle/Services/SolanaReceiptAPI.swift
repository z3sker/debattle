import Foundation

/// A portable copy of the exact server-issued receipt. The opaque record is kept
/// intact so exporting it never drops fields used in its canonical SHA-256 hash.
struct SolanaReceipt: Sendable {
    let data: Data
    let signature: String
    let signer: String
    let digest: String
    let memo: String

    var explorerURL: URL {
        URL(string: "https://explorer.solana.com/tx/\(signature)?cluster=devnet")!
    }

    init(data: Data) throws {
        let fields = try JSONDecoder().decode(Fields.self, from: data)
        guard fields.schema == "debattle-proof-v1", fields.cluster == "devnet",
              fields.signature.range(of: "^[1-9A-HJ-NP-Za-km-z]{64,88}$", options: .regularExpression) != nil,
              fields.signer.range(of: "^[1-9A-HJ-NP-Za-km-z]{32,44}$", options: .regularExpression) != nil,
              fields.digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              fields.memo.utf8.count <= 566,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["record"] is [String: Any] else {
            throw APIError(message: "The server returned an invalid devnet receipt.")
        }
        self.data = data
        signature = fields.signature
        signer = fields.signer
        digest = fields.digest
        memo = fields.memo
    }

    private struct Fields: Decodable {
        let schema: String
        let cluster: String
        let signature: String
        let signer: String
        let digest: String
        let memo: String
    }
}

struct SolanaVerification: Decodable, Sendable {
    let verified: Bool
    let reason: String
}

/// No wallet private key enters iOS. The configured server signs a Solana devnet
/// Memo transaction; verification is a separate, public API operation.
final class SolanaReceiptAPI: Sendable {
    let connection: CloudPracticeConnection
    private let session: URLSession

    init(connection: CloudPracticeConnection, configuration: URLSessionConfiguration? = nil) {
        self.connection = connection
        let configuration = (configuration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: RoomRedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func receipt(roomID: String, publish: Bool = false) async throws -> SolanaReceipt? {
        guard CloudRoomAPI.validIdentifier(roomID) else { throw APIError(message: "Invalid room identifier.") }
        let data = try await request("v1/rooms/\(roomID)/proof", method: publish ? "POST" : "GET",
                                     body: publish ? Data(#"{"consent":true}"#.utf8) : nil, authenticated: true)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope.keys.contains("receipt") else { throw APIError(message: "The receipt response could not be read.") }
        if envelope["receipt"] is NSNull { return nil }
        guard let receipt = envelope["receipt"] as? [String: Any] else { throw APIError(message: "The receipt response could not be read.") }
        return try SolanaReceipt(data: JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted]))
    }

    func verify(_ receipt: SolanaReceipt) async throws -> SolanaVerification {
        let object = try JSONSerialization.jsonObject(with: receipt.data)
        let data = try await request("v1/proofs/verify", method: "POST",
                                     body: JSONSerialization.data(withJSONObject: ["receipt": object]), authenticated: false)
        return try JSONDecoder().decode(SolanaVerification.self, from: data)
    }

    private func request(_ path: String, method: String, body: Data?, authenticated: Bool) async throws -> Data {
        let base = connection.baseURL
        guard ["http", "https"].contains(base.scheme?.lowercased() ?? ""), base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              !connection.token.contains("\r"), !connection.token.contains("\n") else {
            throw APIError(message: "Reconnect to the Debattle server first.")
        }
        var request = URLRequest(url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated { request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw APIError(message: "The server could not be reached.") }
        guard response.expectedContentLength <= 1_048_576 else { throw APIError(message: "The receipt response is too large.") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw APIError(message: "The receipt response is too large.") }
            data.append(byte)
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(RoomAPI.ServerError.self, from: data))?.error
            throw APIError(message: message ?? "Proof request failed (\(response.statusCode)).", statusCode: response.statusCode)
        }
        return data
    }
}
