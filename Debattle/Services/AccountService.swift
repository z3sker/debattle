import Foundation
import AuthenticationServices

struct ServerConfiguration: Codable, Sendable, Equatable {
    let authenticationRequired: Bool
    let appleSignInAvailable: Bool
    let communityGuidelinesVersion: String
}

struct AppleSignInChallenge: Decodable, Sendable {
    let challengeID: String
    let nonce: String
    let expiresAt: Double

    var isUsable: Bool {
        !challengeID.isEmpty && !nonce.isEmpty && expiresAt > Date().timeIntervalSince1970 + 5
    }
}

enum DebattleLinks {
    static let website = URL(string: "https://debattle.mans.team")!
    static let privacy = website.appendingPathComponent("privacy")
    static let support = website.appendingPathComponent("support")
    static let community = website.appendingPathComponent("community")
}

@MainActor
extension AppStore {
    func prepareAppleSignIn() async throws -> AppleSignInChallenge {
        guard !isTransitioningAccount, !isWorking, let api, serverConfiguration?.appleSignInAvailable == true else {
            throw APIError(message: "Sign in is temporarily unavailable. Please try connecting again shortly.")
        }
        let generation = connectionGeneration
        let endpoint = serverAddress
        let challenge: AppleSignInChallenge = try await api.request("v1/auth/apple/challenge", method: "POST", body: [:])
        guard connectionGeneration == generation, self.api === api, endpoint == serverAddress, !Task.isCancelled else { throw CancellationError() }
        guard challenge.isUsable else { throw APIError(message: "The sign-in request expired. Please try again.") }
        return challenge
    }

    func signInWithApple(identityToken: String, authorizationCode: String,
                         challenge: AppleSignInChallenge, endpoint: String, appleUserID: String? = nil) async throws {
        guard !isWorking, !isLoading, !isTransitioningAccount, activeRoom == nil, let api, endpoint == serverAddress,
              let configuration = serverConfiguration, configuration.appleSignInAvailable else {
            throw APIError(message: "Your connection changed. Please start sign-in again.")
        }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...30).contains(name.count) else { throw APIError(message: "Choose a display name between 2 and 30 characters.") }
        let generation = UUID()
        connectionGeneration = generation
        var signedIn: GuestSession = try await api.request("v1/auth/apple", method: "POST", body: [
            "challengeID": challenge.challengeID, "identityToken": identityToken,
            "authorizationCode": authorizationCode, "displayName": name,
            "communityGuidelinesVersion": configuration.communityGuidelinesVersion
        ])
        guard connectionGeneration == generation, endpoint == serverAddress, !Task.isCancelled else {
            let abandoned = apiFactory(api.baseURL)
            abandoned.token = signedIn.token
            let _: RoomAPI.Acknowledgement? = try? await abandoned.request("v1/auth/logout", method: "POST", body: [:])
            throw CancellationError()
        }
        guard signedIn.authProvider == "apple", !signedIn.token.isEmpty, !signedIn.isExpired else {
            throw APIError(message: "Your account could not be verified. Please try signing in again.")
        }
        signedIn.localAppleUserID = appleUserID
        SecureSessionStore.write(signedIn, server: endpoint)
        await resetConnection()
        guard session?.participantID == signedIn.participantID else {
            throw APIError(message: connectionMessage ?? "Your account was verified, but the connection was interrupted. Please reconnect.")
        }
    }

    func signOut(force: Bool = false) async {
        guard (!isWorking || force), !isTransitioningAccount else { return }
        isWorking = true
        isTransitioningAccount = true
        connectionGeneration = UUID() // Invalidate an in-flight sign-in before the first suspension.
        isLoading = false
        cancelCloudRoomWork()
        defer { finishAccountTransition() }
        let client = api
        let endpoint = serverAddress
        SecureSessionStore.remove(server: endpoint)
        await leaveRoom()
        var revocationFailed = false
        if let client, session != nil {
            do { let _: RoomAPI.Acknowledgement = try await client.request("v1/auth/logout", method: "POST", body: [:]) }
            catch { revocationFailed = true }
        }
        SecureSessionStore.remove(server: endpoint)
        connectionGeneration = UUID()
        session = nil
        api = nil
        rooms = []
        await connect()
        if revocationFailed { alertMessage = "You are signed out on this device. The server could not confirm revocation; the previous session will expire automatically." }
    }

    func handleAppleCredentialRevocation() async {
        guard session?.authProvider == "apple" else { pendingAppleCredentialRevocation = false; return }
        if isTransitioningAccount {
            pendingAppleCredentialRevocation = true
            SecureSessionStore.remove(server: serverAddress)
            cancelCloudRoomWork()
            return
        }
        pendingAppleCredentialRevocation = false
        // Apple's notification itself confirms revocation; do not wait for another
        // credential lookup that could fail while the device is offline.
        await signOut(force: true)
        alertMessage = "Apple sign-in was revoked. Your microphone was stopped. Sign in again to continue."
    }

    private func finishAccountTransition() {
        isWorking = false
        isTransitioningAccount = false
        if pendingAppleCredentialRevocation {
            // Deletion may fail; a revocation arriving during that request still has
            // to sign the local user out once the in-flight transition finishes.
            Task { await handleAppleCredentialRevocation() }
        }
    }

    /// The local opaque Apple identifier is used only with Apple's credential API.
    /// An old callback must never sign out a newer account or a different endpoint.
    func checkAppleCredentialState(
        using lookup: @MainActor (String) async throws -> ASAuthorizationAppleIDProvider.CredentialState = {
            try await ASAuthorizationAppleIDProvider().credentialState(forUserID: $0)
        }
    ) async {
        guard !isTransitioningAccount, let current = session, current.authProvider == "apple",
              let userID = current.localAppleUserID, !userID.isEmpty else { return }
        let generation = connectionGeneration
        let endpoint = serverAddress
        do {
            let state = try await lookup(userID)
            guard !Task.isCancelled, connectionGeneration == generation, endpoint == serverAddress,
                  session?.token == current.token, session?.localAppleUserID == userID else { return }
            switch state {
            case .authorized: return
            case .revoked, .notFound, .transferred:
                await signOut(force: true)
                alertMessage = "Apple sign-in is no longer authorized for this account. Your microphone was stopped. Sign in again to continue."
            @unknown default: return
            }
        } catch {
            // A temporary Apple credential-service failure is not evidence of revocation.
            // The server still independently enforces its session expiration and suspension.
        }
    }

    func deleteAccount() async throws {
        guard !isWorking, let client = api, session != nil else {
            throw APIError(message: "Sign in before deleting your account.")
        }
        isWorking = true
        isTransitioningAccount = true
        connectionGeneration = UUID()
        isLoading = false
        cancelCloudRoomWork()
        defer { finishAccountTransition() }
        let endpoint = serverAddress
        await leaveRoom()
        let _: RoomAPI.Acknowledgement = try await client.request("v1/account", method: "DELETE", body: ["confirmation": "DELETE"])
        SecureSessionStore.remove(server: endpoint)
        connectionGeneration = UUID()
        session = nil
        api = nil
        rooms = []
        displayName = ""
        var localFailure = false
        do { try LocalDebateArchive.clear(); completedDebates = [] }
        catch { localFailure = true }
        RoundVerdictArchive.clear()
        for speech in recoveredTranscripts {
            if !deleteRecoveredTranscript(id: speech.id) { localFailure = true }
        }
        await connect()
        if localFailure { alertMessage = "Your server account was deleted. Some local journal or recovery files could not be removed; you can remove them in Your corner." }
    }
}
