import AVFoundation
import Foundation
import Observation
import XCTest
@testable import Debattle

final class PracticeSessionTests: XCTestCase {
    @MainActor
    func testFeedbackWithShortOrWhitespaceOnlyTextExplainsMinimumInsteadOfDoingNothing() async {
        let coach = StubPracticeCoach()
        let session = PracticeSession(voice: StubPracticeVoice(), transcriber: StubPracticeTranscriber(), judge: coach)
        for text in ["", "   \n ", "A short argument."] {
            session.transcript = text
            await session.review()
            XCTAssertTrue(session.message?.contains("80 characters") == true)
            XCTAssertEqual(coach.requestCount, 0)
            XCTAssertFalse(session.hasCaptureFailure)
        }
    }

    @MainActor
    func testUnavailableFeedbackShowsReasonWithoutStartingGenerationOrErasingSpeech() async {
        let coach = StubPracticeCoach()
        coach.isAvailable = false
        coach.availabilityMessage = "Enable Apple Intelligence in Settings."
        let session = PracticeSession(voice: StubPracticeVoice(), transcriber: StubPracticeTranscriber(), judge: coach)
        session.transcript = String(repeating: "An argument with evidence. ", count: 5)
        let draft = session.transcript

        await session.review()

        XCTAssertEqual(session.message, coach.availabilityMessage)
        XCTAssertEqual(coach.requestCount, 0)
        XCTAssertEqual(session.transcript, draft)
        XCTAssertNil(session.feedback)
    }

    @MainActor
    func testAvailabilityRefreshUsesSelectedLanguageAndRetryCanGenerateAfterSettingsChange() async {
        let coach = StubPracticeCoach()
        coach.isAvailable = false
        let session = PracticeSession(voice: StubPracticeVoice(), transcriber: StubPracticeTranscriber(), judge: coach)
        session.language = "Spanish"
        session.transcript = String(repeating: "La propuesta necesita evidencia y una explicación. ", count: 3)
        await session.review()
        XCTAssertEqual(coach.lastLanguage, "Spanish")
        XCTAssertEqual(coach.requestCount, 0)

        coach.isAvailable = true // Simulate returning after enabling/downloading the model.
        session.refreshCapabilities()
        XCTAssertNil(session.message, "The old unavailable message must disappear before another request.")
        await session.review()

        XCTAssertEqual(coach.requestCount, 1)
        XCTAssertNotNil(session.feedback)
        XCTAssertNil(session.message)
        XCTAssertEqual(session.lastRoom?.language, "Spanish")
    }

    @MainActor
    func testChangingInputClearsFeedbackErrorButRefreshPreservesCaptureFailure() async {
        let speech = StubPracticeTranscriber()
        let session = PracticeSession(voice: StubPracticeVoice(), transcriber: speech, judge: StubPracticeCoach())
        await session.review()
        XCTAssertNotNil(session.message)
        session.transcript = "An edited draft"
        session.clearFeedbackForInputChange()
        XCTAssertNil(session.message)

        speech.startHandler = { throw StubPracticeError.unavailable }
        await session.start()
        let captureMessage = session.message
        XCTAssertTrue(session.hasCaptureFailure)
        session.refreshCapabilities()
        XCTAssertEqual(session.message, captureMessage)
    }

    @MainActor
    func testLeavingBeforeRequestedFeedbackStartsDoesNotGenerateOrShowAnError() async {
        let coach = StubPracticeCoach()
        let session = PracticeSession(voice: StubPracticeVoice(), transcriber: StubPracticeTranscriber(), judge: coach)
        for draft in ["A short draft.", String(repeating: "A proposal needs supporting evidence. ", count: 4)] {
            session.transcript = draft
            session.requestReview()
            session.endSession() // No suspension: cancel before the queued MainActor task can start.

            // Give the cancelled task time to run so both preflight errors and generation are checked.
            try? await Task.sleep(for: .milliseconds(20))

            XCTAssertEqual(coach.requestCount, 0)
            XCTAssertNil(session.message)
            XCTAssertNil(session.feedback)
            XCTAssertEqual(session.transcript, draft)
        }
    }

    @MainActor
    func testLeavingCancelsRequestedFeedbackAndAllowsAnotherAttempt() async {
        let coach = StubPracticeCoach()
        coach.handler = { try await Task.sleep(for: .seconds(60)) }
        let session = PracticeSession(voice: StubPracticeVoice(), transcriber: StubPracticeTranscriber(), judge: coach)
        session.transcript = String(repeating: "A proposal needs supporting evidence. ", count: 4)
        session.requestReview()
        await waitFor { coach.isGenerating }

        session.endSession()
        await waitFor { !coach.isGenerating }
        XCTAssertNil(session.feedback)
        XCTAssertNil(session.message)

        coach.handler = nil
        session.requestReview()
        await waitFor { session.feedback != nil }
        XCTAssertEqual(coach.requestCount, 2)
    }

    @MainActor
    func testGenerationFailureIsReportedAndTranscriptRemainsEditable() async {
        let coach = StubPracticeCoach()
        coach.handler = { throw JudgeError.generationFailed("The model could not complete feedback. Try again.") }
        let session = PracticeSession(voice: StubPracticeVoice(), transcriber: StubPracticeTranscriber(), judge: coach)
        session.transcript = String(repeating: "Evidence should support this proposal. ", count: 4)
        let draft = session.transcript

        await session.review()

        XCTAssertEqual(session.message, "The model could not complete feedback. Try again.")
        XCTAssertEqual(session.transcript, draft)
        XCTAssertFalse(session.isCapturing)
        XCTAssertFalse(session.hasCaptureFailure)
    }

    @MainActor
    func testOldFeedbackFailureCannotReplaceStatusForAChangedLanguage() async {
        let coach = StubPracticeCoach()
        var completion: CheckedContinuation<Void, Never>?
        coach.handler = {
            await withCheckedContinuation { completion = $0 }
            throw JudgeError.generationFailed("Old English failure")
        }
        let session = PracticeSession(voice: StubPracticeVoice(), transcriber: StubPracticeTranscriber(), judge: coach)
        session.transcript = String(repeating: "Evidence should support this proposal. ", count: 4)
        let task = Task { await session.review() }
        await waitFor { completion != nil }
        session.language = "Spanish"
        completion?.resume()
        await task.value
        XCTAssertNil(session.message)
        XCTAssertNil(session.feedback)
    }

    @MainActor
    func testLiveRecognitionUpdatesTheEditableTranscriptBeforeFinishing() async {
        let voice = StubPracticeVoice()
        let speech = StubPracticeTranscriber()
        let session = PracticeSession(voice: voice, transcriber: speech)
        await session.start()
        XCTAssertTrue(session.isRecording)

        speech.partialText = "A live argument appears while the microphone is still open."
        await waitFor { session.transcript == speech.partialText }

        XCTAssertTrue(session.isRecording)
        XCTAssertTrue(voice.isMicrophoneEnabled)
        XCTAssertEqual(speech.finishCount, 0)
        await session.stop()
        XCTAssertEqual(session.transcript, "A live argument appears while the microphone is still open.")
        XCTAssertFalse(session.isCapturing)
    }

    @MainActor
    func testRuntimeTranscriptionFailureStopsListeningAndPreservesPartialWords() async {
        let voice = StubPracticeVoice()
        let speech = StubPracticeTranscriber()
        speech.finishHandler = { "" } // Some recognition failures never deliver a final result.
        let session = PracticeSession(voice: voice, transcriber: speech)
        await session.start()
        speech.partialText = "These words were recognized before the service failed."
        speech.errorMessage = "The recognizer stopped unexpectedly."
        speech.isRecording = false

        await waitFor { !session.isCapturing }

        XCTAssertFalse(voice.isMicrophoneEnabled)
        XCTAssertFalse(session.isRecording)
        XCTAssertEqual(session.transcript, "These words were recognized before the service failed.")
        XCTAssertTrue(session.message?.contains("The recognizer stopped unexpectedly.") == true,
                      "Keep the service's actionable cause instead of replacing it with generic copy.")
        XCTAssertTrue(session.hasCaptureFailure)
        XCTAssertFalse(session.statusText.contains("Listening"))
        XCTAssertFalse(session.statusText.contains("only when you’re ready"))
        XCTAssertEqual(speech.finishCount, 1)
    }

    @MainActor
    func testMicrophoneInterruptionFinalizesTextAndReportsTheFailure() async {
        let voice = StubPracticeVoice()
        let speech = StubPracticeTranscriber()
        let session = PracticeSession(voice: voice, transcriber: speech)
        await session.start()
        speech.partialText = "The argument before the audio route changed."
        voice.isMicrophoneEnabled = false
        voice.errorMessage = "Your audio device changed."

        await waitFor { !session.isCapturing }

        XCTAssertEqual(session.transcript, speech.partialText)
        XCTAssertEqual(session.message, "Your audio device changed.")
        XCTAssertNil(session.deadline)
    }

    @MainActor
    func testRecognitionStartupFailureClosesMicrophoneAndKeepsPastedText() async {
        let voice = StubPracticeVoice()
        let speech = StubPracticeTranscriber()
        var events: [String] = []
        voice.startHandler = { events.append("microphone") }
        speech.startHandler = {
            events.append("recognizer")
            throw StubPracticeError.unavailable
        }
        let session = PracticeSession(voice: voice, transcriber: speech)
        session.transcript = "An existing pasted draft should not be erased by a permission failure."

        await session.start()

        XCTAssertEqual(events, ["microphone", "recognizer"])
        XCTAssertFalse(session.isCapturing)
        XCTAssertFalse(voice.isMicrophoneEnabled)
        XCTAssertEqual(session.transcript, "An existing pasted draft should not be erased by a permission failure.")
        XCTAssertNotNil(session.message)
    }

    @MainActor
    func testRecognizerThatFailsDuringStartupCannotBecomeListening() async {
        let voice = StubPracticeVoice()
        let speech = StubPracticeTranscriber()
        speech.startHandler = { speech.errorMessage = "No offline recognizer is available." }
        let session = PracticeSession(voice: voice, transcriber: speech)

        await session.start()

        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(session.isStarting)
        XCTAssertFalse(voice.isMicrophoneEnabled)
        XCTAssertFalse(session.statusText.contains("Listening"))
        XCTAssertNotNil(session.message)
    }

    @MainActor
    func testCancelledMicrophonePermissionCompletionCannotStopANewAttempt() async {
        let voice = StubPracticeVoice()
        let speech = StubPracticeTranscriber()
        var permission: CheckedContinuation<Void, Never>?
        voice.startHandler = {
            if voice.startCount == 1 { await withCheckedContinuation { permission = $0 } }
        }
        let session = PracticeSession(voice: voice, transcriber: speech)
        let oldAttempt = Task { await session.start() }
        await waitFor { permission != nil }
        await session.stop()
        XCTAssertFalse(session.isCapturing)

        await session.start()
        XCTAssertTrue(session.isRecording)
        let stopsBeforeOldCompletion = voice.stopCount
        permission?.resume()
        await oldAttempt.value

        XCTAssertTrue(session.isRecording)
        XCTAssertTrue(voice.isMicrophoneEnabled)
        XCTAssertEqual(voice.stopCount, stopsBeforeOldCompletion)
        XCTAssertEqual(speech.startCount, 1)
        await session.stop()
    }

    @MainActor
    func testCancelledSpeechAuthorizationCannotOverwriteANewAttempt() async {
        let voice = StubPracticeVoice()
        let speech = StubPracticeTranscriber()
        var authorization: CheckedContinuation<Void, Never>?
        speech.startHandler = {
            if speech.startCount == 1 { await withCheckedContinuation { authorization = $0 } }
        }
        let session = PracticeSession(voice: voice, transcriber: speech)
        let oldAttempt = Task { await session.start() }
        await waitFor { authorization != nil }
        await session.stop()
        await session.start()
        speech.partialText = "The second attempt belongs to the current recording."
        await waitFor { session.transcript == speech.partialText }

        authorization?.resume()
        await oldAttempt.value

        XCTAssertTrue(session.isRecording)
        XCTAssertTrue(voice.isMicrophoneEnabled)
        XCTAssertEqual(session.transcript, "The second attempt belongs to the current recording.")
        XCTAssertNil(session.message)
        await session.stop()
    }

    @MainActor
    func testFinalizationIsSharedAndBlocksRestartUntilItsResultIsSaved() async {
        let voice = StubPracticeVoice()
        let speech = StubPracticeTranscriber()
        var finalResult: CheckedContinuation<String, Never>?
        speech.finishHandler = { await withCheckedContinuation { finalResult = $0 } }
        let session = PracticeSession(voice: voice, transcriber: speech)
        await session.start()
        speech.partialText = "A useful partial result."
        let firstStop = Task { await session.stop() }
        await waitFor { finalResult != nil }
        let secondStop = Task { await session.stop() }
        await session.start() // Must not erase text or start overlapping framework sessions.

        XCTAssertTrue(session.isFinalizing)
        XCTAssertFalse(voice.isMicrophoneEnabled)
        XCTAssertEqual(session.transcript, "A useful partial result.")
        XCTAssertEqual(voice.startCount, 1)
        XCTAssertEqual(speech.finishCount, 1)

        finalResult?.resume(returning: "The finalized result belongs to the first speech.")
        await firstStop.value
        await secondStop.value
        XCTAssertFalse(session.isCapturing)
        XCTAssertEqual(session.transcript, "The finalized result belongs to the first speech.")

        speech.finishHandler = nil
        await session.start()
        XCTAssertTrue(session.isRecording)
        XCTAssertEqual(voice.startCount, 2)
        await session.stop()
    }

    @MainActor
    func testLeavingPracticeClosesInputSynchronouslyBeforeFinalizationCompletes() async {
        let voice = StubPracticeVoice()
        let speech = StubPracticeTranscriber()
        var finalResult: CheckedContinuation<String, Never>?
        speech.finishHandler = { await withCheckedContinuation { finalResult = $0 } }
        let session = PracticeSession(voice: voice, transcriber: speech)
        await session.start()
        speech.partialText = "Keep the speech when the screen disappears."

        session.endSession()

        XCTAssertFalse(voice.isMicrophoneEnabled, "Closing input must not wait for another scheduled UI task.")
        XCTAssertTrue(session.isFinalizing)
        XCTAssertNil(session.deadline)
        await waitFor { finalResult != nil }
        finalResult?.resume(returning: "")
        await session.stop()
        XCTAssertEqual(session.transcript, "Keep the speech when the screen disappears.")
    }

    @MainActor
    func testTaskCancellationDuringStartupIsNormalCleanupWithoutAnErrorBanner() async {
        let voice = StubPracticeVoice()
        let speech = StubPracticeTranscriber()
        var permission: CheckedContinuation<Void, Never>?
        voice.startHandler = { await withCheckedContinuation { permission = $0 } }
        let session = PracticeSession(voice: voice, transcriber: speech)
        let task = Task { await session.start() }
        await waitFor { permission != nil }
        task.cancel()
        permission?.resume()
        await task.value

        XCTAssertFalse(session.isCapturing)
        XCTAssertFalse(voice.isMicrophoneEnabled)
        XCTAssertEqual(speech.startCount, 0)
        XCTAssertNil(session.message)
    }

    @MainActor
    func testAudioFailureReportedThroughCancellationKeepsItsCauseVisible() async {
        let voice = StubPracticeVoice()
        let speech = StubPracticeTranscriber()
        voice.startHandler = {
            voice.errorMessage = "The audio device changed while the microphone was starting."
            throw CancellationError()
        }
        let session = PracticeSession(voice: voice, transcriber: speech)

        await session.start()

        XCTAssertFalse(session.isCapturing)
        XCTAssertFalse(voice.isMicrophoneEnabled)
        XCTAssertEqual(speech.startCount, 0)
        XCTAssertEqual(session.message, "The audio device changed while the microphone was starting.")
        XCTAssertTrue(session.hasCaptureFailure)
        XCTAssertFalse(session.statusText.contains("only when you’re ready"))
    }

    @MainActor
    func testCloudBackgroundingDiscardsAudioWithoutUploadingAndPreservesDraft() async {
        let (session, voice, speech, coach) = makeCloudSession()
        session.transcript = "My existing editable draft."
        await session.start()
        XCTAssertEqual(session.transcript, "My existing editable draft.")
        XCTAssertTrue(session.statusText.contains("memory"))

        session.endSession()

        XCTAssertFalse(voice.isMicrophoneEnabled)
        XCTAssertFalse(session.isCapturing)
        XCTAssertFalse(session.usesCloudProcessing, "Cloud consent is limited to the visible Practice session.")
        XCTAssertEqual(speech.finishCount, 0, "Leaving must never invoke a cloud transcriber's upload entry point.")
        XCTAssertGreaterThan(speech.cancelCount, 0)
        XCTAssertEqual(coach.requestCount, 0)
        XCTAssertEqual(session.transcript, "My existing editable draft.")
    }

    @MainActor
    func testCloudCaptureFailuresDiscardInsteadOfFinishingOrSendingPartialAudio() async {
        for microphoneFailure in [true, false] {
            let (session, voice, speech, _) = makeCloudSession()
            session.transcript = "Keep this pasted draft after capture fails."
            await session.start()
            if microphoneFailure {
                voice.errorMessage = "The microphone was interrupted."
                voice.isMicrophoneEnabled = false
            } else {
                speech.errorMessage = "The in-memory recording limit was reached."
                speech.isRecording = false
            }

            await waitFor { !session.isCapturing }

            XCTAssertEqual(speech.finishCount, 0)
            XCTAssertGreaterThan(speech.cancelCount, 0)
            XCTAssertFalse(voice.isMicrophoneEnabled)
            XCTAssertTrue(session.hasCaptureFailure)
            XCTAssertEqual(session.transcript, "Keep this pasted draft after capture fails.")
            XCTAssertTrue(session.usesCloudProcessing, "A failed attempt must not silently select another provider.")
        }
    }

    @MainActor
    func testCloudFinishUploadsOnceAndDoesNotAutomaticallyRequestFeedback() async {
        let (session, voice, speech, coach) = makeCloudSession()
        session.transcript = "Keep the draft while a new transcript is pending."
        var result: CheckedContinuation<String, Never>?
        speech.finishHandler = { await withCheckedContinuation { result = $0 } }
        await session.start()

        let firstFinish = Task { await session.stop() }
        await waitFor { result != nil }
        let secondFinish = Task { await session.stop() }
        XCTAssertFalse(voice.isMicrophoneEnabled)
        XCTAssertTrue(session.isFinalizing)
        XCTAssertEqual(session.transcript, "Keep the draft while a new transcript is pending.")
        XCTAssertEqual(speech.finishCount, 1)
        XCTAssertEqual(coach.requestCount, 0)

        result?.resume(returning: "The cloud transcript returned successfully.")
        await firstFinish.value
        await secondFinish.value

        XCTAssertEqual(session.transcript, "The cloud transcript returned successfully.")
        XCTAssertFalse(session.isCapturing)
        XCTAssertEqual(speech.finishCount, 1)
        XCTAssertEqual(coach.requestCount, 0)
    }

    @MainActor
    func testCloudFinishFailureIsVisibleAndKeepsExistingDraft() async {
        let (session, _, speech, _) = makeCloudSession()
        session.transcript = "A draft that must survive an exhausted provider quota."
        speech.finishHandler = { speech.errorMessage = "Groq quota is exhausted. Try again later."; return "" }
        await session.start()

        await session.stop()

        XCTAssertEqual(session.message, "Groq quota is exhausted. Try again later.")
        XCTAssertTrue(session.hasCaptureFailure)
        XCTAssertEqual(session.transcript, "A draft that must survive an exhausted provider quota.")
        XCTAssertTrue(session.usesCloudProcessing)
        XCTAssertFalse(session.isCapturing)
    }

    @MainActor
    func testCloudFinishCannotUploadAfterAnErrorBeforeItsObserverRuns() async {
        let (session, voice, speech, _) = makeCloudSession()
        await session.start()
        voice.errorMessage = "The audio route was interrupted just before Finish."
        // Do not yield to the observation task: Finish must check the current service state.
        await session.stop()
        XCTAssertEqual(speech.finishCount, 0)
        XCTAssertFalse(session.isCapturing)
        XCTAssertEqual(session.message, "The audio route was interrupted just before Finish.")
    }

    @MainActor
    func testCloudStopDuringStartupCancelsWithoutSendingAudio() async {
        let (session, voice, speech, _) = makeCloudSession()
        var permission: CheckedContinuation<Void, Never>?
        speech.startHandler = { await withCheckedContinuation { permission = $0 } }
        session.transcript = "Keep the draft when preparation is cancelled."
        let start = Task { await session.start() }
        await waitFor { permission != nil }

        await session.stop()
        permission?.resume()
        await start.value

        XCTAssertEqual(speech.finishCount, 0)
        XCTAssertFalse(voice.isMicrophoneEnabled)
        XCTAssertFalse(session.isCapturing)
        XCTAssertEqual(session.transcript, "Keep the draft when preparation is cancelled.")
    }

    @MainActor
    func testCloudCancelledMicrophoneStartupNeverUploadsOrStartsTranscription() async {
        let (session, voice, speech, _) = makeCloudSession()
        var permission: CheckedContinuation<Void, Never>?
        voice.startHandler = { await withCheckedContinuation { permission = $0 } }
        let start = Task { await session.start() }
        await waitFor { permission != nil }

        start.cancel()
        permission?.resume()
        await start.value

        XCTAssertFalse(voice.isMicrophoneEnabled)
        XCTAssertFalse(session.isCapturing)
        XCTAssertEqual(speech.startCount, 0)
        XCTAssertEqual(speech.finishCount, 0)
        XCTAssertNil(session.message)
    }

    @MainActor
    func testRevokingCloudConsentCancelsPendingUploadAndIgnoresLateResult() async {
        let (session, voice, speech, _) = makeCloudSession()
        session.transcript = "The draft before cloud capture."
        var result: CheckedContinuation<String, Never>?
        speech.ignoreFinishCancellation = true // Simulate a remote response arriving despite cancellation.
        speech.finishHandler = { await withCheckedContinuation { result = $0 } }
        await session.start()
        let finish = Task { await session.stop() }
        await waitFor { result != nil }

        session.useOnDevice()
        session.transcript = "A new local draft after consent was revoked."
        result?.resume(returning: "An obsolete cloud transcript must not overwrite the local draft.")
        await finish.value

        XCTAssertFalse(voice.isMicrophoneEnabled)
        XCTAssertFalse(session.isCapturing)
        XCTAssertFalse(session.usesCloudProcessing)
        XCTAssertGreaterThan(speech.cancelCount, 0)
        XCTAssertEqual(session.transcript, "A new local draft after consent was revoked.")
        XCTAssertNil(session.message)
    }

    @MainActor
    func testLeavingDuringCloudFinalizationDiscardsPendingResult() async {
        let (session, _, speech, _) = makeCloudSession()
        session.transcript = "A preserved local draft."
        var result: CheckedContinuation<String, Never>?
        speech.ignoreFinishCancellation = true
        speech.finishHandler = { await withCheckedContinuation { result = $0 } }
        await session.start()
        let finish = Task { await session.stop() }
        await waitFor { result != nil }

        session.endSession()
        result?.resume(returning: "A response after the user left Practice.")
        await finish.value

        XCTAssertEqual(session.transcript, "A preserved local draft.")
        XCTAssertFalse(session.isCapturing)
        XCTAssertFalse(session.usesCloudProcessing)
        XCTAssertGreaterThan(speech.cancelCount, 0)
    }

    @MainActor
    func testConnectionChangeBeforeCloudFinishRevokesConsentWithoutUpload() async {
        let (session, _, speech, coach) = makeCloudSession()
        var connectionIsCurrent = true
        XCTAssertTrue(session.configureServices(transcriber: speech, judge: coach,
                                               cloudConnectionIsCurrent: { connectionIsCurrent }))
        session.transcript = "Keep the speech draft for a different server."
        await session.start()
        connectionIsCurrent = false

        await session.stop()

        XCTAssertEqual(speech.finishCount, 0)
        XCTAssertFalse(session.usesCloudProcessing)
        XCTAssertTrue(session.message?.contains("server connection changed") == true)
        XCTAssertEqual(session.transcript, "Keep the speech draft for a different server.")
    }

    @MainActor
    func testCloudConsentRevocationIgnoresLateFeedback() async {
        let (session, _, _, coach) = makeCloudSession()
        session.transcript = String(repeating: "Evidence should support this argument. ", count: 4)
        var result: CheckedContinuation<Void, Never>?
        coach.handler = { await withCheckedContinuation { result = $0 } }
        session.requestReview()
        await waitFor { result != nil }

        session.useOnDevice()
        result?.resume()
        await waitFor { !coach.isGenerating }

        XCTAssertNil(session.feedback)
        XCTAssertNil(session.message)
        XCTAssertFalse(session.usesCloudProcessing)
        XCTAssertEqual(coach.requestCount, 1, "Only the explicit feedback request may send text.")
    }

    @MainActor
    func testProviderReplacementRequiresIdleSessionAndPreservesPracticeInputs() async {
        let (session, _, speech, _) = makeCloudSession()
        session.motion = "This house would fund public transport."
        session.language = "Spanish"
        session.duration = 60
        session.transcript = "A saved practice draft."
        await session.start()
        XCTAssertFalse(session.configureServices(transcriber: StubPracticeTranscriber(), judge: StubPracticeCoach()))
        XCTAssertTrue(session.transcriber === speech)

        session.useOnDevice()

        XCTAssertEqual(speech.finishCount, 0)
        XCTAssertEqual(session.motion, "This house would fund public transport.")
        XCTAssertEqual(session.language, "Spanish")
        XCTAssertEqual(session.duration, 60)
        XCTAssertEqual(session.transcript, "A saved practice draft.")
    }

    @MainActor
    func testCloudDeadlineNeverExceedsSevenMinutes() async {
        let (session, _, speech, _) = makeCloudSession()
        session.duration = 900
        await session.start()
        XCTAssertLessThanOrEqual(session.deadline?.timeIntervalSinceNow ?? .infinity, 420)
        XCTAssertGreaterThan(session.deadline?.timeIntervalSinceNow ?? 0, 410)
        session.endSession()
        XCTAssertEqual(speech.finishCount, 0)
    }

    @MainActor
    private func makeCloudSession() -> (PracticeSession, StubPracticeVoice, StubPracticeTranscriber, StubPracticeCoach) {
        let voice = StubPracticeVoice()
        let speech = StubPracticeTranscriber()
        speech.usesCloudProcessing = true
        let coach = StubPracticeCoach()
        coach.usesCloudProcessing = true
        return (PracticeSession(voice: voice, transcriber: speech, judge: coach), voice, speech, coach)
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected the scheduled main-actor state transition to complete.", file: file, line: line)
    }
}

@MainActor @Observable
private final class StubPracticeVoice: PracticeVoiceInput {
    var isMicrophoneEnabled = false
    var level: Float = 0
    var errorMessage: String?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    @ObservationIgnored var startHandler: (@MainActor () async throws -> Void)?
    @ObservationIgnored private var generation = UUID()

    func startMicrophone(onAudio: @escaping @Sendable (Data) -> Void,
                         onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?) async throws {
        let attempt = UUID()
        generation = attempt
        startCount += 1
        errorMessage = nil
        try await startHandler?()
        guard generation == attempt else { throw CancellationError() }
        isMicrophoneEnabled = true
    }

    func stop() {
        generation = UUID()
        stopCount += 1
        isMicrophoneEnabled = false
        level = 0
    }
}

@MainActor @Observable
private final class StubPracticeTranscriber: PracticeTranscribing {
    var usesCloudProcessing = false
    var partialText = ""
    var isRecording = false
    var errorMessage: String?
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    var ignoreFinishCancellation = false
    @ObservationIgnored var startHandler: (@MainActor () async throws -> Void)?
    @ObservationIgnored var finishHandler: (@MainActor () async -> String)?
    @ObservationIgnored private var generation = UUID()

    func start(language: String) async throws {
        let attempt = UUID()
        generation = attempt
        startCount += 1
        partialText = ""
        errorMessage = nil
        try await startHandler?()
        guard generation == attempt else { throw CancellationError() }
        isRecording = errorMessage == nil
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) { }

    func finish() async -> String {
        let attempt = generation
        finishCount += 1
        isRecording = false
        let result = await finishHandler?() ?? partialText
        guard generation == attempt || ignoreFinishCancellation else { return "" }
        return result
    }

    func cancel() {
        generation = UUID()
        cancelCount += 1
        isRecording = false
    }
}

private enum StubPracticeError: LocalizedError {
    case unavailable
    var errorDescription: String? { "On-device speech recognition is unavailable for this test." }
}

@MainActor @Observable
private final class StubPracticeCoach: PracticeCoaching {
    var usesCloudProcessing = false
    var isAvailable = true
    var availabilityMessage = "On-device coaching is ready."
    var isGenerating = false
    var lastLanguage: String?
    var requestCount = 0
    @ObservationIgnored var handler: (@MainActor () async throws -> Void)?

    func refreshAvailability(language: String?) { lastLanguage = language }

    func feedback(for room: DebateRoom, participantID: String?) async throws -> JudgeFeedback {
        requestCount += 1
        isGenerating = true
        defer { isGenerating = false }
        try await handler?()
        return JudgeFeedback(id: "test-feedback", summary: "Test fixture", strengths: [], improvements: [], evidence: [],
                             limitation: "Test fixture, not generated feedback", sourceParticipantID: "local", sourceTurnID: "test-turn",
                             speakerName: "You", reviewedCharacters: 100, totalCharacters: 100, createdAt: 0)
    }
}
