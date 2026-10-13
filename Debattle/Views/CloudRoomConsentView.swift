import SwiftUI

struct CloudRoomConsentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "waveform.and.magnifyingglass").font(.largeTitle).foregroundStyle(Design.accent)
                Text("Let Groq help with this round.").font(.title2.bold())
                Text("Optional cloud AI works across Debattle’s languages without Apple Intelligence. Accuracy varies by language.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 16) {
                    Label("Your microphone audio is sent through Debattle’s server to Groq when you mute, pause, yield a point, or finish a turn.", systemImage: "mic")
                    Label("Recognized text is shared with room members and saved in the room record. Speech audio is held in memory during processing, not saved by Debattle.", systemImage: "text.bubble")
                    Label("For the round judge, Groq receives the motion, format and every consenting speaker’s transcript. Experimental scores explain arguments using actual quotations.", systemImage: "sparkles")
                    Label("You can turn this off here. Unsent audio is discarded when you leave, lose the connection or move the app into the background. Already processed information cannot be unsent.", systemImage: "hand.raised")
                }.font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Text("Groq has its own processing and retention terms. Shared free limits may pause AI. You can always debate by voice; without cloud permission, available on-device transcription is used.")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("Read Groq’s data policy", destination: URL(string: "https://console.groq.com/docs/your-data")!)
                    .font(.subheadline)
                if store.hasRoomCloudConsent {
                    PrimaryButton(title: "Keep Groq enabled", icon: "checkmark") { dismiss() }
                    Button("Turn off cloud AI for this room", role: .destructive) {
                        Task { await store.setRoomCloudConsent(false); if !store.hasRoomCloudConsent { dismiss() } }
                    }.disabled(store.isChangingCloudConsent)
                } else {
                    PrimaryButton(title: "Allow Groq for this room", icon: "cloud", busy: store.isChangingCloudConsent) {
                        Task { await store.setRoomCloudConsent(true); if store.hasRoomCloudConsent { dismiss() } }
                    }
                    Button("Continue without cloud AI") { dismiss() }.font(.subheadline)
                }
            }.padding(24)
        }.background(Design.background).navigationTitle("Cloud AI permission")
            .navigationBarTitleDisplayMode(.inline)
    }
}
