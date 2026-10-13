import Foundation
import XCTest
@testable import Debattle

final class ConnectionTests: XCTestCase {
    private static var betaConfiguration: Data {
        Data(#"{"authenticationRequired":false,"appleSignInAvailable":false,"communityGuidelinesVersion":"2026-09-22"}"#.utf8)
    }
    private var savedAddress: Any?
    private var savedName: Any?

    override func setUp() {
        super.setUp()
        savedAddress = UserDefaults.standard.object(forKey: "serverAddress")
        savedName = UserDefaults.standard.object(forKey: "displayName")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedAddress, forKey: "serverAddress")
        UserDefaults.standard.set(savedName, forKey: "displayName")
        super.tearDown()
    }

    @MainActor
    func testFailedDiscoveryDoesNotPublishCandidateIdentityOrKeepPreviousRooms() async throws {
        let endpoint = URL(string: "https://\(UUID().uuidString.lowercased()).test")!
        let guest = GuestSession(token: "synthetic-test-token", participantID: "new-guest", displayName: "Test guest")
        let guestData = try JSONEncoder().encode(guest)
        let log = ConnectionRequestLog()
        ConnectionURLProtocol.install(host: endpoint.host!) { request in
            log.record(request.url!.path)
            if request.url!.path == "/v1/config" { return (200, Self.betaConfiguration) }
            if request.url!.path == "/v1/sessions" { return (201, guestData) }
            return (503, Data(#"{"error":"Temporarily unavailable"}"#.utf8))
        }
        defer {
            ConnectionURLProtocol.remove(host: endpoint.host!)
            SecureSessionStore.remove(server: endpoint.absoluteString)
        }
        let store = makeStore(endpoint: endpoint)
        store.session = GuestSession(token: "previous-synthetic-token", participantID: "previous-guest", displayName: "Previous guest")
        store.rooms = [sampleRoom()]

        await store.connect()

        XCTAssertNil(store.session, "A created guest is not a connected account until authenticated discovery succeeds.")
        XCTAssertNil(store.cloudPracticeConnection)
        XCTAssertTrue(store.rooms.isEmpty, "A failed server switch must not show the previous server's rooms.")
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.connectionMessage, "Temporarily unavailable")
        let created = await store.createRoom(title: "This house would expand transit", language: "English", format: FormatCatalog.duel, visibility: "public")
        XCTAssertFalse(created)
        XCTAssertEqual(log.paths, ["/v1/config", "/v1/sessions", "/v1/rooms"], "No mutation may use an unverified candidate connection.")
    }

    @MainActor
    func testSuccessfulConnectionPublishesMatchingIdentityAndRoomsTogether() async throws {
        let endpoint = URL(string: "https://\(UUID().uuidString.lowercased()).test")!
        let guest = GuestSession(token: "synthetic-test-token", participantID: "new-guest", displayName: "Test guest")
        let guestData = try JSONEncoder().encode(guest)
        let room = sampleRoom()
        let roomObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(room))
        let roomsData = try JSONSerialization.data(withJSONObject: ["rooms": [roomObject]])
        ConnectionURLProtocol.install(host: endpoint.host!) { request in
            if request.url!.path == "/v1/config" { return (200, Self.betaConfiguration) }
            return request.url!.path == "/v1/sessions" ? (201, guestData) : (200, roomsData)
        }
        defer {
            ConnectionURLProtocol.remove(host: endpoint.host!)
            SecureSessionStore.remove(server: endpoint.absoluteString)
        }
        let store = makeStore(endpoint: endpoint)

        await store.connect()

        XCTAssertEqual(store.session?.participantID, guest.participantID)
        XCTAssertEqual(store.rooms, [room])
        XCTAssertNil(store.connectionMessage)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testCloudHandoffRequiresMatchingVerifiedServerAndIdentity() async throws {
        let endpoint = URL(string: "https://\(UUID().uuidString.lowercased()).test")!
        let guest = GuestSession(token: "synthetic-cloud-token", participantID: "guest", displayName: "Test guest")
        let guestData = try JSONEncoder().encode(guest)
        ConnectionURLProtocol.install(host: endpoint.host!) { request in
            if request.url!.path == "/v1/config" { return (200, Self.betaConfiguration) }
            return request.url!.path == "/v1/sessions" ? (201, guestData) : (200, Data(#"{"rooms":[]}"#.utf8))
        }
        defer {
            ConnectionURLProtocol.remove(host: endpoint.host!)
            SecureSessionStore.remove(server: endpoint.absoluteString)
        }
        let store = makeStore(endpoint: endpoint)
        XCTAssertNil(store.cloudPracticeConnection)
        await store.connect()
        XCTAssertEqual(store.cloudPracticeConnection?.baseURL, endpoint)
        XCTAssertEqual(store.cloudPracticeConnection?.token, guest.token)

        store.serverAddress = "https://another.test"
        XCTAssertNil(store.cloudPracticeConnection, "A draft server edit cannot reuse the old token on the new server.")
        store.serverAddress = endpoint.absoluteString
        store.session = GuestSession(token: "different-token", participantID: "different", displayName: "Different")
        XCTAssertNil(store.cloudPracticeConnection, "An independently changed identity cannot inherit the authenticated client.")
    }

    @MainActor
    func testUntrustedServerAddressComponentsCannotUseAnOldConnection() async {
        for address in ["https://user:password@example.test", "https://example.test?token=secret", "https://example.test#fragment"] {
            let store = makeStore(endpoint: URL(string: "https://unused.test")!)
            store.serverAddress = address
            store.session = GuestSession(token: "synthetic-test-token", participantID: "old", displayName: "Old")
            store.rooms = [sampleRoom()]

            await store.connect()

            XCTAssertNil(store.session)
            XCTAssertTrue(store.rooms.isEmpty)
            XCTAssertNotNil(store.connectionMessage)
        }
    }

    func testRedirectPolicyDoesNotForwardAuthenticatedTranscriptToAnotherDestination() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://rooms.example.test/v1/rooms/test/transcript")!
        let response = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil,
                                                  headerFields: ["Location": "http://different.example.test/collect"]))
        var redirected = URLRequest(url: URL(string: "http://different.example.test/collect")!)
        redirected.httpMethod = "POST"
        redirected.httpBody = Data(#"{"text":"Private speech"}"#.utf8)
        redirected.setValue("Bearer synthetic-test-token", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: original) // Never resumed; no real network request.
        let completion = expectation(description: "Redirect rejected")

        RoomRedirectPolicy().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { proposed in
            XCTAssertNil(proposed)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
    }

    @MainActor
    func testRepeatedReconnectSetupDoesNotPostponeMembershipExpiryPolling() async throws {
        let endpoint = URL(string: "https://\(UUID().uuidString.lowercased()).test")!
        let polled = expectation(description: "Original three-second membership poll reaches the server")
        ConnectionURLProtocol.install(host: endpoint.host!) { _ in
            polled.fulfill()
            return (404, Data(#"{"error":"Room not found."}"#.utf8))
        }
        defer { ConnectionURLProtocol.remove(host: endpoint.host!) }
        let store = makeStore(endpoint: endpoint)
        store.activeRoom = sampleRoom()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionURLProtocol.self]
        let client = RoomAPI(baseURL: endpoint, token: "synthetic-test-token", configuration: configuration)
        let roomID = store.activeRoom!.id
        let generation = store.roomGeneration
        let membershipEnded = expectation(description: "Expired membership closes locally")
        let observer = Task { @MainActor in
            while !Task.isCancelled, store.activeRoom != nil {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
            if !Task.isCancelled { membershipEnded.fulfill() }
        }
        defer { observer.cancel() }

        store.startRoomPolling(roomID: roomID, generation: generation, using: client)
        // The real reconnect loop runs every two seconds. Its next setup must retain
        // the first three-second poll, rather than restarting the deadline at five.
        try await Task.sleep(for: .seconds(2))
        store.startRoomPolling(roomID: roomID, generation: generation, using: client)
        await fulfillment(of: [polled, membershipEnded], timeout: 2)

        XCTAssertNil(store.activeRoom)
        XCTAssertFalse(store.streamConnected)
        XCTAssertNotNil(store.alertMessage)
        await store.leaveRoom()
    }

    @MainActor
    func testForcedDepartureRecoveryPreservesPartialSpeechWithoutUploadingOrChangingRoomEvidence() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("interrupted-speech-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let archive = TranscriptRecoveryArchive(fileURL: file)
        let store = AppStore(historyLoader: { [] }, historyWriter: { _ in }, recoveryArchive: archive) { _ in
            XCTFail("Forced-departure recovery must not create a network connection.")
            return RoomAPI(baseURL: URL(string: "https://unused.test")!)
        }
        var original = sampleRoom()
        original.participants = [Participant(id: "speaker", displayName: "Recognized speaker", teamID: "gov", seatIndex: 0)]
        store.activeRoom = original
        let text = "The partial argument that was recognized before my membership ended."

        let notice = store.preserveInterruptedSpeech(text, room: original, turnID: original.format.turns[0].id, participantID: "speaker")

        let saved = try XCTUnwrap(archive.load().first)
        XCTAssertEqual(saved.text, text)
        XCTAssertEqual(saved.speakerName, "Recognized speaker")
        XCTAssertEqual(saved.turnID, original.format.turns[0].id)
        XCTAssertEqual(store.activeRoom, original, "Recovered speech never becomes evidence in the room transcript.")
        XCTAssertTrue(store.completedDebates.isEmpty)
        XCTAssertTrue(notice?.contains("saved") == true)
        store.preserveInterruptedSpeech(text, room: original, turnID: original.format.turns[0].id, participantID: "speaker")
        XCTAssertEqual(try archive.load().count, 1, "An upload's existing identical safety copy must not be duplicated.")
    }

    @MainActor
    func testPublicBrowsingDoesNotCreateGuestOrEnableAIWithoutAppleAccount() async throws {
        let endpoint = URL(string: "https://\(UUID().uuidString.lowercased()).test")!
        let log = ConnectionRequestLog()
        ConnectionURLProtocol.install(host: endpoint.host!) { request in
            log.record(request.url!.path)
            if request.url!.path == "/v1/config" {
                return (200, Data(#"{"authenticationRequired":true,"appleSignInAvailable":true,"communityGuidelinesVersion":"2026-09-22"}"#.utf8))
            }
            return (200, Data(#"{"rooms":[]}"#.utf8))
        }
        defer { ConnectionURLProtocol.remove(host: endpoint.host!); SecureSessionStore.remove(server: endpoint.absoluteString) }
        let store = makeStore(endpoint: endpoint)
        await store.connect()
        XCTAssertNil(store.session)
        XCTAssertNil(store.cloudPracticeConnection)
        XCTAssertTrue(store.needsSignIn)
        XCTAssertNil(store.connectionMessage)
        XCTAssertEqual(log.paths, ["/v1/config", "/v1/rooms"])
    }

    @MainActor
    func testPublicConnectionDropsLegacyGuestBeforeSendingAnyCredential() async throws {
        let endpoint = URL(string: "https://\(UUID().uuidString.lowercased()).test")!
        SecureSessionStore.write(GuestSession(token: "old-guest", participantID: "guest", displayName: "Guest"), server: endpoint.absoluteString)
        ConnectionURLProtocol.install(host: endpoint.host!) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if request.url!.path == "/v1/config" {
                return (200, Data(#"{"authenticationRequired":true,"appleSignInAvailable":true,"communityGuidelinesVersion":"2026-09-22"}"#.utf8))
            }
            return (200, Data(#"{"rooms":[]}"#.utf8))
        }
        defer { ConnectionURLProtocol.remove(host: endpoint.host!); SecureSessionStore.remove(server: endpoint.absoluteString) }
        let store = makeStore(endpoint: endpoint)
        await store.connect()
        XCTAssertNil(store.session)
        XCTAssertNil(SecureSessionStore.read(server: endpoint.absoluteString))
        XCTAssertTrue(store.needsSignIn)
    }

    @MainActor
    func testConfigurationFailureNeverDowngradesToGuestCreation() async {
        let endpoint = URL(string: "https://\(UUID().uuidString.lowercased()).test")!
        let log = ConnectionRequestLog()
        ConnectionURLProtocol.install(host: endpoint.host!) { request in
            log.record(request.url!.path)
            return (503, Data(#"{"error":"Service unavailable"}"#.utf8))
        }
        defer { ConnectionURLProtocol.remove(host: endpoint.host!) }
        let store = makeStore(endpoint: endpoint)
        await store.connect()
        XCTAssertNil(store.session)
        XCTAssertNil(store.api)
        XCTAssertNotNil(store.connectionMessage)
        XCTAssertEqual(log.paths, ["/v1/config"])
    }

    @MainActor
    private func makeStore(endpoint: URL) -> AppStore {
        let recoveryURL = FileManager.default.temporaryDirectory.appendingPathComponent("debattle-connection-\(UUID().uuidString).json")
        let store = AppStore(historyLoader: { [] }, historyWriter: { _ in },
                             recoveryArchive: TranscriptRecoveryArchive(fileURL: recoveryURL)) { url in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ConnectionURLProtocol.self]
            return RoomAPI(baseURL: url, configuration: configuration)
        }
        store.serverAddress = endpoint.absoluteString
        store.displayName = "Test guest"
        return store
    }

    private func sampleRoom() -> DebateRoom {
        DebateRoom(id: "room-test", title: "This house would expand public transport", language: "English",
                   format: FormatCatalog.duel, hostID: "host", participants: [], revision: 1)
    }
}

private final class ConnectionRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPaths: [String] = []
    var paths: [String] { lock.withLock { recordedPaths } }
    func record(_ path: String) { lock.withLock { recordedPaths.append(path) } }
}

private final class ConnectionProtocolHandlers: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    func set(host: String, handler: Handler?) { lock.withLock { handlers[host] = handler } }
    func get(host: String) -> Handler? { lock.withLock { handlers[host] } }
}

private final class ConnectionURLProtocol: URLProtocol {
    private static let handlers = ConnectionProtocolHandlers()
    static func install(host: String, handler: @escaping ConnectionProtocolHandlers.Handler) { handlers.set(host: host, handler: handler) }
    static func remove(host: String) { handlers.set(host: host, handler: nil) }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let handler = Self.handlers.get(host: url.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
