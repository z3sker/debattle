import SwiftUI

struct SolanaReceiptView: View {
    let room: DebateRoom
    @Environment(AppStore.self) private var store
    @State private var receipt: SolanaReceipt?
    @State private var exportURL: URL?
    @State private var verification: SolanaVerification?
    @State private var consent = false
    @State private var isWorking = false
    @State private var status = ""
    @State private var errorMessage: String?

    private var isCurrentMember: Bool {
        store.activeRoom?.id == room.id && room.participants.contains { $0.id == store.participantID }
    }
    private var canPublish: Bool { isCurrentMember && room.hostID == store.participantID && room.status == "finished" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Pill(title: "SOLANA DEVNET · EXPERIMENT", icon: "link")
                Text("A record you\ncan verify.")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text(room.title).font(.headline).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Label("What this proves", systemImage: "checkmark.seal").font(.headline)
                    Text("A public Solana transaction commits to a particular completed debate record. If the exported record changes later, its digital fingerprint will no longer match.")
                    Text("The Debattle server signs the transaction. This is not a participant wallet signature, proof of identity, proof that a debate was fair, or validation of an AI verdict.")
                        .foregroundStyle(.secondary)
                    Text("Devnet is a test network with no real-money payment. Its history can be reset.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.font(.subheadline).cardStyle()

                if let receipt {
                    receiptDetails(receipt)
                } else {
                    publishControls
                }

                if isWorking {
                    HStack { ProgressView(); Text(status).font(.subheadline) }
                        .accessibilityIdentifier("proof.progress")
                }
                if let errorMessage {
                    InfoBanner(text: errorMessage, icon: "exclamationmark.triangle")
                }
                if isCurrentMember {
                    Button("Refresh receipt") { Task { await loadReceipt() } }
                        .disabled(isWorking).accessibilityIdentifier("proof.refresh")
                }
            }.padding(22)
        }
        .background(Design.background)
        .navigationTitle("Verifiable record")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadReceipt() }
        .onChange(of: store.serverAddress) { _, _ in
            receipt = nil; exportURL = nil; verification = nil; consent = false
            errorMessage = "The server changed. Reopen this room before requesting its proof."
        }
    }

    private var publishControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            if canPublish {
                Text("Before publishing").font(.headline)
                Text("Only a salted fingerprint and protocol marker go on-chain. Your motion, transcript and speaker names stay off-chain. The exported receipt contains anonymous completion metadata and hashed source data.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("One immutable snapshot per room. Generate a cloud verdict before publishing if you want its digest included. Later transcript or verdict changes are not included. On-device verdicts are not included.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("I agree to publish this record’s fingerprint publicly on Solana devnet.", isOn: $consent)
                    .font(.subheadline).disabled(isWorking).accessibilityIdentifier("proof.consent")
                PrimaryButton(title: "Publish devnet proof", icon: "link.badge.plus") {
                    Task { await publish() }
                }.disabled(!consent || isWorking).accessibilityIdentifier("proof.publish")
            } else {
                InfoBanner(text: isCurrentMember
                    ? "The room host can publish a completed record. You can refresh here to view and verify its receipt."
                    : "Reconnect to this finished room to load its receipt. A local-only saved round cannot be published.")
            }
        }.cardStyle()
    }

    private func receiptDetails(_ receipt: SolanaReceipt) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Transaction confirmed on devnet", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(Design.accent).accessibilityIdentifier("proof.confirmed")
            Text("SHA-256 fingerprint").font(.caption).foregroundStyle(.secondary)
            Text(receipt.digest).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            DisclosureGroup("Server signer & transaction") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Server signer").font(.caption.bold())
                    Text(receipt.signer).textSelection(.enabled)
                    Text("Transaction").font(.caption.bold())
                    Text(receipt.signature).textSelection(.enabled)
                }.font(.system(.caption, design: .monospaced)).padding(.top, 8)
            }.font(.subheadline)
            Link(destination: receipt.explorerURL) {
                Label("View on Solana Explorer", systemImage: "arrow.up.right.square")
            }.accessibilityIdentifier("proof.explorer")
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Share verification receipt (.json)", systemImage: "square.and.arrow.up")
                }.accessibilityIdentifier("proof.share")
            }
            Text("Keep this file to verify the record later, even outside the room. It does not contain the transcript or speaker names.")
                .font(.caption).foregroundStyle(.secondary)
            Button { Task { await verify(receipt) } } label: {
                Label("Verify against Solana", systemImage: "checkmark.shield")
            }.disabled(isWorking).accessibilityIdentifier("proof.verify")
            if let verification {
                VStack(alignment: .leading, spacing: 6) {
                    Label(verification.verified ? "Record matches the chain" : "Verification failed",
                          systemImage: verification.verified ? "checkmark.shield.fill" : "xmark.shield.fill")
                        .font(.headline)
                    Text(verification.reason).font(.subheadline)
                    Text("The server checks the record hash, Memo instruction and signer against the transaction retrieved from Solana.")
                        .font(.caption).foregroundStyle(.secondary)
                }.accessibilityIdentifier("proof.verification")
            }
        }.cardStyle()
    }

    @MainActor private func loadReceipt() async {
        guard !isWorking, isCurrentMember, let connection = store.cloudPracticeConnection else { return }
        isWorking = true; status = "Loading the room receipt…"; errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await SolanaReceiptAPI(connection: connection).receipt(roomID: room.id)
            guard store.cloudPracticeConnection == connection else { return }
            try adopt(result)
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func publish() async {
        guard canPublish, consent, !isWorking, let connection = store.cloudPracticeConnection else { return }
        isWorking = true; status = "Waiting for Solana confirmation…"; errorMessage = nil
        defer { isWorking = false }
        do {
            guard let result = try await SolanaReceiptAPI(connection: connection).receipt(roomID: room.id, publish: true) else {
                throw APIError(message: "No confirmed transaction was returned. Refresh the receipt before trying again.")
            }
            guard store.cloudPracticeConnection == connection else { return }
            try adopt(result)
        } catch {
            errorMessage = error.localizedDescription + " If submission timed out, refresh the receipt before retrying."
        }
    }

    @MainActor private func verify(_ receipt: SolanaReceipt) async {
        guard !isWorking, let connection = store.cloudPracticeConnection else { return }
        isWorking = true; status = "Checking Solana and the record fingerprint…"; errorMessage = nil; verification = nil
        defer { isWorking = false }
        do {
            let result = try await SolanaReceiptAPI(connection: connection).verify(receipt)
            guard store.cloudPracticeConnection == connection else { return }
            verification = result
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func adopt(_ result: SolanaReceipt?) throws {
        receipt = result; verification = nil; exportURL = nil
        if let result {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Debattle-devnet-\(result.digest.prefix(12)).json")
            try result.data.write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url
        }
    }
}
