import Foundation
import Observation

@MainActor @Observable
final class CloudPracticeCoach: PracticeCoaching {
    let usesCloudProcessing = true
    private(set) var isAvailable = false
    private(set) var availabilityMessage = "Check cloud availability after connecting to your Debattle server."
    private(set) var isGenerating = false
    @ObservationIgnored private let api: CloudPracticeAPI
    @ObservationIgnored private var status: CloudPracticeStatus?
    @ObservationIgnored private var language: String?

    init(api: CloudPracticeAPI, status: CloudPracticeStatus? = nil) {
        self.api = api
        self.status = status
        refreshAvailability(language: nil)
    }

    func apply(status: CloudPracticeStatus) {
        self.status = status
        refreshAvailability(language: language)
    }

    func refreshAvailability(language: String?) {
        self.language = language
        guard let status else {
            isAvailable = false
            availabilityMessage = "Check cloud availability after connecting to your Debattle server."
            return
        }
        guard status.available else { isAvailable = false; availabilityMessage = status.message; return }
        if let language, (try? CloudPracticeAPI.languageCode(language)) == nil {
            isAvailable = false
            availabilityMessage = CloudPracticeError.unsupportedLanguage.localizedDescription
            return
        }
        isAvailable = true
        availabilityMessage = "Groq is enabled on this server. Feedback needs internet and available quota. Your transcript excerpt and motion are sent through your Debattle server. Language accuracy varies; no competitive rating."
    }

    func feedback(for room: DebateRoom, participantID: String?) async throws -> JudgeFeedback {
        try Task.checkCancellation()
        guard !isGenerating else { throw JudgeError.alreadyGenerating }
        refreshAvailability(language: room.language)
        guard isAvailable else { throw JudgeError.unavailable(availabilityMessage) }
        let available = room.transcript.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (participantID == nil || $0.participantID == participantID)
        }.sorted { $0.createdAt < $1.createdAt }
        guard let latest = available.last else { throw JudgeError.noTranscript }
        let source = available.filter { $0.participantID == latest.participantID && $0.turnID == latest.turnID }
            .map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.count >= 80 else { throw JudgeError.tooLittleSpeech }
        isGenerating = true
        defer { isGenerating = false }
        let response = try await api.feedback(motion: room.title, language: room.language, transcript: source)
        try Task.checkCancellation()
        try CloudPracticeAPI.validate(response, source: source)
        let evidence = response.strengths.map { JudgeEvidence(id: UUID().uuidString, quote: $0.quote, explanation: $0.explanation, kind: "strength") }
            + response.improvements.map { JudgeEvidence(id: UUID().uuidString, quote: $0.quote, explanation: $0.explanation, kind: "improvement") }
        let speaker = (room.participants + room.debateParticipants).first { $0.id == latest.participantID }?.displayName ?? "Speaker"
        return JudgeFeedback(id: UUID().uuidString, summary: response.summary,
                             strengths: response.strengths.map(\.explanation), improvements: response.improvements.map(\.explanation),
                             evidence: evidence,
                             limitation: "Experimental Groq cloud coaching (\(response.model)). Only the first \(response.reviewedText.count) of \(source.count) transcript characters were reviewed. Transcription can be inaccurate, especially across languages. Quotations are checked against the transcript, not independently fact-checked. This is not a full debate verdict or an assessment of vocal delivery; it does not affect ratings.",
                             sourceParticipantID: latest.participantID, sourceTurnID: latest.turnID, speakerName: speaker,
                             reviewedCharacters: response.reviewedText.count, totalCharacters: source.count,
                             createdAt: Date().timeIntervalSince1970)
    }
}
