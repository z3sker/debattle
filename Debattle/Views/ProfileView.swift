import SwiftUI
import UIKit

struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @State private var showSettings = false
    @State private var confirmClear = false
    @State private var confirmSignOut = false
    @State private var confirmDeleteAccount = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack(spacing: 18) {
                    Text(String((store.session?.displayName ?? store.displayName).prefix(1)).uppercased())
                        .font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Design.accent)
                        .frame(width: 76, height: 76).background(Design.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 27))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(store.session?.displayName ?? (store.displayName.isEmpty ? "Your corner" : store.displayName)).font(.title2.bold())
                        Pill(title: store.session?.authProvider == "apple" ? "Debattle member" : "Welcome", icon: "sparkle")
                    }
                    Spacer()
                }
                Text("Every conversation\nis a chance to grow.").font(.system(.title, design: .rounded).weight(.bold)).tracking(-0.8)
                if store.session?.authProvider != "apple" { SignInPrompt() }
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(store.completedDebates.count)").font(.system(size: 35, weight: .bold, design: .rounded))
                        Text("Saved rounds").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.preferredLanguage).font(.headline)
                        Text("Preferred language").font(.caption).foregroundStyle(.secondary)
                    }
                }.cardStyle()
                SectionHeading(title: "Your debate journal")
                if store.completedDebates.isEmpty {
                    EmptyCard(icon: "book.closed", title: "Your story starts here", message: "Completed rounds will appear here, with their transcripts. There’s no rush to be an expert.")
                } else {
                    ForEach(store.completedDebates) { room in
                        NavigationLink { TranscriptView(room: room) } label: { RoomCard(room: room) }.buttonStyle(.plain)
                    }
                    Button("Clear saved rounds", role: .destructive) { confirmClear = true }.font(.footnote)
                }
                InfoBanner(text: "Competitive ratings will arrive after the judge is calibrated against human adjudicators. For now, focus on practice and thoughtful feedback.", icon: "chart.line.uptrend.xyaxis")
                if !store.recoveredTranscripts.isEmpty || store.recoveryMessage != nil {
                    SectionHeading(title: "Recovered speeches", subtitle: "Local copies with unconfirmed uploads.")
                    if let message = store.recoveryMessage { InfoBanner(text: message, icon: "tray.and.arrow.down") }
                    ForEach(store.recoveredTranscripts) { speech in
                        NavigationLink { RecoveredSpeechView(speech: speech) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("LOCAL RECOVERY", systemImage: "doc.text").font(.caption.bold()).foregroundStyle(Design.accent)
                                Text(speech.roomTitle).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                Text("\(speech.turnLabel) · \(speech.language)").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                        }.buttonStyle(.plain)
                    }
                }
                Button { showSettings = true } label: {
                    HStack { Label("Preferences & privacy", systemImage: "slider.horizontal.3"); Spacer(); Image(systemName: "chevron.right").font(.caption) }.font(.subheadline.weight(.medium)).cardStyle()
                }.buttonStyle(.plain)
                if store.session?.authProvider == "apple" {
                    VStack(alignment: .leading, spacing: 18) {
                        Button("Sign out") { confirmSignOut = true }
                        Button("Delete my account", role: .destructive) { confirmDeleteAccount = true }
                    }.font(.subheadline).disabled(store.isWorking)
                }
                Text("DEBATTLE\nBuilt for ideas worth talking about.")
                    .font(.system(size: 10, weight: .medium)).tracking(1).foregroundStyle(.tertiary).frame(maxWidth: .infinity).multilineTextAlignment(.center)
            }.padding(22)
        }.background(Design.background).navigationTitle("Your corner").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
            .confirmationDialog("Clear saved rounds from this device?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear saved rounds", role: .destructive) { do { try LocalDebateArchive.clear(); store.completedDebates = []; RoundVerdictArchive.clear() }
                    catch { store.alertMessage = error.localizedDescription } }
            } message: { Text("This removes the local journal. Recovery copies remain until deleted in Recovered speeches. Server data follows the retention policy; deleting your account removes your server-held speech data.") }
            .confirmationDialog("Sign out of Debattle?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out") { Task { await store.signOut() } }
            } message: { Text("You will leave any active room. Saved rounds remain on this device.") }
            .confirmationDialog("Permanently delete your account?", isPresented: $confirmDeleteAccount, titleVisibility: .visible) {
                Button("Delete account and speech data", role: .destructive) {
                    Task { do { try await store.deleteAccount() } catch { store.alertMessage = error.localizedDescription } }
                }
            } message: {
                Text("This removes your Debattle account, server-held speeches, memberships, and local journal and recovery copies. Copies previously saved by other participants are outside Debattle’s control. Deletion cannot be undone.")
            }
    }
}

struct RecoveredSpeechView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let speech: RecoveredTranscript
    @State private var copied = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Pill(title: "LOCAL RECOVERY · UPLOAD UNCONFIRMED", icon: "doc.text")
                Text(speech.roomTitle).font(.title2.bold())
                Text("\(speech.speakerName) · \(speech.turnLabel) · \(speech.language)").font(.subheadline).foregroundStyle(.secondary)
                Text(Date(timeIntervalSince1970: speech.createdAt), format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                InfoBanner(text: "This is a full local copy of your captured speech. Some or all of it may already be in the room transcript. It is not added to round results, and Debattle will not automatically resubmit it.", icon: "info.circle")
                Text(speech.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                PrimaryButton(title: copied ? "Speech copied" : "Copy speech", icon: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = speech.text
                    copied = true
                }
                Button("Delete local copy", role: .destructive) { confirmDelete = true }.font(.subheadline)
                if let message = store.recoveryMessage { InfoBanner(text: message, icon: "exclamationmark.bubble") }
            }.padding(22)
        }.background(Design.background).navigationTitle("Recovered speech").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Delete this recovery copy?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete local copy", role: .destructive) {
                    if store.deleteRecoveredTranscript(id: speech.id) { dismiss() }
                }
            } message: { Text("Copy any text you want to keep first. This only removes the copy on this device; it does not change the room transcript.") }
    }
}

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    var body: some View {
        @Bindable var store = store
        Form {
            Section("Your preferences") {
                Picker("Debate language", selection: $store.preferredLanguage) { ForEach(debateLanguages, id: \.self) { Text($0) } }
                LabeledContent("Display name", value: store.session?.displayName ?? store.displayName)
            }
            #if DEBUG
            Section {
                TextField("Server address", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("settings.server")
                Button("Save and connect") {
                    store.serverAddress = server.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await store.resetConnection() }
                }.disabled(store.isLoading || store.activeRoom != nil)
                if store.isLoading { ProgressView("Connecting…") }
                else if let message = store.connectionMessage { Text(message).font(.footnote).foregroundStyle(Design.orange) }
                else if store.session != nil { Label("Connected to the room server", systemImage: "checkmark.circle").foregroundStyle(Design.green).font(.footnote) }
            } header: { Text("Beta server") } footer: {
                Text("On this Mac’s simulator, use http://localhost:8787. A physical iPhone needs the Mac’s Wi-Fi address or a hosted HTTPS server. Public rooms are shared among people connected to the same server.")
            }
            #endif
            Section("Privacy") {
                Label("Microphone opens only with your action", systemImage: "mic")
                Label("Room audio is relayed without saving it", systemImage: "waveform")
                Label("Cloud AI requires your permission", systemImage: "hand.raised")
                Label("Room members can review transcripts", systemImage: "text.bubble")
                Label("Groq supports speech and feedback", systemImage: "cloud")
                Text("With your permission, Debattle sends speech recordings and requested feedback through its server to Groq. Practice audio and text are not saved by the server. Debate transcripts are shared with room participants and follow our retention policy. Groq’s retention policy also applies.")
                Link("Debattle privacy policy", destination: DebattleLinks.privacy)
                Link("Groq data policy", destination: URL(string: "https://console.groq.com/docs/your-data")!)
            }.font(.footnote)
            Section("Help & community") {
                Link("Support and report a concern", destination: DebattleLinks.support)
                Link("Community rules", destination: DebattleLinks.community)
            }
            Section {
                Text("English, Russian, Spanish, and Kazakh rooms are supported. Groq requires internet and available shared allowance; transcription and feedback quality vary by language. Apple processing depends on device and language availability. Audio is never silently switched to a cloud provider.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Preferences").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { server = store.serverAddress }
    }
}
