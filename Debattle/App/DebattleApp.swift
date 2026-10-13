import SwiftUI

@main
struct DebattleApp: App {
    @State private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let screen = UIAuditView.requestedScreen {
                    UIAuditView(screen: screen)
                } else { application }
                #else
                application
                #endif
            }
        }
    }

    private var application: some View {
        RootView()
            .environment(store)
            .tint(Design.accent)
            .onOpenURL { url in
                if url.scheme == "debattle", url.host == "join" {
                    store.pendingInvite = url.lastPathComponent
                }
            }
    }
}
