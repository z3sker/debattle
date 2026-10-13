import SwiftUI

struct RoundResultsView: View {
    let room: DebateRoom
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var useCloud = true
    @State private var cloudProgress: CloudRoomJudgeStatus?
    @State private var reviewedRoom: DebateRoom?
    @State private var showCloudConsent = false
    @State private var activeCloudAPI: CloudRoomAPI?
    @State private var judge = RoundJudge()
    @State private var verdict: RoundVerdict?
    @State private var errorMessage: String?
    @State private var judgingTask: Task<Void, Never>?

    init(room: DebateRoom) {
        self.room = room
        _verdict = State(initialValue: RoundVerdictArchive.load(room: room))
    }

    #if DEBUG
    init(room: DebateRoom, auditVerdict: RoundVerdict) {
        self.room = room
        _verdict = State(initialValue: auditVerdict)
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Pill(title: "EXPERIMENTAL · UNRANKED", icon: "sparkles")
                Text("Every verdict\nneeds a reason.")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold)).tracking(-1)
                Text(room.title).font(.headline).foregroundStyle(.secondary)
                if room.status == "finished" {
                    NavigationLink { SolanaReceiptView(room: reviewedRoom ?? room) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Label("Verifiable record", systemImage: "link.badge.plus").font(.headline)
                            Text("Publish or verify a record fingerprint on Solana devnet.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                    }.buttonStyle(.plain).accessibilityIdentifier("round.solanaProof")
                }
                if let verdict {
                    results(verdict)
                } else {
                    preparation
                }
                if let errorMessage { InfoBanner(text: errorMessage, icon: "exclamationmark.bubble") }
                NavigationLink { TranscriptView(room: reviewedRoom ?? room) } label: {
                    Label("Review the source transcript", systemImage: "text.alignleft").font(.subheadline.bold())
                }
            }.padding(22)
        }.background(Design.background)
            .navigationTitle("Round verdict").navigationBarTitleDisplayMode(.inline)
            .onDisappear { cancelJudging() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { cancelJudging() } }
            .sheet(isPresented: $showCloudConsent) { NavigationStack { CloudRoomConsentView() } }
            .onChange(of: room.transcript) { _, _ in
                cancelJudging()
                verdict = RoundVerdictArchive.load(room: room)
                errorMessage = "The transcript changed. Review the updated record before generating a new verdict."
            }
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Label("All teams, compared", systemImage: "person.2").font(.headline)
                Text(useCloud ? "Groq processes every submitted speech, then compares the teams. You’ll receive team placements, practice points, and explanations linked to speech quotations. All speakers must allow cloud AI." : "Apple’s on-device model processes each submitted speech, then compares the teams. This requires a supported device, language and enabled Apple Intelligence.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Divider()
                Text("A complete transcript is required. Summarization and transcription can miss nuance; this verdict has not been calibrated against expert human judges.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.cardStyle()
            Picker("Judge provider", selection: $useCloud) {
                Text("Groq cloud").tag(true)
                Text("On device").tag(false)
            }.pickerStyle(.segmented).disabled(judgingTask != nil)
            if judgingTask != nil {
                VStack(alignment: .leading, spacing: 12) {
                    if useCloud, let cloudProgress, cloudProgress.totalSteps > 0 {
                        ProgressView(value: Double(cloudProgress.completedSteps), total: Double(cloudProgress.totalSteps))
                    } else if let fraction = judge.progressFraction { ProgressView(value: fraction) }
                    else { ProgressView() }
                    Text(useCloud ? (cloudProgress?.message ?? "Starting the cloud judge…") : judge.progress).font(.subheadline.weight(.medium))
                    Text("Keep Debattle open. Larger rounds may take several minutes.").font(.caption).foregroundStyle(.secondary)
                    Button("Cancel judging", role: .cancel) { cancelJudging() }.font(.footnote)
                }.cardStyle()
            } else {
                PrimaryButton(title: useCloud ? "Judge with Groq" : "Judge on this device", icon: "sparkles") { startJudging() }
                    .disabled(useCloud && store.activeRoom?.id != room.id)
                if useCloud {
                    if store.activeRoom?.id != room.id {
                        InfoBanner(text: "Cloud judging requires current room membership. Generate and save a Groq verdict before leaving a finished room. Your saved transcript remains available for on-device review.")
                    }
                    Text("The server reviews the complete submitted transcript. Long rounds can take several minutes under the shared free allowance. No public rating changes.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if store.activeRoom?.id == room.id, !store.hasRoomCloudConsent {
                        Button("Review cloud AI permission") { showCloudConsent = true }.font(.subheadline)
                    }
                }
            }
        }
    }

    private func results(_ verdict: RoundVerdict) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(verdict.summary).font(.title3.weight(.semibold))
            InfoBanner(text: verdict.limitation, icon: "info.circle")
            SectionHeading(title: "Team placements", subtitle: "A comparison of the arguments in this round.")
            ForEach(verdict.teamPlacements.sorted { $0.rank < $1.rank }, id: \.teamID) { placement in
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 13) {
                        Text("\(placement.rank)").font(.system(size: 25, weight: .bold, design: .rounded))
                            .foregroundStyle(Design.accent).frame(width: 49, height: 49)
                            .background(Design.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 17))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(room.format.teams.first { $0.id == placement.teamID }?.name ?? placement.teamID).font(.headline)
                            Text(placement.rank == 1 ? "First in this assessment" : "Place \(placement.rank)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(placement.explanation).font(.subheadline)
                    evidenceDisclosure(placement.evidence)
                }.cardStyle()
            }
            SectionHeading(title: "Speaker feedback", subtitle: "Debattle practice points · 100 possible · not a tournament speaker scale")
            ForEach(verdict.speakerAssessments, id: \.participantID) { assessment in
                speakerCard(assessment)
            }
            Text("This result is saved on your device. Practice points do not change a public rating or leaderboard.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func speakerCard(_ assessment: SpeakerAssessment) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text((room.participants + room.debateParticipants).first { $0.id == assessment.participantID }?.displayName ?? "Speaker").font(.headline)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(assessment.points)").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Design.accent)
                    Text("/100").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(assessment.explanation).font(.subheadline)
            VStack(spacing: 12) {
                scoreRow("Argumentation", value: assessment.argumentation)
                scoreRow("Engagement", value: assessment.engagement)
                scoreRow("Structure", value: assessment.structure)
                scoreRow("Role fulfilment", value: assessment.roleFulfilment)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Try this next").font(.subheadline.bold()).foregroundStyle(Design.accent)
                Text(assessment.improvement).font(.subheadline).foregroundStyle(.secondary)
            }
            evidenceDisclosure(assessment.evidence, participantID: assessment.participantID)
        }.cardStyle()
    }

    private func scoreRow(_ label: String, value: Int) -> some View {
        VStack(spacing: 5) {
            HStack { Text(label); Spacer(); Text("\(value)/25").monospacedDigit() }.font(.caption)
            ProgressView(value: Double(value), total: 25).tint(Design.purple)
        }
    }

    private func evidenceDisclosure(_ quotes: [String], participantID: String? = nil) -> some View {
        DisclosureGroup("Speech evidence") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(quotes.enumerated()), id: \.offset) { _, quote in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("“\(quote)”").font(.footnote.italic())
                        let sources = evidenceSources(for: quote, participantID: participantID)
                        if !sources.isEmpty {
                            Text((sources.count > 1 ? "Source matches:\n" : "") + sources.joined(separator: "\n"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.top, 10)
        }.font(.subheadline.weight(.medium))
    }

    private func evidenceSources(for quote: String, participantID: String?) -> [String] {
        guard let prepared = try? RoundJudgeValidation.prepare(reviewedRoom ?? room) else { return [] }
        return prepared.sources.filter {
            (participantID == nil || $0.participantID == participantID)
                && RoundJudgeValidation.exactQuote(quote, in: $0.text)
        }.map { source in
            let name = prepared.speakers.first { $0.id == source.participantID }?.displayName ?? "Speaker"
            let turn = room.format.turns.first { $0.id == source.turnID }?.label ?? "Speech"
            return name + " · " + turn + (source.isPOI ? " · POI" : "")
        }
    }

    private func cancelJudging() {
        judgingTask?.cancel()
        if let api = activeCloudAPI {
            activeCloudAPI = nil
            Task { await api.cancelJudge(roomID: room.id) }
        }
    }

    private func startJudging() {
        guard judgingTask == nil else { return }
        errorMessage = nil
        cloudProgress = nil
        judgingTask = Task { @MainActor in
            defer { judgingTask = nil; activeCloudAPI = nil }
            do {
                let result: RoundVerdict
                if useCloud {
                    guard let connection = store.cloudPracticeConnection else { throw CloudRoomError.connection }
                    let api = CloudRoomAPI(connection: connection)
                    activeCloudAPI = api
                    var status = try await api.judge(roomID: room.id)
                    while status.state == "running" {
                        try Task.checkCancellation()
                        cloudProgress = status
                        try await Task.sleep(for: .seconds(2))
                        status = try await api.judge(roomID: room.id, method: "GET")
                    }
                    try Task.checkCancellation()
                    guard status.state == "complete" else {
                        switch status.code {
                        case "quota": throw CloudRoomError.quota
                        case "consent": throw CloudRoomError.consentRequired
                        case "incomplete": throw RoundJudgeError.incomplete("Every scheduled speech must have a usable transcript.")
                        case "cancelled": throw CancellationError()
                        default: throw RoundJudgeError.unavailable(status.message.isEmpty ? "The cloud judge could not finish. No verdict was saved." : status.message)
                        }
                    }
                    let checked = try CloudRoomAPI.validate(status, roomID: room.id)
                    reviewedRoom = checked.room
                    store.saveHistory(checked.room)
                    result = checked.verdict
                } else {
                    result = try await judge.judge(room)
                }
                try Task.checkCancellation()
                try RoundVerdictArchive.save(result)
                verdict = result
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

enum RoundVerdictArchive {
    private static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("DebattleVerdicts", isDirectory: true)
    }
    private static func fileURL(roomID: String) -> URL {
        // Room IDs are server-generated, but sanitization also protects locally constructed snapshots.
        let name = Data(roomID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return directory.appendingPathComponent(name + ".json")
    }
    static func load(room: DebateRoom) -> RoundVerdict? {
        guard let data = try? Data(contentsOf: fileURL(roomID: room.id)),
              let verdict = try? JSONDecoder().decode(RoundVerdict.self, from: data),
              let digest = try? RoundJudgeValidation.transcriptDigest(room),
              verdict.transcriptDigest == digest else { return nil }
        return verdict
    }
    static func save(_ verdict: RoundVerdict) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(verdict).write(to: fileURL(roomID: verdict.roomID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func clear() {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
