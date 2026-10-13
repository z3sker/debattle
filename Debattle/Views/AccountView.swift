import SwiftUI
import AuthenticationServices

struct AccountSignInView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var challenge: AppleSignInChallenge?
    @State private var challengeEndpoint = ""
    @State private var acceptedRules = false
    @State private var busy = false
    @State private var message: String?
    @State private var preparationID = UUID()

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                BrandMark(size: 64)
                Text("Your voice.\nYour place at the table.")
                    .font(.system(.largeTitle, design: .rounded).bold()).tracking(-1)
                Text("Save your Debattle identity, join voice rooms, and use the shared AI allowance. Your public display name can be different from your real name.")
                    .foregroundStyle(.secondary)
                TextField("Display name", text: $store.displayName)
                    .textContentType(.nickname).autocorrectionDisabled()
                    .padding(16).background(Design.surface, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("account.displayName")
                VStack(alignment: .leading, spacing: 12) {
                    Text("Challenge ideas. Respect people.").font(.headline)
                    Text("No harassment, threats, hate, sexual content, or sharing someone’s private information. You can report and block people in every room.").font(.subheadline).foregroundStyle(.secondary)
                    Link("Read the community rules", destination: DebattleLinks.community)
                    Toggle("I agree to the community rules", isOn: $acceptedRules).font(.subheadline)
                }.cardStyle()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    SignInWithAppleButton(.continue) { request in
                        request.nonce = challenge?.nonce
                        request.state = challenge?.challengeID
                        request.requestedScopes = []
                        busy = true
                        message = nil
                    } onCompletion: { result in
                        Task { await complete(result) }
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 52).clipShape(RoundedRectangle(cornerRadius: 14))
                    .disabled(!acceptedRules || busy || challenge?.isUsable != true ||
                              !(2...30).contains(store.displayName.trimmingCharacters(in: .whitespacesAndNewlines).count))
                    .accessibilityIdentifier("account.appleSignIn")
                }
                if busy { ProgressView("Signing in…") }
                if let message { InfoBanner(text: message, icon: "info.circle") }
                if !busy, challenge?.isUsable != true {
                    Button("Prepare sign-in again") { preparationID = UUID() }
                }
                Text("Apple verifies your account. Debattle does not request your Apple email or password. Cloud AI asks for separate permission before sending speech to Groq.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 20) {
                    Link("Privacy", destination: DebattleLinks.privacy)
                    Link("Support", destination: DebattleLinks.support)
                }.font(.footnote)
            }.padding(24)
        }.background(Design.background).navigationTitle("Sign in").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .task(id: preparationID) {
                challenge = nil
                if store.serverConfiguration == nil { await store.connect() }
                let endpoint = store.serverAddress
                do {
                    let prepared = try await store.prepareAppleSignIn()
                    guard !Task.isCancelled, endpoint == store.serverAddress else { return }
                    challengeEndpoint = endpoint
                    challenge = prepared
                    message = nil
                } catch { if !Task.isCancelled { message = error.localizedDescription } }
            }
            .onChange(of: store.serverAddress) { _, _ in challenge = nil; preparationID = UUID() }
    }

    @MainActor private func complete(_ result: Result<ASAuthorization, Error>) async {
        defer { busy = false; challenge = nil }
        do {
            let authorization = try result.get()
            guard let challenge,
                  let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  credential.state == challenge.challengeID,
                  let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8),
                  let codeData = credential.authorizationCode, let code = String(data: codeData, encoding: .utf8) else {
                throw APIError(message: "Apple sign-in could not be verified. Please try again.")
            }
            try await store.signInWithApple(identityToken: token, authorizationCode: code,
                                            challenge: challenge, endpoint: challengeEndpoint, appleUserID: credential.user)
            dismiss()
        } catch let error as ASAuthorizationError where error.code == .canceled {
            message = "Sign-in was cancelled. You can keep browsing without an account."
        } catch { message = error.localizedDescription }
    }
}

struct SignInPrompt: View {
    @State private var showSignIn = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("A place for your voice", systemImage: "person.crop.circle").font(.headline)
            Text("Browse freely. Sign in to join or host a room and use cloud AI.").font(.subheadline).foregroundStyle(.secondary)
            Button("Sign in to Debattle") { showSignIn = true }.font(.subheadline.bold())
        }.cardStyle()
            .sheet(isPresented: $showSignIn) { NavigationStack { AccountSignInView() } }
    }
}
