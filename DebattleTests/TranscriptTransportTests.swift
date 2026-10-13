import XCTest
@testable import Debattle

final class TranscriptTransportTests: XCTestCase {
    func testLongMultilingualSpeechUploadsWithoutTruncation() throws {
        let source = String(repeating: "An argument. Дәлел мен пікір. Аргумент. Una razón. 👨‍👩‍👧‍👦\n", count: 350)
        let chunks = try TranscriptTransport.chunks(source)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), source)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.utf16.count <= 3000 })
    }
    func testBoundaryAndEmptySpeech() throws {
        XCTAssertEqual(try TranscriptTransport.chunks(""), [])
        XCTAssertEqual(try TranscriptTransport.chunks("123456", maximumUTF16Units: 3), ["123", "456"])
        XCTAssertThrowsError(try TranscriptTransport.chunks("hello", maximumUTF16Units: 0))
        XCTAssertThrowsError(try TranscriptTransport.chunks("👨‍👩‍👧‍👦", maximumUTF16Units: 2))
    }
    func testRoomArchivePreservesSpeakersAfterTheyLeave() throws {
        let speaker = Participant(id: "speaker", displayName: "Speaker", teamID: "gov", seatIndex: 0)
        let room = DebateRoom(id: "r", title: "A complete debate", language: "English", format: FormatCatalog.duel,
                              status: "finished", hostID: "speaker", participants: [], revision: 8, debateParticipants: [speaker])
        let decoded = try JSONDecoder().decode(DebateRoom.self, from: JSONEncoder().encode(room))
        XCTAssertTrue(decoded.participants.isEmpty)
        XCTAssertEqual(decoded.debateParticipants, [speaker])
        XCTAssertEqual(decoded.revision, 8)
    }
}
