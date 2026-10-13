import Foundation
import XCTest
@testable import Debattle

final class AppStoreTests: XCTestCase {
    /// Regression: a stale live-room snapshot used to keep the microphone eligible
    /// after its deadline until the next network event arrived.
    @MainActor
    func testExpiredSpeechCannotOpenMicrophoneBeforeNextServerUpdate() async {
        let store = makeStore()
        store.activeRoom = room(deadline: Date().timeIntervalSince1970 - 30)
        XCTAssertFalse(store.canSpeak)
        store.activeRoom?.phaseEndsAt = Date().timeIntervalSince1970 + 120
        XCTAssertTrue(store.canSpeak)
        store.activeRoom?.phaseEndsAt = nil
        XCTAssertFalse(store.canSpeak)
    }

    @MainActor
    func testPauseAndFinishedSnapshotsRemoveFloorPermission() async {
        let store = makeStore()
        store.activeRoom = room(deadline: Date().timeIntervalSince1970 + 120)
        store.activeRoom?.pausedRemainingSeconds = 120
        XCTAssertFalse(store.canSpeak)
        store.activeRoom?.pausedRemainingSeconds = nil
        XCTAssertTrue(store.canSpeak)
        store.activeRoom?.status = "finished"
        XCTAssertFalse(store.canSpeak)
    }

    @MainActor
    func testAcceptedPOITransfersAndReturnsFloorPermission() async {
        let store = makeStore()
        store.activeRoom = room(deadline: Date().timeIntervalSince1970 + 120)
        store.activeRoom?.poiSpeakerID = "opponent"
        store.activeRoom?.poiEndsAt = Date().timeIntervalSince1970 + 15
        XCTAssertFalse(store.canSpeak)
        store.session = GuestSession(token: "unit-test", participantID: "opponent", displayName: "Opponent")
        XCTAssertTrue(store.canSpeak)
        store.activeRoom?.poiEndsAt = Date().timeIntervalSince1970 - 10
        XCTAssertFalse(store.canSpeak)
        store.session = GuestSession(token: "unit-test", participantID: "speaker", displayName: "Speaker")
        XCTAssertTrue(store.canSpeak)
        store.session = GuestSession(token: "unit-test", participantID: "audience", displayName: "Audience")
        XCTAssertFalse(store.canSpeak)
    }

    @MainActor
    func testStaleTurnSnapshotCannotStopCurrentTranscription() async {
        let store = makeStore()
        var current = room(deadline: Date().timeIntervalSince1970 + 120)
        current.currentTurnIndex = 2 // The same speaker's closing speech.
        current.revision = 20
        store.activeRoom = current
        store.isTranscribing = true
        store.streamConnected = true
        var stale = current
        stale.currentTurnIndex = 0
        stale.revision = 19

        await store.update(stale, generation: store.roomGeneration)

        XCTAssertEqual(store.activeRoom, current)
        XCTAssertTrue(store.isTranscribing, "Rejected snapshots must not finalize the current speech.")
        XCTAssertTrue(store.streamConnected)
        XCTAssertNil(store.alertMessage)
        store.isTranscribing = false
    }

    @MainActor
    func testStaleMembershipSnapshotCannotRemoveCurrentParticipant() async {
        let store = makeStore()
        var current = room(deadline: Date().timeIntervalSince1970 + 120)
        current.revision = 20
        store.activeRoom = current
        store.isTranscribing = true
        store.streamConnected = true
        var stale = current
        stale.revision = 19
        stale.participants.removeAll { $0.id == "speaker" }

        await store.update(stale, generation: store.roomGeneration)

        XCTAssertEqual(store.activeRoom, current)
        XCTAssertTrue(store.streamConnected)
        XCTAssertTrue(store.isTranscribing)
        XCTAssertNil(store.alertMessage)
        store.isTranscribing = false
    }

    @MainActor
    func testAcceptedTurnChangeStillFinalizesCurrentTranscription() async {
        let store = makeStore()
        var current = room(deadline: Date().timeIntervalSince1970 + 120)
        current.revision = 20
        store.activeRoom = current
        store.isTranscribing = true
        var next = current
        next.revision = 21
        next.currentTurnIndex = 1

        await store.update(next, generation: store.roomGeneration)

        XCTAssertEqual(store.activeRoom, next)
        XCTAssertFalse(store.isTranscribing)
        XCTAssertFalse(store.canSpeak)
    }

    @MainActor
    func testFinishedUpdatePersistsReceivedTranscriptThroughActualReducer() async {
        var writes: [[DebateRoom]] = []
        let store = makeStore(historyWriter: { writes.append($0) })
        let initial = room(deadline: Date().timeIntervalSince1970 + 120)
        store.activeRoom = initial
        let finished = finishedRoom(revision: 20, text: "The final argument is preserved.")

        await store.update(finished, generation: store.roomGeneration)

        XCTAssertEqual(store.completedDebates, [finished])
        XCTAssertEqual(writes, [[finished]])
        XCTAssertEqual(store.activeRoom, finished)
    }

    @MainActor
    func testLateFinalizationArchivesAfterLeaveWithoutReopeningRoom() async {
        var writes: [[DebateRoom]] = []
        let store = makeStore(historyWriter: { writes.append($0) })
        let previousGeneration = store.roomGeneration
        // A completed teardown invalidates callbacks even when no room remains onscreen.
        await store.leaveRoom()
        XCTAssertNotEqual(store.roomGeneration, previousGeneration)
        let finished = finishedRoom(revision: 21, text: "A final upload returned after the screen closed.")

        store.applyFinalizedSnapshot(finished, generation: previousGeneration, participantID: "speaker")

        XCTAssertNil(store.activeRoom)
        XCTAssertEqual(store.completedDebates, [finished])
        XCTAssertEqual(writes, [[finished]])
        var other = room(deadline: Date().timeIntervalSince1970 + 120)
        other.id = "another-room"
        store.activeRoom = other
        var later = finished
        later.revision = 22
        later.transcript.append(TranscriptSegment(id: "late-peer", participantID: "opponent", turnID: "opp-close",
                                                 text: "Another completed contribution.", createdAt: later.createdAt + 1))
        store.applyFinalizedSnapshot(later, generation: previousGeneration, participantID: "speaker")
        XCTAssertEqual(store.activeRoom, other)
        XCTAssertEqual(store.completedDebates, [later])
    }

    @MainActor
    func testOlderAndRedactedSnapshotsCannotReplaceFinishedArchive() async {
        var writes: [[DebateRoom]] = []
        let store = makeStore(historyWriter: { writes.append($0) })
        let finished = finishedRoom(revision: 21, text: "Keep the full final transcript.")
        store.applyFinalizedSnapshot(finished, generation: UUID(), participantID: "speaker")
        var older = finished
        older.revision = 20
        older.transcript = []
        store.applyFinalizedSnapshot(older, generation: UUID(), participantID: "speaker")
        var redactedLeaveResponse = finished
        redactedLeaveResponse.revision = 22
        redactedLeaveResponse.transcript = []
        redactedLeaveResponse.participants.removeAll { $0.id == "speaker" }
        store.applyFinalizedSnapshot(redactedLeaveResponse, generation: UUID(), participantID: "speaker")

        XCTAssertEqual(store.completedDebates, [finished])
        XCTAssertEqual(writes, [[finished]])
    }

    @MainActor
    func testLegacyEqualRevisionDoesNotLoseAlreadyArchivedFragments() async {
        let store = makeStore()
        let complete = finishedRoom(revision: 0, text: "Legacy servers have no revision counter.")
        store.saveHistory(complete)
        var partial = complete
        partial.transcript = []
        store.saveHistory(partial)
        XCTAssertEqual(store.completedDebates, [complete])
    }

    @MainActor
    private func makeStore(historyWriter: @escaping ([DebateRoom]) throws -> Void = { _ in }) -> AppStore {
        let recoveryURL = FileManager.default.temporaryDirectory.appendingPathComponent("debattle-tests-\(UUID().uuidString)")
            .appendingPathComponent("recovery.json")
        let store = AppStore(historyLoader: { [] }, historyWriter: historyWriter,
                             recoveryArchive: TranscriptRecoveryArchive(fileURL: recoveryURL))
        store.session = GuestSession(token: "unit-test", participantID: "speaker", displayName: "Speaker")
        return store
    }

    private func finishedRoom(revision: Int, text: String) -> DebateRoom {
        var finished = room(deadline: Date().timeIntervalSince1970 + 120)
        finished.status = "finished"
        finished.phaseEndsAt = nil
        finished.currentTurnIndex = finished.format.turns.count - 1
        finished.revision = revision
        finished.transcript = [TranscriptSegment(id: "final-speech", participantID: "speaker", turnID: "gov-close",
                                                text: text, createdAt: finished.createdAt)]
        return finished
    }

    private func room(deadline: Double) -> DebateRoom {
        DebateRoom(id: "test-room", title: "A complete turn", language: "English", format: FormatCatalog.duel,
                   status: "live", hostID: "speaker", participants: [
                    Participant(id: "speaker", displayName: "Speaker", teamID: "gov", seatIndex: 0),
                    Participant(id: "opponent", displayName: "Opponent", teamID: "opp", seatIndex: 0),
                    Participant(id: "audience", displayName: "Audience")
                   ], phaseEndsAt: deadline)
    }
}

final class CustomFormatLibraryTests: XCTestCase {
    func testNewDraftsReceiveDistinctIDsAndSurviveReload() throws {
        try withIsolatedDefaults { defaults in
            let first = try CustomFormatLibrary.save(FormatCatalog.custom(), to: defaults)
            let second = try CustomFormatLibrary.save(FormatCatalog.custom(), to: defaults)
            XCTAssertTrue(first.id.hasPrefix("custom-"))
            XCTAssertNotEqual(first.id, second.id)
            let reloaded = CustomFormatLibrary.load(from: defaults)
            XCTAssertEqual(reloaded.map(\.id), [second.id, first.id])
            XCTAssertEqual(reloaded.last?.turns, first.turns)
        }
    }

    func testEditingUpdatesOneTemplateAndKeepsItsStableIdentity() throws {
        try withIsolatedDefaults { defaults in
            var format = try CustomFormatLibrary.save(FormatCatalog.custom(), to: defaults)
            let originalID = format.id
            format.name = "Friday discussion"
            format.turns[0].durationSeconds = 240
            let updated = try CustomFormatLibrary.save(format, to: defaults)
            let reloaded = CustomFormatLibrary.load(from: defaults)
            XCTAssertEqual(updated.id, originalID)
            XCTAssertEqual(reloaded.count, 1)
            XCTAssertEqual(reloaded.first?.name, "Friday discussion")
            XCTAssertEqual(reloaded.first?.turns[0].durationSeconds, 240)
        }
    }

    func testInvalidSavePreservesExistingTemplates() throws {
        try withIsolatedDefaults { defaults in
            let saved = try CustomFormatLibrary.save(FormatCatalog.custom(), to: defaults)
            var invalid = saved
            invalid.turns.removeAll()
            XCTAssertThrowsError(try CustomFormatLibrary.save(invalid, to: defaults))
            XCTAssertEqual(CustomFormatLibrary.load(from: defaults), [saved])
        }
    }

    func testDeleteRemovesOnlySelectedTemplate() throws {
        try withIsolatedDefaults { defaults in
            let first = try CustomFormatLibrary.save(FormatCatalog.custom(), to: defaults)
            let second = try CustomFormatLibrary.save(FormatCatalog.custom(), to: defaults)
            try CustomFormatLibrary.remove(id: first.id, from: defaults)
            XCTAssertEqual(CustomFormatLibrary.load(from: defaults), [second])
            try CustomFormatLibrary.remove(id: "does-not-exist", from: defaults)
            XCTAssertEqual(CustomFormatLibrary.load(from: defaults), [second])
        }
    }

    func testMalformedStorageAndDuplicateTemplatesAreHandledSafely() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(Data("invalid json".utf8), forKey: CustomFormatLibrary.storageKey)
            XCTAssertEqual(CustomFormatLibrary.load(from: defaults), [])
            var valid = FormatCatalog.custom()
            valid.id = "custom-test"
            var invalid = valid
            invalid.id = "custom-invalid"
            invalid.turns.removeAll()
            defaults.set(try JSONEncoder().encode([valid, valid, invalid, FormatCatalog.duel]), forKey: CustomFormatLibrary.storageKey)
            XCTAssertEqual(CustomFormatLibrary.load(from: defaults), [valid])
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "app.debattle.tests.custom-formats.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
