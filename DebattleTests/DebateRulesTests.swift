import Foundation
import XCTest
@testable import Debattle

final class DebateRulesTests: XCTestCase {
    func testAllPresetsHaveCompleteValidSchedules() {
        for format in FormatCatalog.presets {
            XCTAssertEqual(format.validate(), [], format.name)
            XCTAssertEqual(Set(format.turns.filter { $0.kind == "substantive" }
                .map { "\($0.teamID):\($0.speakerIndex)" }).count, format.capacity, format.name)
            XCTAssertLessThanOrEqual(format.totalDurationSeconds, 14_400)
        }
    }

    func testBritishParliamentarySpeakingOrderAndTiming() {
        let format = FormatCatalog.britishParliamentary
        XCTAssertEqual(format.capacity, 8)
        XCTAssertEqual(format.turns.map(\.teamID), ["og", "oo", "og", "oo", "cg", "co", "cg", "co"])
        XCTAssertEqual(format.turns.map(\.speakerIndex), [0, 0, 1, 1, 0, 0, 1, 1])
        XCTAssertEqual(format.turns.map(\.durationSeconds), Array(repeating: 420, count: 8))
        XCTAssertEqual(format.totalDurationSeconds, 900 + 8 * 435)
        XCTAssertFalse(format.turns.contains { $0.kind == "reply" })
    }

    func testSchoolsAndAsianRepliesFollowSubstantivesInReverseSideOrder() {
        for format in [FormatCatalog.worldSchools, FormatCatalog.asianParliamentary] {
            XCTAssertEqual(format.capacity, 6)
            XCTAssertEqual(Array(format.turns.prefix(6)).map(\.teamID), ["gov", "opp", "gov", "opp", "gov", "opp"])
            XCTAssertEqual(Array(format.turns.suffix(2)).map(\.teamID), ["opp", "gov"])
            XCTAssertEqual(Array(format.turns.suffix(2)).map(\.kind), ["reply", "reply"])
            XCTAssertEqual(Array(format.turns.suffix(2)).map(\.durationSeconds), [240, 240])
        }
    }

    func testReplySpeakerMayBeFirstOrSecondButNotThird() {
        for seat in 0...2 {
            var format = FormatCatalog.worldSchools
            format.turns[6].speakerIndex = seat
            XCTAssertEqual(format.validate().isEmpty, seat < 2)
        }
        var outOfOrder = FormatCatalog.worldSchools
        outOfOrder.turns.swapAt(0, 6)
        XCTAssertFalse(outOfOrder.validate().isEmpty)
    }

    func testCustomBuilderGivesEverySeatEveryRound() {
        let format = FormatCatalog.custom(teamCount: 4, speakersPerTeam: 2, rounds: 3)
        XCTAssertEqual(format.validate(), [])
        XCTAssertEqual(format.turns.count, 24)
        for team in format.teams {
            for seat in 0..<format.speakersPerTeam {
                XCTAssertEqual(format.turns.filter { $0.teamID == team.id && $0.speakerIndex == seat }.count, 3)
            }
        }
    }

    func testCustomValidationRejectsLimitsAndUnusablePOIWindows() {
        let cases: [DebateFormat] = [
            .init(id: "empty", name: "Empty", summary: "", teams: [], speakersPerTeam: 0,
                  preparationSeconds: 0, turns: [], poiEnabled: false,
                  protectedSeconds: 0, poiDurationSeconds: 15, graceSeconds: 0),
            FormatCatalog.custom(teamCount: 5),
            FormatCatalog.custom(speakersPerTeam: 5),
            FormatCatalog.custom(preparationSeconds: -1),
            FormatCatalog.custom(speechDurationSeconds: 29),
            FormatCatalog.custom(speechDurationSeconds: 901),
            FormatCatalog.custom(rounds: 0),
            FormatCatalog.custom(teamCount: 4, speakersPerTeam: 4, rounds: 3),
            FormatCatalog.custom(speechDurationSeconds: 60, poiEnabled: true, protectedSeconds: 30),
            FormatCatalog.custom(poiDurationSeconds: 31),
            FormatCatalog.custom(graceSeconds: 61),
            FormatCatalog.custom(teamCount: 4, speakersPerTeam: 4, speechDurationSeconds: 900, rounds: 2)
        ]
        for (index, format) in cases.enumerated() {
            XCTAssertFalse(format.validate().isEmpty, "Invalid case \(index) passed")
        }
        XCTAssertFalse(FormatCatalog.custom(teamCount: Int.max, speakersPerTeam: Int.max, rounds: Int.max).validate().isEmpty)
    }

    func testCustomValidationRejectsMissingTeamsSeatsAndDuplicateIDs() {
        var format = FormatCatalog.custom()
        format.turns[0].teamID = "missing"
        format.turns[1].speakerIndex = 4
        format.turns[2].id = format.turns[3].id
        XCTAssertGreaterThanOrEqual(format.validate().count, 3)
    }

    func testReservedServerMapKeysCannotBeUsedAsIdentifiers() {
        for reserved in ["__proto__", "constructor", "prototype"] {
            var format = FormatCatalog.custom()
            format.id = reserved
            XCTAssertFalse(format.validate().isEmpty)
            format.id = "custom"
            format.turns[0].id = reserved
            XCTAssertFalse(format.validate().isEmpty)
            format.turns[0].id = "first-turn"
            format.teams[0].id = reserved
            XCTAssertFalse(format.validate().isEmpty)
        }
    }

    func testPOIWindowIncludesFirstUnprotectedSecondAndExcludesLastMinute() {
        let start = 1_000.0
        let room = fullRoom(format: FormatCatalog.britishParliamentary, start: start)
        for (elapsed, expected) in [(0.0, false), (59.999, false), (60.0, true),
                                     (359.999, true), (360.0, false), (420.0, false), (435.0, false)] {
            XCTAssertEqual(DebateRules.canOfferPOI(participantID: "oo-0", in: room, at: start + elapsed), expected,
                           "Elapsed \(elapsed)")
        }
    }

    func testPOIsExcludeOwnBenchAndUnseatedAudience() {
        var room = fullRoom(format: FormatCatalog.britishParliamentary)
        room.participants.append(Participant(id: "audience", displayName: "Observer"))
        XCTAssertEqual(Set(DebateRules.eligiblePOISpeakers(in: room, at: 1_100).map(\.id)),
                       Set(["oo-0", "oo-1", "co-0", "co-1"]))
        XCTAssertFalse(DebateRules.canOfferPOI(participantID: "cg-0", in: room, at: 1_100))
        XCTAssertFalse(DebateRules.canOfferPOI(participantID: "audience", in: room, at: 1_100))
    }

    func testRepliesAndPausedSpeechesNeverAllowPOI() {
        var room = fullRoom(format: FormatCatalog.worldSchools)
        room.currentTurnIndex = 6
        room.phaseEndsAt = 1_255
        XCTAssertFalse(DebateRules.canOfferPOI(participantID: "gov-0", in: room, at: 1_100))
        room.currentTurnIndex = 0
        room.pausedRemainingSeconds = 395
        room.phaseEndsAt = nil
        XCTAssertFalse(DebateRules.canOfferPOI(participantID: "opp-0", in: room, at: 1_100))
        XCTAssertFalse(DebateRules.canSpeak(participantID: "gov-0", in: room, at: 1_100))
    }

    func testAcceptedPOITransfersFloorAndExpiresWithoutFreezingSpeechClock() {
        var room = fullRoom(format: FormatCatalog.britishParliamentary)
        room.poiSpeakerID = "oo-0"
        room.poiEndsAt = 1_115
        XCTAssertTrue(DebateRules.canSpeak(participantID: "oo-0", in: room, at: 1_110))
        XCTAssertFalse(DebateRules.canSpeak(participantID: "og-0", in: room, at: 1_110))
        XCTAssertFalse(DebateRules.canOfferPOI(participantID: "co-0", in: room, at: 1_110))
        XCTAssertTrue(DebateRules.canSpeak(participantID: "og-0", in: room, at: 1_115))
        XCTAssertEqual(DebateRules.elapsedSpeechSeconds(in: room, at: 1_115), 115)
    }

    func testTimerRoundingPauseAndGraceBoundaries() {
        var room = fullRoom(format: FormatCatalog.britishParliamentary)
        XCTAssertEqual(DebateRules.remainingSeconds(in: room, at: 1_000), 435)
        XCTAssertEqual(DebateRules.remainingSeconds(in: room, at: 1_434.2), 1)
        XCTAssertEqual(DebateRules.remainingSeconds(in: room, at: 1_435), 0)
        XCTAssertEqual(DebateRules.remainingSeconds(in: room, at: 2_000), 0)
        XCTAssertFalse(DebateRules.isInGracePeriod(room, at: 1_419.9))
        XCTAssertTrue(DebateRules.isInGracePeriod(room, at: 1_420))
        XCTAssertFalse(DebateRules.isInGracePeriod(room, at: 1_435))
        room.pausedRemainingSeconds = 200.2
        room.phaseEndsAt = nil
        XCTAssertEqual(DebateRules.remainingSeconds(in: room, at: 2_000), 201)
        XCTAssertEqual(DebateRules.remainingSeconds(in: room, at: 5_000), 201)
        XCTAssertEqual(DebateRules.elapsedSpeechSeconds(in: room, at: 2_000), 234.8, accuracy: 0.0001)
    }

    func testMissingAndNonFiniteTimestampsDoNotCreateSpeakingPermission() {
        var room = fullRoom(format: FormatCatalog.duel)
        room.phaseEndsAt = nil
        XCTAssertEqual(DebateRules.remainingSeconds(in: room, at: 1_000), 0)
        XCTAssertEqual(DebateRules.elapsedSpeechSeconds(in: room, at: 1_000), 0)
        room.phaseEndsAt = .infinity
        XCTAssertEqual(DebateRules.remainingSeconds(in: room, at: 1_000), 0)
        XCTAssertFalse(DebateRules.canSpeak(participantID: "gov-0", in: room, at: .nan))
        room.status = "finished"
        room.pausedRemainingSeconds = 200
        XCTAssertEqual(DebateRules.remainingSeconds(in: room, at: 1_000), 0)
        XCTAssertEqual(DebateRules.clockText(-1), "00:00")
        XCTAssertEqual(DebateRules.clockText(435), "07:15")
    }

    func testStartRequiresUniqueReadyCompleteRoster() {
        var room = fullRoom(format: FormatCatalog.duel)
        room.status = "waiting"
        XCTAssertTrue(DebateRules.canStart(room))
        room.participants[0].isReady = false
        XCTAssertFalse(DebateRules.canStart(room))
        room.participants[0].isReady = true
        room.participants[1].seatIndex = nil
        XCTAssertFalse(DebateRules.canStart(room))
        XCTAssertEqual(room.occupiedSeats, 1)
        room.participants[1].seatIndex = 0
        room.participants[1].id = room.participants[0].id
        XCTAssertFalse(DebateRules.canStart(room))
    }

    func testRoomRoundTripsEpochSecondsAndDecodesAbsentOptionalFields() throws {
        var room = fullRoom(format: FormatCatalog.duel)
        room.poiRequests = ["opp-0"]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(room)
        XCTAssertEqual(try decoder.decode(DebateRoom.self, from: data), room)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["transcript", "currentTurnIndex", "phaseEndsAt", "pausedRemainingSeconds", "poiSpeakerID", "poiEndsAt", "poiRequests"] {
            json.removeValue(forKey: key)
        }
        let decoded = try decoder.decode(DebateRoom.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.createdAt, 1_000)
        XCTAssertEqual(decoded.transcript, [])
        XCTAssertEqual(decoded.currentTurnIndex, 0)
        XCTAssertNil(decoded.phaseEndsAt)
        XCTAssertEqual(decoded.poiRequests, [])
    }

    private func fullRoom(format: DebateFormat, start: Double = 1_000) -> DebateRoom {
        let participants = format.teams.flatMap { team in
            (0..<format.speakersPerTeam).map { seat in
                Participant(id: "\(team.id)-\(seat)", displayName: "Speaker \(seat + 1)",
                            teamID: team.id, seatIndex: seat, isReady: true)
            }
        }
        return DebateRoom(id: "room", title: "This house would test its rules", language: "en", format: format,
                          status: "live", hostID: participants[0].id, participants: participants, createdAt: start,
                          phaseEndsAt: start + Double(format.turns[0].durationSeconds + format.graceSeconds))
    }
}
