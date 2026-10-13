import Foundation
import XCTest
@testable import Debattle

final class TranscriptRecoveryArchiveTests: XCTestCase {
    func testFullUnicodeSpeechAndAttributionSurviveReload() throws {
        let archive = makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.fileURL.deletingLastPathComponent()) }
        let speech = recovery(text: "Аргумент қазақша 👩🏽‍💻\n" + String(repeating: "Full speech. ", count: 600))
        try archive.preserve(speech)
        let reopened = TranscriptRecoveryArchive(fileURL: archive.fileURL)
        XCTAssertEqual(try reopened.load(), [speech])
    }

    func testRecordLimitRejectsNewCopyWithoutEvictingExistingSpeech() throws {
        let archive = makeArchive(maximumRecords: 1)
        defer { try? FileManager.default.removeItem(at: archive.fileURL.deletingLastPathComponent()) }
        let first = recovery(id: "first")
        try archive.preserve(first)
        XCTAssertThrowsError(try archive.preserve(recovery(id: "second"))) {
            XCTAssertEqual($0 as? TranscriptRecoveryArchive.RecoveryError, .storageFull)
        }
        XCTAssertEqual(try archive.load(), [first])
    }

    func testByteLimitRejectsWriteWithoutChangingExistingFile() throws {
        let archive = makeArchive(maximumBytes: 1_000)
        defer { try? FileManager.default.removeItem(at: archive.fileURL.deletingLastPathComponent()) }
        let first = recovery(id: "first")
        try archive.preserve(first)
        let originalBytes = try Data(contentsOf: archive.fileURL)
        XCTAssertThrowsError(try archive.preserve(recovery(id: "second", text: String(repeating: "я", count: 1_000)))) {
            XCTAssertEqual($0 as? TranscriptRecoveryArchive.RecoveryError, .storageFull)
        }
        XCTAssertEqual(try Data(contentsOf: archive.fileURL), originalBytes)
        XCTAssertEqual(try archive.load(), [first])
    }

    func testMalformedArchiveIsNeverOverwrittenByNewRecovery() throws {
        let archive = makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: archive.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalBytes = Data("damaged recovery data".utf8)
        try originalBytes.write(to: archive.fileURL)
        XCTAssertThrowsError(try archive.preserve(recovery())) {
            XCTAssertEqual($0 as? TranscriptRecoveryArchive.RecoveryError, .unreadableArchive)
        }
        XCTAssertEqual(try Data(contentsOf: archive.fileURL), originalBytes)
    }

    func testDeleteOnlyRemovesChosenRecovery() throws {
        let archive = makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.fileURL.deletingLastPathComponent()) }
        let first = recovery(id: "first")
        let second = recovery(id: "second")
        try archive.preserve(first)
        try archive.preserve(second)
        XCTAssertEqual(try archive.remove(id: first.id), [second])
        XCTAssertEqual(try archive.load(), [second])
    }

    private func makeArchive(maximumRecords: Int = 20, maximumBytes: Int = 2_000_000) -> TranscriptRecoveryArchive {
        TranscriptRecoveryArchive(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("debattle-recovery-tests-\(UUID().uuidString)").appendingPathComponent("recovery.json"),
                                  maximumRecords: maximumRecords, maximumBytes: maximumBytes)
    }

    private func recovery(id: String = "recovery", text: String = "A speech worth recovering.") -> RecoveredTranscript {
        RecoveredTranscript(id: id, roomID: "room", roomTitle: "The debate motion", turnID: "gov-open",
                            turnLabel: "Government opening", language: "Kazakh", participantID: "speaker",
                            speakerName: "Speaker", text: text, createdAt: 1_000)
    }
}

final class TranscriptRecoveryFlowTests: XCTestCase {
    @MainActor
    func testPartialUploadFailureKeepsFullSpeechAndDoesNotRetryOrJudgeIt() async throws {
        let archive = makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.fileURL.deletingLastPathComponent()) }
        let store = makeStore(archive: archive)
        let original = room()
        store.activeRoom = original
        let text = String(repeating: "A complete argument with its conclusion. ", count: 200)
        var attempts = 0

        await store.submitTranscript(text, for: original, turnID: "gov-open", participantID: "speaker",
                                     generation: store.roomGeneration) { chunk in
            attempts += 1
            XCTAssertEqual(try archive.load().first?.text, text, "A durable full copy must precede the first request.")
            if attempts == 2 { throw APIError(message: "Acknowledgement lost") }
            var response = original
            response.revision = 1
            response.transcript = [TranscriptSegment(id: "accepted", participantID: "speaker", turnID: "gov-open",
                                                    text: chunk, createdAt: original.createdAt)]
            return response
        }

        XCTAssertEqual(attempts, 2, "An uncertain upload must not be retried automatically.")
        XCTAssertEqual(try archive.load().count, 1)
        XCTAssertEqual(store.recoveredTranscripts.first?.text, text)
        XCTAssertEqual(store.activeRoom?.transcript.count, 1, "Recovery is not merged into the room transcript.")
        XCTAssertTrue(store.completedDebates.isEmpty)
        XCTAssertTrue(store.recoveryMessage?.contains("Some text may already") == true)
    }

    @MainActor
    func testAllAcknowledgementsRemoveOnlyThisSpeechRecovery() async throws {
        let archive = makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.fileURL.deletingLastPathComponent()) }
        let previous = RecoveredTranscript(id: "previous", roomID: "old-room", roomTitle: "Previous room", turnID: "turn",
                                           turnLabel: "Speech", language: "English", participantID: "speaker", speakerName: "Speaker",
                                           text: "An earlier failed speech.", createdAt: 1_000)
        try archive.preserve(previous)
        let store = makeStore(archive: archive)
        let original = room()
        let text = String(repeating: "A complete speech. ", count: 400)
        let expectedChunks = try TranscriptTransport.chunks(text)
        var uploaded: [String] = []

        await store.submitTranscript(text, for: original, turnID: "gov-open", participantID: "speaker",
                                     generation: store.roomGeneration) { chunk in
            XCTAssertEqual(try archive.load().count, 2, "Keep the safety copy until the last acknowledgement.")
            uploaded.append(chunk)
            return original
        }

        XCTAssertEqual(uploaded, expectedChunks)
        XCTAssertEqual(try archive.load(), [previous])
        XCTAssertEqual(store.recoveredTranscripts, [previous])
    }

    @MainActor
    func testRecoveryReloadAndExplicitDeleteUseIsolatedArchive() async throws {
        let archive = makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.fileURL.deletingLastPathComponent()) }
        let original = room()
        let store = makeStore(archive: archive)
        await store.submitTranscript("The captured speech survives an application restart.", for: original,
                                     turnID: "gov-open", participantID: "speaker", generation: UUID()) { _ in
            throw APIError(message: "Disconnected")
        }
        let reopened = makeStore(archive: archive)
        let saved = try XCTUnwrap(reopened.recoveredTranscripts.first)
        XCTAssertEqual(saved.roomID, original.id)
        XCTAssertEqual(saved.turnID, "gov-open")
        XCTAssertEqual(saved.language, "English")
        XCTAssertTrue(reopened.deleteRecoveredTranscript(id: saved.id))
        XCTAssertEqual(try archive.load(), [])
        XCTAssertEqual(reopened.recoveredTranscripts, [])
    }

    @MainActor
    func testFullArchiveIsReportedAndExistingRecoveryIsNeverEvicted() async throws {
        let archive = makeArchive(maximumRecords: 1)
        defer { try? FileManager.default.removeItem(at: archive.fileURL.deletingLastPathComponent()) }
        let previous = RecoveredTranscript(id: "previous", roomID: "old-room", roomTitle: "Previous room", turnID: "turn",
                                           turnLabel: "Speech", language: "English", participantID: "speaker", speakerName: "Speaker",
                                           text: "An earlier failed speech.", createdAt: 1_000)
        try archive.preserve(previous)
        let store = makeStore(archive: archive)
        await store.submitTranscript("This speech cannot have a local backup because the archive is full.", for: room(),
                                     turnID: "gov-open", participantID: "speaker", generation: UUID()) { _ in
            throw APIError(message: "Disconnected")
        }
        XCTAssertEqual(try archive.load(), [previous])
        XCTAssertEqual(store.recoveredTranscripts, [previous])
        XCTAssertTrue(store.recoveryMessage?.contains("full") == true)
        XCTAssertTrue(store.recoveryMessage?.contains("could not be saved") == true)
        XCTAssertNotNil(store.alertMessage)
    }

    @MainActor
    private func makeStore(archive: TranscriptRecoveryArchive) -> AppStore {
        AppStore(historyLoader: { [] }, historyWriter: { _ in }, recoveryArchive: archive)
    }

    private func makeArchive(maximumRecords: Int = 20) -> TranscriptRecoveryArchive {
        TranscriptRecoveryArchive(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("debattle-recovery-flow-\(UUID().uuidString)").appendingPathComponent("recovery.json"),
                                  maximumRecords: maximumRecords)
    }

    private func room() -> DebateRoom {
        DebateRoom(id: "room", title: "This house would preserve speeches", language: "English", format: FormatCatalog.duel,
                   status: "live", hostID: "speaker", participants: [
                    Participant(id: "speaker", displayName: "Speaker", teamID: "gov", seatIndex: 0)
                   ], phaseEndsAt: Date().timeIntervalSince1970 + 120)
    }
}
