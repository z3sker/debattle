#if DEBUG
import SwiftUI
import AVFoundation
import Observation

/// Isolated screenshot fixtures. This entire route is excluded from Release builds.
/// No fixture is sent to a server, saved in the journal, or presented as a real AI verdict.
struct UIAuditView: View {
    static var requestedScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--ui-audit"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    let screen: String
    @State private var store: AppStore
    private let room: DebateRoom

    init(screen: String) {
        self.screen = screen
        let room = Self.sampleRoom(status: screen == "lobby" ? "waiting" : screen == "preparation" ? "preparing" : ["live", "paused"].contains(screen) ? "live" : "finished")
        self.room = room
        let store = AppStore(historyLoader: { [] }, historyWriter: { _ in }, recoveryArchive: TranscriptRecoveryArchive(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("debattle-ui-audit-unused.json")))
        // Nil session prevents Explore's refresh loop from contacting the room server.
        if ["lobby", "preparation", "live", "paused", "finished", "report"].contains(screen) {
            store.session = GuestSession(token: "ui-audit-unused", participantID: "sample-gov", displayName: "Alex")
            store.activeRoom = room
            if screen == "paused" { store.activeRoom?.pausedRemainingSeconds = 184; store.activeRoom?.phaseEndsAt = nil }
        }
        if screen == "explore-populated" { store.rooms = [Self.sampleRoom(status: "waiting")] }
        if screen == "offline" { store.connectionMessage = "The room server is unavailable. Check your connection or the server address in Preferences. Formats and Practice are still available." }
        if screen == "journal" { store.completedDebates = [room] }
        _store = State(initialValue: store)
    }

    var body: some View {
        Group {
            if ["explore", "explore-populated", "offline", "formats", "practice", "profile", "journal"].contains(screen) {
                TabView(selection: .constant(tab)) {
                    Tab("Explore", systemImage: "safari", value: 0) { NavigationStack { ExploreView() } }
                    Tab("Formats", systemImage: "square.grid.2x2", value: 1) { NavigationStack { FormatsView() } }
                    Tab("Practice", systemImage: "waveform", value: 2) { NavigationStack { PracticeView() } }
                    Tab("You", systemImage: "person.crop.circle", value: 3) { NavigationStack { ProfileView() } }
                }
            } else {
                NavigationStack { content }
            }
        }
        .environment(store).tint(Design.accent)
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--audit-dark") ? .dark : .light)
        .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--audit-large-text") ? .accessibility3 : .large)
        .safeAreaInset(edge: .top, spacing: 0) {
            Text("UI AUDIT · SAMPLE DATA · \(screen)")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 3).background(Design.background)
                .accessibilityIdentifier("audit.marker")
        }
    }

    private var tab: Int {
        switch screen { case "formats": 1; case "practice": 2; case "profile", "journal": 3; default: 0 }
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case "welcome": WelcomeView(onContinue: {})
        case "create": CreateRoomView()
        case "invite": InviteView()
        case "join": JoinRoomView(room: Self.sampleRoom(status: "waiting"))
        case "format-detail": FormatDetailView(format: FormatCatalog.britishParliamentary)
        case "custom": CustomFormatView(initial: FormatCatalog.custom(), onSave: { _ in })
        case "lobby", "preparation", "live", "paused", "finished": LiveRoomView()
        case "schedule": ScrollView { TurnSchedule(format: FormatCatalog.britishParliamentary, currentIndex: 2).padding(22) }.navigationTitle("Speaking order")
        case "transcript": TranscriptView(room: room)
        case "transcript-empty": TranscriptView(room: nil)
        case "round": RoundResultsView(room: room)
        case "round-results": RoundResultsView(room: room, auditVerdict: Self.sampleVerdict(room))
        case "report": ReportView()
        case "settings": SettingsView()
        case "recovery": RecoveredSpeechView(speech: RecoveredTranscript(id: "sample-recovery", roomID: room.id, roomTitle: room.title, turnID: room.format.turns[0].id, turnLabel: "Opening speech", language: "English", participantID: "sample-gov", speakerName: "Alex", text: room.transcript[0].text, createdAt: room.createdAt))
        case "practice-live", "practice-error", "practice-feedback": UIAuditPracticeView(kind: screen)
        default: Text("Unknown audit screen")
        }
    }

    private static func sampleRoom(status: String) -> DebateRoom {
        let format = FormatCatalog.duel
        let members = [Participant(id: "sample-gov", displayName: "Alex", teamID: "gov", seatIndex: 0, isReady: true),
                       Participant(id: "sample-opp", displayName: "Samira", teamID: "opp", seatIndex: 0, isReady: true)]
        let gov = "Free public transport lowers the cost of getting to work and education. A city could fund a limited trial and compare ridership, travel times and public spending before expanding it. Better access matters most for people who cannot afford a car."
        let opp = "Affordable travel matters, but removing fares does not guarantee a reliable bus. Limited funding should first improve frequency and routes. Targeted discounts could help low-income riders while keeping resources available for a better service."
        let start = Date().timeIntervalSince1970 - 3_600
        return DebateRoom(id: "ui-audit-room", title: "This house would make public transport free.", language: "English", format: format,
            status: status, hostID: members[0].id, participants: members, createdAt: start,
            currentTurnIndex: status == "finished" ? format.turns.count - 1 : 0,
            phaseEndsAt: ["live", "preparing"].contains(status) ? Date().timeIntervalSince1970 + 184 : nil,
            inviteCode: "SAMPLEONLY0000001",
            transcript: status == "finished" ? format.turns.enumerated().map { index, turn in
                TranscriptSegment(id: "sample-text-\(index)", participantID: turn.teamID == "gov" ? members[0].id : members[1].id,
                                  turnID: turn.id, text: turn.teamID == "gov" ? gov : opp, createdAt: start + Double(index * 240))
            } : [], revision: 1, debateParticipants: status == "waiting" ? [] : members)
    }

    private static func sampleVerdict(_ room: DebateRoom) -> RoundVerdict {
        RoundVerdict(id: "ui-audit-verdict", roomID: room.id,
            summary: "Sample layout only: the opposition makes the stronger comparison between access and service reliability.",
            teamPlacements: [
                TeamPlacement(teamID: "opp", rank: 1, explanation: "Sample explanation: the response identifies a trade-off between removing fares and funding frequent services.", evidence: ["Limited funding should first improve frequency and routes."]),
                TeamPlacement(teamID: "gov", rank: 2, explanation: "Sample explanation: the trial gives a practical starting point, but its funding needs a clearer comparison.", evidence: ["Better access matters most for people who cannot afford a car."])
            ], speakerAssessments: [
                SpeakerAssessment(participantID: "sample-gov", argumentation: 18, engagement: 16, structure: 20, roleFulfilment: 19, explanation: "Sample feedback: the access argument is clear. Explain why a universal subsidy should take priority over improving routes.", evidence: ["Better access matters most for people who cannot afford a car."], improvement: "Compare the cost of your trial with an alternative use of the same funding."),
                SpeakerAssessment(participantID: "sample-opp", argumentation: 20, engagement: 21, structure: 19, roleFulfilment: 20, explanation: "Sample feedback: the response directly challenges the proposal’s mechanism and offers an alternative.", evidence: ["Limited funding should first improve frequency and routes."], improvement: "Explain who qualifies for discounts and how those riders would access them.")
            ], limitation: "UI TEST FIXTURE — these points and explanations were authored for layout review. No AI judged this sample.", createdAt: Date().timeIntervalSince1970)
    }
}

private struct UIAuditPracticeView: View {
    let kind: String
    @State private var practice: PracticeSession
    private let speech = UIAuditSpeechInput()

    init(kind: String) {
        self.kind = kind
        let practice = PracticeSession(voice: UIAuditVoiceInput(), transcriber: speech)
        if kind == "practice-error" {
            practice.message = "On-device transcription stopped. Your captured words have been kept below. Try again or paste a transcript."
            practice.transcript = "This is a sample recovered fragment for reviewing the error layout."
        }
        if kind == "practice-feedback" {
            practice.transcript = "Free transport lowers the cost of getting to work. A limited trial could measure ridership and service quality before expanding the policy."
            practice.feedback = JudgeFeedback(id: "ui-sample", summary: "Sample feedback: explain the funding behind your transport proposal.", strengths: ["A trial makes the proposal concrete."], improvements: ["Compare the trial with other uses of the same funding."], evidence: [JudgeEvidence(id: "sample-quote", quote: "A limited trial could measure ridership and service quality", explanation: "Sample observation: specify what change would count as a successful trial.", kind: "improvement")], limitation: "UI TEST FIXTURE — authored sample feedback; no AI generation.", sourceParticipantID: "sample", sourceTurnID: "sample-turn", speakerName: "Alex", reviewedCharacters: 153, totalCharacters: 153, createdAt: Date().timeIntervalSince1970)
        }
        _practice = State(initialValue: practice)
    }

    var body: some View {
        PracticeView(previewSession: practice)
            .task { if kind == "practice-live" { await practice.start() } }
    }
}

@MainActor @Observable private final class UIAuditVoiceInput: PracticeVoiceInput {
    var isMicrophoneEnabled = false
    var level: Float = 0 // The screenshot fixture never pretends to measure a real microphone.
    var errorMessage: String?
    func startMicrophone(onAudio: @escaping @Sendable (Data) -> Void, onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?) async throws { isMicrophoneEnabled = true }
    func stop() { isMicrophoneEnabled = false }
}

@MainActor @Observable private final class UIAuditSpeechInput: PracticeTranscribing {
    var partialText = ""
    var isRecording = false
    var errorMessage: String?
    func start(language: String) async throws {
        isRecording = true
        partialText = "Sample live transcript: a limited trial would let the city compare access, cost, and service quality."
    }
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {}
    func finish() async -> String { isRecording = false; return partialText }
    func cancel() { isRecording = false }
}
#endif
