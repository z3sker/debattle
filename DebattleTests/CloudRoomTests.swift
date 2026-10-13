import AVFoundation
import Foundation
import XCTest
@testable import Debattle

final class CloudRoomTests: XCTestCase {
    func testVoicePCM16NegotiatedWireFormatHasHalfTheBytesAndClampsSafely() {
        let values: [Float] = [-2, -1, -0.5, 0, 0.5, 1, 2, .nan, .infinity]
        let bytes = values.withUnsafeBufferPointer(VoicePCM16.encode)
        XCTAssertEqual(bytes.count, values.count * 2)
        XCTAssertEqual(Array(bytes), [0, 128, 0, 128, 0, 192, 0, 0, 0, 64, 255, 127, 255, 127, 0, 0, 0, 0])
    }

    func testRoomAudioUsesBoundedPCM16WithoutASecondMicrophone() throws {
        let recording = CloudRoomAudioBuffer(maximumSeconds: 1)
        recording.append(try buffer([-1, 0, 0.5, 1, .nan, .infinity]))
        let wav = try recording.finish()
        try CloudPracticeWAV.validate(wav)
        XCTAssertEqual(Array(wav.suffix(12)), [0, 128, 0, 0, 0, 64, 255, 127, 0, 0, 0, 0])
        XCTAssertThrowsError(try recording.finish())
    }

    func testCancelledAudioCannotBeRecoveredOrMixedIntoTheNextSpeech() throws {
        let old = CloudRoomAudioBuffer(maximumSeconds: 1)
        old.append(try buffer([0.5]))
        old.cancel()
        old.append(try buffer([0.9]))
        XCTAssertThrowsError(try old.finish()) { XCTAssertEqual($0 as? CloudRoomError, .noAudio) }
        let next = CloudRoomAudioBuffer(maximumSeconds: 1)
        next.append(try buffer([-0.5]))
        XCTAssertEqual(Array(try next.finish().suffix(2)), [0, 192])
    }

    func testOverflowDoesNotPresentAPartialSpeechAsACompleteRecording() throws {
        let recording = CloudRoomAudioBuffer(maximumSeconds: 1)
        recording.append(try buffer(Array(repeating: 0.1, count: 24_000)))
        recording.append(try buffer([0.1]))
        XCTAssertThrowsError(try recording.finish()) { XCTAssertEqual($0 as? CloudRoomError, .tooLong) }
    }

    func testInvalidAudioFormatCannotBecomeATranscript() throws {
        let recording = CloudRoomAudioBuffer(maximumSeconds: 1)
        recording.append(try buffer([0.5], rate: 48_000))
        XCTAssertThrowsError(try recording.finish()) { XCTAssertEqual($0 as? CloudRoomError, .invalidResponse) }
    }

    func testIdentifiersCannotEscapeRoomEndpoints() {
        XCTAssertTrue(CloudRoomAPI.validIdentifier("capture-12_abc"))
        for id in ["", "../other-room", "room?token=secret", "a/b", "a\nAuthorization: forged"] {
            XCTAssertFalse(CloudRoomAPI.validIdentifier(id))
        }
    }

    func testLegacyRoomSnapshotsDefaultToNoCloudPermission() throws {
        let room = room()
        let data = try JSONEncoder().encode(room)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "cloudConsentParticipantIDs")
        let decoded = try JSONDecoder().decode(DebateRoom.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.cloudConsentParticipantIDs.isEmpty)
    }

    @MainActor
    func testRoomCloudConsentIsScopedToTheCurrentParticipantAndRoom() {
        let store = AppStore(historyLoader: { [] }, historyWriter: { _ in })
        store.session = GuestSession(token: "test", participantID: "p1", displayName: "One")
        var room = room()
        room.cloudConsentParticipantIDs = ["p2"]
        store.activeRoom = room
        XCTAssertFalse(store.hasRoomCloudConsent)
        room.cloudConsentParticipantIDs = ["p1"]
        store.activeRoom = room
        XCTAssertTrue(store.hasRoomCloudConsent)
        room.cloudConsentParticipantIDs = []
        store.activeRoom = room
        XCTAssertFalse(store.hasRoomCloudConsent)
        store.activeRoom = nil
        XCTAssertFalse(store.hasRoomCloudConsent)
    }

    func testIncompleteCloudRoundNeverBecomesAVerdict() throws {
        let room = room()
        let verdict = RoundVerdict(id: "v", roomID: room.id, summary: "An invented winner", teamPlacements: [],
                                  speakerAssessments: [], limitation: "Experimental", createdAt: Date().timeIntervalSince1970)
        let status = CloudRoomJudgeStatus(state: "complete", completedSteps: 1, totalSteps: 1, message: "Done", room: room, verdict: verdict, code: nil)
        XCTAssertThrowsError(try CloudRoomAPI.validate(status, roomID: room.id))
        XCTAssertThrowsError(try CloudRoomAPI.validate(status, roomID: "another-room"))
    }

    func testRoomAPIBindsConsentAndCaptureToAuthenticatedRoomWithoutProviderKey() async throws {
        let fixture = RoomAIFixture()
        defer { fixture.remove() }
        fixture.respond { request in
            XCTAssertEqual(request.url?.path, "/v1/rooms/test-room/ai/captures")
            XCTAssertGreaterThanOrEqual(request.timeoutInterval, 500)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer room-test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Debattle-Cloud-Consent"), "room-v1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try JSONSerialization.jsonObject(with: RoomAIFixture.body(request)) as? [String: String]
            XCTAssertEqual(body, ["turnID": "turn-1"])
            return (200, Data(#"{"captureID":"bound-capture","maxAudioSeconds":960}"#.utf8))
        }
        let ticket = try await fixture.api.startCapture(roomID: "test-room", turnID: "turn-1")
        XCTAssertEqual(ticket.captureID, "bound-capture")
        XCTAssertEqual(ticket.maxAudioSeconds, 960)
    }

    func testConsentRequestDoesNotImplicitlyUploadSpeech() async throws {
        let fixture = RoomAIFixture()
        defer { fixture.remove() }
        let response = try JSONEncoder().encode(["room": room()])
        fixture.respond { request in
            XCTAssertEqual(request.url?.path, "/v1/rooms/test-room/ai/consent")
            let body = try JSONSerialization.jsonObject(with: RoomAIFixture.body(request)) as? [String: Bool]
            XCTAssertEqual(body, ["enabled": false])
            return (200, response)
        }
        _ = try await fixture.api.setConsent(roomID: "test-room", enabled: false)
    }

    func testCloudRoomFailuresDoNotExposePrivateProviderResponses() async {
        let fixture = RoomAIFixture()
        defer { fixture.remove() }
        fixture.respond { _ in (429, Data(#"{"error":"private-debug-secret"}"#.utf8)) }
        do { _ = try await fixture.api.startCapture(roomID: "test-room", turnID: "turn-1"); XCTFail("Expected quota") }
        catch { XCTAssertEqual(error as? CloudRoomError, .quota); XCTAssertFalse(error.localizedDescription.contains("private-debug")) }
    }

    func testCancellingACloudRequestCancelsTheNetworkTask() async throws {
        let fixture = RoomAIFixture()
        defer { fixture.remove() }
        let started = expectation(description: "Capture authorization started")
        let stopped = expectation(description: "Capture authorization cancelled")
        fixture.respond(onStop: { stopped.fulfill() }) { _ in started.fulfill(); return nil }
        let task = Task { try await fixture.api.startCapture(roomID: "test-room", turnID: "turn-1") }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 2)
        do { _ = try await task.value; XCTFail("A cancelled ticket cannot start recording") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func room() -> DebateRoom {
        DebateRoom(id: "test-room", title: "A motion", language: "English", format: FormatCatalog.duel, hostID: "p1")
    }

    private func buffer(_ values: [Float], rate: Double = 24_000) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let result = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)))
        result.frameLength = AVAudioFrameCount(values.count)
        for (index, value) in values.enumerated() { result.floatChannelData![0][index] = value }
        return result
    }
}

private final class RoomAIFixture: @unchecked Sendable {
    let host = "\(UUID().uuidString.lowercased()).test"
    lazy var api: CloudRoomAPI = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RoomAITestProtocol.self]
        return CloudRoomAPI(connection: CloudPracticeConnection(baseURL: URL(string: "https://\(host)")!, token: "room-test-token"), configuration: config)
    }()
    func respond(onStop: (@Sendable () -> Void)? = nil, handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)?) {
        RoomAITestProtocol.install(host: host, onStop: onStop, handler: handler)
    }
    func remove() { RoomAITestProtocol.remove(host: host) }
    static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

private final class RoomAITestProtocol: URLProtocol, @unchecked Sendable {
    struct Entry: Sendable {
        let onStop: (@Sendable () -> Void)?
        let handler: @Sendable (URLRequest) throws -> (Int, Data)?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    private var onStop: (@Sendable () -> Void)?
    static func install(host: String, onStop: (@Sendable () -> Void)?, handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)?) {
        lock.withLock { entries[host] = Entry(onStop: onStop, handler: handler) }
    }
    static func remove(host: String) { _ = lock.withLock { entries.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { lock.withLock { entries[request.url?.host ?? ""] != nil } }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let entry = Self.lock.withLock({ Self.entries[request.url?.host ?? ""] }) else { return }
        onStop = entry.onStop
        do {
            guard let (status, data) = try entry.handler(request), let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { onStop?() }
}
