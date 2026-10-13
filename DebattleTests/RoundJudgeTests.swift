import Foundation
import XCTest
@testable import Debattle

final class RoundJudgeTests: XCTestCase {
    func testCompleteRoundIncludesEveryScheduledSpeech() throws {
        let room = completeRoom()
        let round = try RoundJudgeValidation.prepare(room, now: 2_000)
        XCTAssertEqual(round.speakers.count, 2)
        XCTAssertEqual(round.sources.count, 4)
        XCTAssertEqual(Set(round.sources.map(\.turnID)), Set(room.format.turns.map(\.id)))
        XCTAssertNoThrow(try RoundJudgeValidation.validate(validVerdict(round), against: round))
    }

    func testIncompleteLiveOrEarlyFinishedRoundCannotBeRanked() {
        var room = completeRoom()
        room.status = "live"
        XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
        room.status = "finished"
        room.currentTurnIndex = 0
        XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
        room.currentTurnIndex = room.format.turns.count - 1
        room.transcript.removeLast()
        XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
    }

    func testMissingReplyIsIncompleteEvenWhenEverySpeakerHasSubstantiveText() {
        var room = completeRoom(format: FormatCatalog.worldSchools)
        room.transcript.removeAll { $0.turnID == "gov-reply" }
        XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
    }

    func testDuplicateEntriesAndRepeatedSubmissionsAreRejected() {
        var room = completeRoom()
        room.transcript.append(room.transcript[0])
        XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
        room.transcript[room.transcript.count - 1].id = "another-id-same-submission"
        XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
    }

    func testEmptyTinyUnknownAndFutureTranscriptEntriesAreRejected() {
        let base = completeRoom()
        for text in ["", " \n ", "A tiny fragment"] {
            var room = base
            room.transcript[0].text = text
            XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
        }
        var room = base
        room.transcript[0].turnID = "not-scheduled"
        XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
        room = base
        room.transcript[0].participantID = "not-a-debater"
        XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
        room = base
        room.transcript[0].createdAt = 2_001
        XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
        room.transcript[0].createdAt = .nan
        XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
    }

    func testArchivedRosterPreservesDepartedSpeakerAttribution() throws {
        var room = completeRoom()
        room.debateParticipants = room.participants
        room.participants.removeAll()
        let round = try RoundJudgeValidation.prepare(room, now: 2_000)
        XCTAssertEqual(Set(round.speakers.map(\.id)), Set(["gov-0", "opp-0"]))
        XCTAssertNoThrow(try RoundJudgeValidation.validate(validVerdict(round), against: round))
    }

    func testAmbiguousRosterCannotBeJudged() {
        var room = completeRoom()
        room.participants.append(Participant(id: "duplicate-seat", displayName: "Other", teamID: "gov", seatIndex: 0))
        XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
        room = completeRoom()
        room.participants[1].id = room.participants[0].id
        XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
    }

    func testPOIIsAttributedToItsActualSpeakerAndCannotReplaceTheFloorSpeech() throws {
        var room = completeRoom(format: FormatCatalog.britishParliamentary)
        let poi = TranscriptSegment(id: "poi", participantID: "oo-0", turnID: "pm",
            text: "Your proposal does not explain how remote households can access this service without reliable transport.", createdAt: 1_030)
        room.transcript.append(poi)
        let round = try RoundJudgeValidation.prepare(room, now: 2_000)
        let source = try XCTUnwrap(round.sources.first { $0.isPOI })
        XCTAssertEqual(source.participantID, "oo-0")
        XCTAssertEqual(source.teamID, "oo")
        room.transcript.removeAll { $0.turnID == "pm" && $0.participantID == "og-0" }
        XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
    }

    func testOwnBenchPOIAndPOIInAReplyAreRejected() {
        var room = completeRoom(format: FormatCatalog.britishParliamentary)
        room.transcript.append(TranscriptSegment(id: "poi", participantID: "cg-0", turnID: "pm",
            text: "This is not an eligible point of information from the opposing bench.", createdAt: 1_030))
        XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
        room = completeRoom(format: FormatCatalog.worldSchools)
        room.transcript.append(TranscriptSegment(id: "poi", participantID: "gov-0", turnID: "opp-reply",
            text: "A reply speech cannot receive this point of information.", createdAt: 1_030))
        XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
    }

    func testUnicodeChunkingPreservesEveryCharacterAndByteBudget() throws {
        let source = String(repeating: "Здравствуйте 🌍 👩🏽‍💻 Қазақша e\u{301} argumento. ", count: 80)
        let chunks = try RoundJudgeValidation.chunks(source, maximumUTF8Bytes: 128)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), source)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 })
        let tail = String(repeating: "x", count: 1_001)
        let tailChunks = try RoundJudgeValidation.chunks(tail, maximumUTF8Bytes: 1_000)
        XCTAssertEqual(tailChunks.joined(), tail)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(tailChunks.last).utf8.count, 32)
    }

    func testOversizedGraphemeAndWholeRoundBudgetAbstainWithoutTruncation() {
        let grapheme = "a" + String(repeating: "\u{301}", count: 100)
        XCTAssertThrowsError(try RoundJudgeValidation.chunks(grapheme, maximumUTF8Bytes: 128))
        var room = completeRoom()
        room.transcript[0].text = String(repeating: "x", count: RoundJudgeValidation.maximumTranscriptBytes + 1)
        XCTAssertThrowsError(try RoundJudgeValidation.prepare(room, now: 2_000))
    }

    func testRankPermutationAndEveryTeamIdentityAreRequired() throws {
        let round = try RoundJudgeValidation.prepare(completeRoom(), now: 2_000)
        var verdict = validVerdict(round)
        verdict.teamPlacements[1].rank = 1
        XCTAssertThrowsError(try RoundJudgeValidation.validate(verdict, against: round))
        verdict = validVerdict(round)
        verdict.teamPlacements[1].teamID = "invented"
        XCTAssertThrowsError(try RoundJudgeValidation.validate(verdict, against: round))
        verdict = validVerdict(round)
        verdict.teamPlacements.removeLast()
        XCTAssertThrowsError(try RoundJudgeValidation.validate(verdict, against: round))
    }

    func testScoresUseInclusiveZeroToTwentyFiveBoundsAndComputedTotal() throws {
        let round = try RoundJudgeValidation.prepare(completeRoom(), now: 2_000)
        var verdict = validVerdict(round)
        verdict.speakerAssessments[0].argumentation = 0
        verdict.speakerAssessments[0].engagement = 25
        verdict.speakerAssessments[0].structure = 25
        verdict.speakerAssessments[0].roleFulfilment = 25
        XCTAssertEqual(verdict.speakerAssessments[0].points, 75)
        XCTAssertNoThrow(try RoundJudgeValidation.validate(verdict, against: round))
        verdict.speakerAssessments[0].argumentation = -1
        XCTAssertThrowsError(try RoundJudgeValidation.validate(verdict, against: round))
        verdict.speakerAssessments[0].argumentation = 26
        XCTAssertThrowsError(try RoundJudgeValidation.validate(verdict, against: round))
    }

    func testMissingDuplicateAndInventedSpeakerAssessmentsAreRejected() throws {
        let round = try RoundJudgeValidation.prepare(completeRoom(), now: 2_000)
        var verdict = validVerdict(round)
        verdict.speakerAssessments.removeLast()
        XCTAssertThrowsError(try RoundJudgeValidation.validate(verdict, against: round))
        verdict = validVerdict(round)
        verdict.speakerAssessments[1] = verdict.speakerAssessments[0]
        XCTAssertThrowsError(try RoundJudgeValidation.validate(verdict, against: round))
        verdict = validVerdict(round)
        verdict.speakerAssessments[0].participantID = "invented"
        XCTAssertThrowsError(try RoundJudgeValidation.validate(verdict, against: round))
    }

    func testInventedAndMisattributedEvidenceCannotPass() throws {
        let round = try RoundJudgeValidation.prepare(completeRoom(), now: 2_000)
        var verdict = validVerdict(round)
        verdict.speakerAssessments[0].evidence = verdict.speakerAssessments[1].evidence
        XCTAssertThrowsError(try RoundJudgeValidation.validate(verdict, against: round))
        verdict = validVerdict(round)
        verdict.teamPlacements[0].evidence = ["This quotation never occurred in any speech."]
        XCTAssertThrowsError(try RoundJudgeValidation.validate(verdict, against: round))
        verdict = validVerdict(round)
        verdict.speakerAssessments[0].evidence = []
        XCTAssertThrowsError(try RoundJudgeValidation.validate(verdict, against: round))
        XCTAssertFalse(RoundJudgeValidation.exactQuote("changed words", in: "the original speech words"))
    }

    func testTranscriptDigestIsOrderStableAndChangesWhenEvidenceChanges() throws {
        let room = completeRoom()
        let digest = try RoundJudgeValidation.transcriptDigest(room)
        XCTAssertEqual(digest.count, 64)
        var changed = room
        changed.transcript.reverse()
        XCTAssertEqual(try RoundJudgeValidation.transcriptDigest(changed), digest)
        changed.transcript[0].text += " Changed."
        XCTAssertNotEqual(try RoundJudgeValidation.transcriptDigest(changed), digest)
    }

    private func completeRoom(format: DebateFormat = FormatCatalog.duel) -> DebateRoom {
        let participants = format.teams.flatMap { team in
            (0..<format.speakersPerTeam).map { Participant(id: "\(team.id)-\($0)", displayName: "\(team.name) \($0 + 1)", teamID: team.id, seatIndex: $0) }
        }
        let transcript = format.turns.enumerated().map { index, turn in
            TranscriptSegment(id: "segment-\(index)", participantID: "\(turn.teamID)-\(turn.speakerIndex)", turnID: turn.id,
                text: "Speaker \(turn.teamID)-\(turn.speakerIndex), turn \(turn.id), argues that funding local transport improves access to school. A regular service reduces travel uncertainty, so families can plan attendance and students lose fewer lessons. The other side must explain why its alternative reaches remote households.",
                createdAt: 1_010 + Double(index))
        }
        return DebateRoom(id: "complete-round", title: "This house would fund local transport", language: "English",
                          format: format, status: "finished", hostID: participants[0].id,
                          participants: participants, createdAt: 1_000, currentTurnIndex: format.turns.count - 1,
                          transcript: transcript)
    }

    private func validVerdict(_ round: PreparedRound) -> RoundVerdict {
        let placements = round.room.format.teams.enumerated().map { index, team in
            TeamPlacement(teamID: team.id, rank: index + 1, explanation: "A comparative explanation supported by the submitted arguments.",
                          evidence: [String(round.sources.first { $0.teamID == team.id }!.text.prefix(90))])
        }
        let assessments = round.speakers.map { speaker in
            SpeakerAssessment(participantID: speaker.id, argumentation: 15, engagement: 14, structure: 16,
                              roleFulfilment: 15, explanation: "The four practice scores reflect this speaker's recorded contribution.",
                              evidence: [String(round.sources.first { $0.participantID == speaker.id }!.text.prefix(90))],
                              improvement: "Explain the causal link with a concrete example.")
        }
        return RoundVerdict(id: "test-verdict", roomID: round.room.id, summary: "The comparative conclusion from this complete record.",
                            teamPlacements: placements, speakerAssessments: assessments,
                            limitation: "Test fixture; not a generated AI result.", createdAt: 2_000)
    }
}
