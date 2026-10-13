import Foundation
import AuthenticationServices
import XCTest
@testable import Debattle

final class AccountLifecycleTests: XCTestCase {
    private var address: Any?
    private var savedDisplayName: Any?
    override func setUp() {
        super.setUp()
        address = UserDefaults.standard.object(forKey: "serverAddress")
        savedDisplayName = UserDefaults.standard.object(forKey: "displayName")
    }
    override func tearDown() {
        UserDefaults.standard.set(address, forKey: "serverAddress")
        UserDefaults.standard.set(savedDisplayName, forKey: "displayName")
        super.tearDown()
    }

    @MainActor
    func testLateSignInCannotRestoreIdentityAfterSignOutStarts() async throws {
        let fixture = AccountLifecycleFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let started = expectation(description: "Sign-in request started")
        let logoutStarted = expectation(description: "Existing session logout started")
        let loginReply = DeferredAccountReply()
        let logoutReply = DeferredAccountReply()
        let newSession = GuestSession(token: "new-token", participantID: "new-account", displayName: "New", authProvider: "apple")
        let sessionData = try JSONEncoder().encode(newSession)
        fixture.respond { request, reply in
            switch request.url?.path {
            case "/v1/auth/apple": loginReply.install(reply); started.fulfill()
            case "/v1/auth/logout" where request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token":
                logoutReply.install(reply); logoutStarted.fulfill()
            case "/v1/config": reply(200, Self.configuration)
            case "/v1/rooms": reply(200, Data(#"{"rooms":[]}"#.utf8))
            default: reply(200, Data("{}".utf8))
            }
        }
        let login = Task { try await store.signInWithApple(identityToken: "synthetic-identity", authorizationCode: "synthetic-code", challenge: fixture.challenge, endpoint: fixture.endpoint.absoluteString) }
        await fulfillment(of: [started], timeout: 2)
        let logout = Task { await store.signOut() }
        await fulfillment(of: [logoutStarted], timeout: 2)
        XCTAssertTrue(store.isTransitioningAccount)
        XCTAssertNil(store.cloudPracticeConnection, "An account transition must immediately cancel cloud access.")
        loginReply.send(200, sessionData)
        do { try await login.value; XCTFail("The late login must be rejected") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNotEqual(store.session?.participantID, newSession.participantID)
        XCTAssertNil(SecureSessionStore.read(server: fixture.endpoint.absoluteString))
        logoutReply.send(200, Data("{}".utf8))
        await logout.value
        XCTAssertNil(store.session)
        XCTAssertFalse(store.isTransitioningAccount)
    }

    @MainActor
    func testLateLoginCannotReplaceAccountDuringFailedDeletion() async throws {
        let fixture = AccountLifecycleFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let started = expectation(description: "Sign-in started")
        let deletionStarted = expectation(description: "Deletion started")
        let loginReply = DeferredAccountReply()
        let deletionReply = DeferredAccountReply()
        let sessionData = try JSONEncoder().encode(GuestSession(token: "new-token", participantID: "new-account", displayName: "New", authProvider: "apple"))
        fixture.respond { request, reply in
            switch request.url?.path {
            case "/v1/auth/apple": loginReply.install(reply); started.fulfill()
            case "/v1/account": deletionReply.install(reply); deletionStarted.fulfill()
            default: reply(200, Data("{}".utf8))
            }
        }
        let login = Task { try await store.signInWithApple(identityToken: "synthetic-identity", authorizationCode: "synthetic-code", challenge: fixture.challenge, endpoint: fixture.endpoint.absoluteString) }
        await fulfillment(of: [started], timeout: 2)
        let deletion = Task { try await store.deleteAccount() }
        await fulfillment(of: [deletionStarted], timeout: 2)
        XCTAssertNil(store.cloudPracticeConnection)
        loginReply.send(200, sessionData)
        do { try await login.value; XCTFail("The late login must not replace the account being deleted") }
        catch { XCTAssertTrue(error is CancellationError) }
        deletionReply.send(503, Data(#"{"error":"Deletion could not be confirmed"}"#.utf8))
        do { try await deletion.value; XCTFail("Expected deletion failure") }
        catch { XCTAssertEqual((error as? APIError)?.statusCode, 503) }
        XCTAssertEqual(store.session?.participantID, "old-account", "An unconfirmed deletion must not claim the old account disappeared.")
        XCTAssertEqual(SecureSessionStore.read(server: fixture.endpoint.absoluteString)?.participantID, "old-account")
        XCTAssertFalse(store.isTransitioningAccount)
    }

    @MainActor
    func testChallengeFromChangedConnectionCannotBeUsed() async throws {
        let fixture = AccountLifecycleFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let started = expectation(description: "Challenge request started")
        let pending = DeferredAccountReply()
        fixture.respond { _, reply in pending.install(reply); started.fulfill() }
        let task = Task { try await store.prepareAppleSignIn() }
        await fulfillment(of: [started], timeout: 2)
        store.connectionGeneration = UUID()
        pending.send(200, Data("{\"challengeID\":\"challenge\",\"nonce\":\"nonce\",\"expiresAt\":\(Date().timeIntervalSince1970 + 300)}".utf8))
        do { _ = try await task.value; XCTFail("A superseded challenge cannot be published") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testRevokedAppleCredentialClearsSessionAndKeychain() async {
        let fixture = AccountLifecycleFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.session?.localAppleUserID = "opaque-apple-user"
        fixture.respond { request, reply in
            switch request.url?.path {
            case "/v1/config": reply(200, Self.configuration)
            case "/v1/rooms": reply(200, Data(#"{"rooms":[]}"#.utf8))
            default: reply(200, Data("{}".utf8))
            }
        }
        await store.checkAppleCredentialState { userID in
            XCTAssertEqual(userID, "opaque-apple-user")
            return .revoked
        }
        XCTAssertNil(store.session)
        XCTAssertNil(store.cloudPracticeConnection)
        XCTAssertNil(SecureSessionStore.read(server: fixture.endpoint.absoluteString))
        XCTAssertNotNil(store.alertMessage)
    }

    @MainActor
    func testDelayedCredentialRevocationCannotSignOutANewerIdentity() async {
        let fixture = AccountLifecycleFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.session?.localAppleUserID = "previous-apple-user"
        let started = expectation(description: "Old Apple credential check started")
        let gate = CredentialLookupGate()
        let check = Task {
            await store.checkAppleCredentialState { _ in
                await withCheckedContinuation { continuation in
                    gate.continuation = continuation
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        store.connectionGeneration = UUID()
        store.session = GuestSession(token: "new-token", participantID: "new-account", displayName: "New", authProvider: "apple", localAppleUserID: "new-apple-user")
        gate.continuation?.resume(returning: .revoked)
        gate.continuation = nil
        await check.value
        XCTAssertEqual(store.session?.participantID, "new-account")
        XCTAssertNil(store.alertMessage)
    }

    @MainActor
    func testRevocationDuringFailedDeletionStillSignsOutAfterTheRequestEnds() async throws {
        let fixture = AccountLifecycleFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let started = expectation(description: "Deletion began")
        let loggedOut = expectation(description: "Revocation triggers logout after deletion fails")
        let pending = DeferredAccountReply()
        fixture.respond { request, reply in
            switch request.url?.path {
            case "/v1/account": pending.install(reply); started.fulfill()
            case "/v1/auth/logout": reply(200, Data("{}".utf8)); loggedOut.fulfill()
            case "/v1/config": reply(200, Self.configuration)
            case "/v1/rooms": reply(200, Data(#"{"rooms":[]}"#.utf8))
            default: reply(200, Data("{}".utf8))
            }
        }
        let deleting = Task { try await store.deleteAccount() }
        await fulfillment(of: [started], timeout: 2)
        await store.handleAppleCredentialRevocation()
        XCTAssertNil(SecureSessionStore.read(server: fixture.endpoint.absoluteString))
        XCTAssertNil(store.cloudPracticeConnection)
        pending.send(503, Data(#"{"error":"Deletion not confirmed"}"#.utf8))
        do { try await deleting.value; XCTFail("Expected unconfirmed deletion") } catch { }
        await fulfillment(of: [loggedOut], timeout: 2)
        // The cloud capability remains unavailable throughout the queued sign-out.
        XCTAssertNil(store.cloudPracticeConnection)
        XCTAssertNil(SecureSessionStore.read(server: fixture.endpoint.absoluteString))
    }

    private static var configuration: Data {
        Data(#"{"authenticationRequired":true,"appleSignInAvailable":true,"communityGuidelinesVersion":"2026-09-22"}"#.utf8)
    }
}

private final class DeferredAccountReply: @unchecked Sendable {
    typealias Reply = @Sendable (Int, Data) -> Void
    private let lock = NSLock()
    private var reply: Reply?
    func install(_ reply: @escaping Reply) { lock.withLock { self.reply = reply } }
    func send(_ code: Int, _ data: Data) {
        let pending = lock.withLock { let value = reply; reply = nil; return value }
        pending?(code, data)
    }
}

private final class AccountLifecycleFixture: @unchecked Sendable {
    let endpoint = URL(string: "https://\(UUID().uuidString.lowercased()).test")!
    let challenge = AppleSignInChallenge(challengeID: "test-challenge", nonce: "test-nonce", expiresAt: Date().timeIntervalSince1970 + 300)
    @MainActor func store() -> AppStore {
        let store = AppStore(historyLoader: { [] }, historyWriter: { _ in }) { url in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [AccountLifecycleProtocol.self]
            return RoomAPI(baseURL: url, configuration: config)
        }
        store.serverAddress = endpoint.absoluteString
        store.displayName = "Test user"
        store.serverConfiguration = ServerConfiguration(authenticationRequired: true, appleSignInAvailable: true, communityGuidelinesVersion: "2026-09-22")
        store.api = store.apiFactory(endpoint)
        let session = GuestSession(token: "old-token", participantID: "old-account", displayName: "Test user", authProvider: "apple")
        store.session = session
        store.api?.token = session.token
        SecureSessionStore.write(session, server: endpoint.absoluteString)
        return store
    }
    func respond(_ handler: @escaping AccountLifecycleProtocol.Handler) { AccountLifecycleProtocol.install(host: endpoint.host!, handler: handler) }
    func remove() { AccountLifecycleProtocol.remove(host: endpoint.host!); SecureSessionStore.remove(server: endpoint.absoluteString) }
}

private final class AccountLifecycleProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, @escaping DeferredAccountReply.Reply) -> Void
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private let state = NSLock()
    private var stopped = false
    static func install(host: String, handler: @escaping Handler) { lock.withLock { handlers[host] = handler } }
    static func remove(host: String) { _ = lock.withLock { handlers.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { lock.withLock { handlers[request.url?.host ?? ""] != nil } }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handlers[request.url?.host ?? ""] }) else { return }
        handler(request) { [weak self] status, data in
            guard let self, !self.state.withLock({ self.stopped }), let url = self.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { state.withLock { stopped = true } }
}

@MainActor private final class CredentialLookupGate {
    var continuation: CheckedContinuation<ASAuthorizationAppleIDProvider.CredentialState, Never>?
}
