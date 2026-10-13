import SwiftUI
import AuthenticationServices

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasCompletedWelcome") private var hasCompletedWelcome = false
    @State private var showRoom = false
    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.selectedTab) {
            Tab("Explore", systemImage: "safari", value: 0) { NavigationStack { ExploreView() } }
            Tab("Formats", systemImage: "square.grid.2x2", value: 1) { NavigationStack { FormatsView() } }
            Tab("Practice", systemImage: "waveform", value: 2) { NavigationStack { PracticeView() } }
            Tab("You", systemImage: "person.crop.circle", value: 3) { NavigationStack { ProfileView() } }
        }
        .sheet(isPresented: Binding(get: { !hasCompletedWelcome }, set: { _ in })) {
            WelcomeView { hasCompletedWelcome = true; Task { await store.connect() } }
                .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $showRoom) { NavigationStack { LiveRoomView() } }
        .task(id: store.activeRoom?.id) {
            if store.activeRoom != nil { try? await Task.sleep(for: .milliseconds(500)); if !Task.isCancelled { showRoom = true } }
            else { showRoom = false }
        }
        .onChange(of: showRoom) { _, newValue in
            if !newValue, store.activeRoom != nil { Task { await store.leaveRoom() } }
        }
        .alert("Debattle", isPresented: Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })) {
            Button("OK", role: .cancel) { store.alertMessage = nil }
        } message: { Text(store.alertMessage ?? "") }
        .task {
            if hasCompletedWelcome { await store.connect(); await store.checkAppleCredentialState() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.checkAppleCredentialState() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
            Task { await store.handleAppleCredentialRevocation() }
        }
    }
}

struct WelcomeView: View {
    @Environment(AppStore.self) private var store
    var onContinue: () -> Void
    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                BrandMark(size: 66).padding(.top, 38)
                Text("A place for\nbetter arguments.").font(.system(.largeTitle, design: .rounded).weight(.bold)).tracking(-1.5)
                Text("Find your people. Challenge an idea.\nLeave with a new perspective.")
                    .font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 16) {
                    Label("Real conversations, voice only", systemImage: "waveform")
                    Label("Public rooms and private invitations", systemImage: "person.2")
                    Label("Your format. Your language.", systemImage: "slider.horizontal.3")
                }.font(.subheadline.weight(.medium)).padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text("What should we call you?").font(.subheadline.bold())
                    TextField("Your display name", text: $store.displayName).textContentType(.nickname)
                        .padding(16).background(Design.surface, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("welcome.name")
                    Picker("Preferred language", selection: $store.preferredLanguage) {
                        ForEach(debateLanguages, id: \.self) { Text($0) }
                    }.pickerStyle(.menu).padding(.top, 4)
                }
                PrimaryButton(title: "Find your voice", icon: "arrow.right", action: onContinue)
                    .disabled(!(2...30).contains(store.displayName.trimmingCharacters(in: .whitespacesAndNewlines).count))
                    .accessibilityIdentifier("welcome.continue")
                Text("Be curious. Challenge ideas, respect people.\nBrowse first, then sign in when you’re ready to join.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }.background(Design.background)
    }
}
