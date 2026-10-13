import AVFoundation
import Foundation
import XCTest
@testable import Debattle

final class CloudPracticeTests: XCTestCase {
    func testPCMEncodingIsCanonicalLittleEndianAndSanitizesInvalidSamples() throws {
        let audio = CloudPracticeAudioBuffer()
        audio.start(generation: UUID())
        XCTAssertNil(audio.append(try buffer([-2, -1, -0.5, 0, 0.5, 1, 2, .nan, .infinity, -.infinity])))
        let wav = try audio.finish()
        try CloudPracticeWAV.validate(wav)
        XCTAssertEqual(wav.count, 64)
        XCTAssertEqual(Array(wav.suffix(20)), [0, 128, 0, 128, 0, 192, 0, 0, 0, 64, 255, 127, 255, 127, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Array(wav[24..<28]), [192, 93, 0, 0]) // 24,000 Hz.
    }

    func testAudioLimitPreservesTheAllowedPrefixAndIgnoresTimerOvershoot() throws {
        let audio = CloudPracticeAudioBuffer(maximumFrames: 4)
        audio.start(generation: UUID())
        XCTAssertNil(audio.append(try buffer([0.5, -.infinity])))
        XCTAssertNil(audio.append(try buffer([1, -1, 0.5, 0.5])))
        XCTAssertNil(audio.append(try buffer([0.5])))
        let wav = try audio.finish()
        XCTAssertEqual(wav.count, 52)
        XCTAssertEqual(Array(wav.suffix(8)), [0, 64, 0, 0, 255, 127, 0, 128])
        try CloudPracticeWAV.validate(wav)
        audio.cancel()
        XCTAssertThrowsError(try audio.finish()) { XCTAssertEqual($0 as? CloudPracticeError, .noAudio) }
    }

    func testAllAppLanguagesMapToServerLanguageCodes() throws {
        let expected = ["en", "ru", "es", "kk", "fr", "de", "ar", "zh", "ja", "pt", "hi", "tr"]
        XCTAssertEqual(try debateLanguages.map(CloudPracticeAPI.languageCode), expected)
        XCTAssertThrowsError(try CloudPracticeAPI.languageCode("not-a-language"))
    }

    func testWrongFormatAndForgedWAVHeadersAreRejected() throws {
        let audio = CloudPracticeAudioBuffer()
        audio.start(generation: UUID())
        XCTAssertEqual(audio.append(try buffer([0.5], sampleRate: 48_000))?.1, .invalidAudio)
        var wav = try CloudPracticeWAV.encode(pcm: Data([0, 0]))
        wav[22] = 2 // Stereo is forbidden even if the payload length is plausible.
        XCTAssertThrowsError(try CloudPracticeWAV.validate(wav))
        wav[22] = 1
        wav[40] = 4 // Forged data length.
        XCTAssertThrowsError(try CloudPracticeWAV.validate(wav))
    }

    func testMultilingualExcerptDoesNotSplitUTF8AndRejectsAlteredEvidence() throws {
        let source = String(repeating: "Қазақ тіліндегі дәлел. 🇰🇿 ", count: 200)
        let excerpt = CloudPracticeAPI.excerpt(from: source)
        XCTAssertLessThanOrEqual(excerpt.utf8.count, 2_200)
        XCTAssertTrue(Data(source.utf8).starts(with: Data(excerpt.utf8)))
        XCTAssertEqual(String(data: Data(excerpt.utf8), encoding: .utf8), excerpt)
        try CloudPracticeAPI.validate(feedback(excerpt: excerpt, quote: "Қазақ тіліндегі дәлел."), source: source)
        XCTAssertThrowsError(try CloudPracticeAPI.validate(feedback(excerpt: excerpt, quote: "An invented quotation"), source: source))
        XCTAssertThrowsError(try CloudPracticeAPI.validate(feedback(excerpt: "An unrelated excerpt", quote: "unrelated"), source: source))
        let accented = String(repeating: "café supports a claim. ", count: 5)
        XCTAssertThrowsError(try CloudPracticeAPI.validate(feedback(excerpt: accented.trimmingCharacters(in: .whitespaces), quote: "cafe\u{301}"), source: accented),
                             "Unicode-equivalent text is not a byte-exact quotation of this source.")
    }

    func testInvalidOrMissingFeedbackFieldsCannotBecomeCoaching() {
        let source = String(repeating: "Evidence supports the argument. ", count: 4).trimmingCharacters(in: .whitespaces)
        let invalid = CloudPracticeFeedback(summary: "Summary", strengths: [], improvements: [], reviewedText: source, provider: "Groq", model: "test")
        XCTAssertThrowsError(try CloudPracticeAPI.validate(invalid, source: source))
    }

    func testInvalidMotionsAreRejectedLocallyWithoutSendingTranscript() async {
        let fixture = CloudAPIFixture()
        defer { fixture.remove() }
        fixture.respond { _ in XCTFail("Invalid motions must not send an HTTP request"); return (500, Data()) }
        let transcript = String(repeating: "Evidence supports the argument. ", count: 4)
        for motion in ["", " \n\t ", String(repeating: "a", count: 501), String(repeating: "🌍", count: 251)] {
            do {
                _ = try await fixture.api.feedback(motion: motion, language: "English", transcript: transcript)
                XCTFail("Expected invalid motion rejection")
            } catch {
                XCTAssertEqual(error as? CloudPracticeError, .invalidMotion)
            }
        }
        XCTAssertEqual(fixture.requestCount, 0)
    }

    func testAPIUsesConfiguredEndpointConsentAndOnlySendsTheReviewedExcerpt() async throws {
        let fixture = CloudAPIFixture()
        defer { fixture.remove() }
        let source = String(repeating: "Evidence supports the argument. ", count: 200)
        let expectedExcerpt = CloudPracticeAPI.excerpt(from: source)
        let response = try JSONEncoder().encode(feedback(excerpt: expectedExcerpt, quote: "Evidence supports the argument."))
        fixture.respond { request in
            XCTAssertEqual(request.url?.host, fixture.host)
            XCTAssertEqual(request.url?.path, "/v1/ai/feedback")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-cloud-test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Debattle-Cloud-Consent"), "practice-v1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertGreaterThanOrEqual(request.timeoutInterval, 150)
            let object = try JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: String]
            XCTAssertEqual(object?["language"], "ru")
            XCTAssertEqual(object?["transcript"], expectedExcerpt)
            return (200, response)
        }
        let result = try await fixture.api.feedback(motion: "A motion", language: "Russian", transcript: source)
        XCTAssertEqual(result.reviewedText, expectedExcerpt)
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testStatusIsAuthenticatedAndDoesNotSendConsentOrAudio() async throws {
        let fixture = CloudAPIFixture()
        defer { fixture.remove() }
        fixture.respond { request in
            XCTAssertEqual(request.url?.path, "/v1/ai/status")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Debattle-Cloud-Consent"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-cloud-test-token")
            XCTAssertTrue(try Self.requestBody(request).isEmpty)
            return (200, Data(#"{"available":true,"provider":"Groq","message":"Ready","maxAudioSeconds":420}"#.utf8))
        }
        let status = try await fixture.api.status()
        XCTAssertTrue(status.available)
        XCTAssertEqual(status.maxAudioSeconds, 420)
    }

    func testServerFailuresAreSanitizedAndResponsesAreBounded() async throws {
        let fixture = CloudAPIFixture()
        defer { fixture.remove() }
        fixture.respond { _ in (502, Data(#"{"error":"private-provider-debug-details"}"#.utf8)) }
        do { _ = try await fixture.api.status(); XCTFail("Expected unavailable") }
        catch { XCTAssertEqual(error as? CloudPracticeError, .unavailable); XCTAssertFalse(error.localizedDescription.contains("private-provider")) }

        fixture.respond { _ in (200, Data(repeating: 65, count: CloudPracticeAPI.maximumResponseBytes + 1)) }
        do { _ = try await fixture.api.status(); XCTFail("Expected bounded response failure") }
        catch { XCTAssertEqual(error as? CloudPracticeError, .responseTooLarge) }
    }

    func testRedirectResponsesDoNotFollowTheLocation() async throws {
        let fixture = CloudAPIFixture()
        defer { fixture.remove() }
        fixture.respond { _ in (307, Data()) }
        do { _ = try await fixture.api.status(); XCTFail("Expected redirect rejection") }
        catch { XCTAssertEqual(error as? CloudPracticeError, .invalidConnection) }
        XCTAssertEqual(fixture.requestCount, 1)
        // The production session uses the same no-forwarding delegate covered by ConnectionTests.
    }

    @MainActor
    func testCancelBeforeFinishDiscardsAudioWithoutMakingAnyRequest() async throws {
        let fixture = CloudAPIFixture()
        defer { fixture.remove() }
        fixture.respond { _ in XCTFail("Cancelled recording must not upload"); return (500, Data()) }
        let transcriber = CloudPracticeTranscriber(api: fixture.api)
        try await transcriber.start(language: "Kazakh")
        transcriber.append(try buffer([0.2, 0.4, 0.1]))
        transcriber.cancel()
        let text = await transcriber.finish()
        XCTAssertEqual(text, "")
        XCTAssertEqual(fixture.requestCount, 0)
        XCTAssertFalse(transcriber.isRecording)
    }

    @MainActor
    func testExplicitFinishUploadsCanonicalAudioAndPublishesTranscript() async throws {
        let fixture = CloudAPIFixture()
        defer { fixture.remove() }
        fixture.respond { request in
            XCTAssertEqual(request.url?.path, "/v1/ai/transcribe")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "kk")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Debattle-Cloud-Consent"), "practice-v1")
            try CloudPracticeWAV.validate(Self.requestBody(request))
            return (200, Data(#"{"text":"Қазақ тіліндегі дәлел.","provider":"Groq","model":"whisper-large-v3"}"#.utf8))
        }
        let transcriber = CloudPracticeTranscriber(api: fixture.api)
        try await transcriber.start(language: "Kazakh")
        transcriber.append(try buffer([0.2, 0.4, 0.1]))
        XCTAssertEqual(fixture.requestCount, 0)
        let text = await transcriber.finish()
        XCTAssertEqual(text, "Қазақ тіліндегі дәлел.")
        XCTAssertEqual(transcriber.partialText, text)
        XCTAssertFalse(transcriber.isRecording)
        XCTAssertNil(transcriber.errorMessage)
    }

    @MainActor
    func testUploadFailurePublishesSafeErrorWithoutInventingTranscript() async throws {
        let fixture = CloudAPIFixture()
        defer { fixture.remove() }
        fixture.respond { _ in (503, Data(#"{"error":"private provider response"}"#.utf8)) }
        let transcriber = CloudPracticeTranscriber(api: fixture.api)
        try await transcriber.start(language: "Spanish")
        transcriber.append(try buffer([0.2, 0.4]))
        let text = await transcriber.finish()
        XCTAssertTrue(text.isEmpty)
        XCTAssertTrue(transcriber.partialText.isEmpty)
        XCTAssertEqual(transcriber.errorMessage, CloudPracticeError.unavailable.localizedDescription)
        XCTAssertFalse(transcriber.isRecording)
    }

    @MainActor
    func testCancelDuringUploadStopsRequestAndNeverPublishesItsResult() async throws {
        let fixture = CloudAPIFixture()
        defer { fixture.remove() }
        let started = expectation(description: "Upload started")
        let stopped = expectation(description: "Upload cancelled")
        fixture.respond(onStop: { stopped.fulfill() }) { _ in started.fulfill(); return nil }
        let transcriber = CloudPracticeTranscriber(api: fixture.api)
        try await transcriber.start(language: "English")
        transcriber.append(try buffer([0.2, 0.4, 0.1]))
        let finish = Task { await transcriber.finish() }
        await fulfillment(of: [started], timeout: 2)
        transcriber.cancel()
        await fulfillment(of: [stopped], timeout: 2)
        let text = await finish.value
        XCTAssertTrue(text.isEmpty)
        XCTAssertTrue(transcriber.partialText.isEmpty)
        XCTAssertNil(transcriber.errorMessage)
        XCTAssertFalse(transcriber.isRecording)
    }

    private func buffer(_ samples: [Float], sampleRate: Double = 24_000) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { buffer.floatChannelData![0][index] = sample }
        return buffer
    }

    private func feedback(excerpt: String, quote: String) -> CloudPracticeFeedback {
        let observation = CloudPracticeObservation(quote: quote, explanation: "Explain the evidence linking this claim to its consequence.")
        return CloudPracticeFeedback(summary: "Consider the link between evidence and the claim.", strengths: [observation], improvements: [observation],
                                     reviewedText: excerpt, provider: "Groq", model: "synthetic-test-model")
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count < 0 { throw URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
}

private final class CloudAPIFixture: @unchecked Sendable {
    let host = "\(UUID().uuidString.lowercased()).test"
    private let lock = NSLock()
    private var count = 0
    var requestCount: Int { lock.withLock { count } }
    lazy var api: CloudPracticeAPI = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudTestURLProtocol.self]
        return CloudPracticeAPI(connection: CloudPracticeConnection(baseURL: URL(string: "https://\(host)")!, token: "synthetic-cloud-test-token"), configuration: configuration)
    }()

    func respond(onStop: (@Sendable () -> Void)? = nil,
                 handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)?) {
        CloudTestURLProtocol.install(host: host, onStop: onStop) { [self] request in
            lock.withLock { count += 1 }
            return try handler(request)
        }
    }

    func remove() { CloudTestURLProtocol.remove(host: host) }
}

private final class CloudTestURLProtocol: URLProtocol, @unchecked Sendable {
    struct Entry: Sendable {
        let handler: @Sendable (URLRequest) throws -> (Int, Data)?
        let onStop: (@Sendable () -> Void)?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    private var onStop: (@Sendable () -> Void)?
    static func install(host: String, onStop: (@Sendable () -> Void)?, handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)?) {
        lock.withLock { entries[host] = Entry(handler: handler, onStop: onStop) }
    }
    static func remove(host: String) { _ = lock.withLock { entries.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { lock.withLock { entries[request.url?.host ?? ""] != nil } }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let entry = Self.lock.withLock({ Self.entries[request.url?.host ?? ""] }) else { return }
        onStop = entry.onStop
        do {
            guard let (status, data) = try entry.handler(request), let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json", "Location": "https://untrusted.test/collect"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { onStop?() }
}
