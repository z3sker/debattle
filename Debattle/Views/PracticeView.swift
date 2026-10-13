import SwiftUI
import Observation
import AVFoundation

@MainActor
protocol PracticeVoiceInput: AnyObject {
    var isMicrophoneEnabled: Bool { get }
    var level: Float { get }
    var errorMessage: String? { get }
    func startMicrophone(onAudio: @escaping @Sendable (Data) -> Void,
                         onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?) async throws
    func stop()
}

@MainActor
protocol PracticeTranscribing: AnyObject, Sendable {
    var usesCloudProcessing: Bool { get }
    var partialText: String { get }
    var isRecording: Bool { get }
    var errorMessage: String? { get }
    func start(language: String) async throws
    nonisolated func append(_ buffer: AVAudioPCMBuffer)
    func finish() async -> String
    func cancel()
}

extension PracticeTranscribing {
    var usesCloudProcessing: Bool { false }
}

extension VoiceService: PracticeVoiceInput {}

@MainActor
protocol PracticeCoaching: AnyObject {
    var usesCloudProcessing: Bool { get }
    var isAvailable: Bool { get }
    var availabilityMessage: String { get }
    var isGenerating: Bool { get }
    func refreshAvailability(language: String?)
    func feedback(for room: DebateRoom, participantID: String?) async throws -> JudgeFeedback
}

extension PracticeCoaching {
    var usesCloudProcessing: Bool { false }
}

@MainActor @Observable
final class PracticeSession {
    enum Phase { case idle, starting, recording, finalizing }

    let voice: any PracticeVoiceInput
    private(set) var transcriber: any PracticeTranscribing
    private(set) var judge: any PracticeCoaching
    private(set) var cloudConnection: CloudPracticeConnection?
    private(set) var speechCapability: SpeechCapability?
    var motion = "This house would introduce a four-day working week."
    var language = "English"
    var duration = 180
    var transcript = ""
    private(set) var deadline: Date?
    private(set) var phase: Phase = .idle
    private(set) var hasCaptureFailure = false
    var message: String?
    var feedback: JudgeFeedback?
    var lastRoom: DebateRoom?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var reviewGeneration = UUID()
    @ObservationIgnored private var reviewTaskID = UUID()
    @ObservationIgnored private var reviewTask: Task<Void, Never>?
    @ObservationIgnored private var finalizationTask: Task<Void, Never>?
    @ObservationIgnored private var microphoneReady = false
    @ObservationIgnored private var transcriptionRequested = false
    @ObservationIgnored private var transcriptionReady = false
    @ObservationIgnored private var cloudConnectionIsCurrent: (@MainActor () -> Bool)?

    var isRecording: Bool { phase == .recording }
    var isStarting: Bool { phase == .starting }
    var isFinalizing: Bool { phase == .finalizing }
    var isCapturing: Bool { phase != .idle }
    var usesCloudProcessing: Bool { transcriber.usesCloudProcessing || judge.usesCloudProcessing }
    var microphoneLevel: Float { isRecording ? voice.level : 0 }
    var transcriptCharacterCount: Int { transcript.trimmingCharacters(in: .whitespacesAndNewlines).count }
    var feedbackRequirement: String {
        if isCapturing { return "Finish your speech before requesting feedback." }
        if judge.isGenerating { return usesCloudProcessing ? "Groq is reviewing your argument…" : "Reviewing your argument on this device…" }
        if transcriptCharacterCount < AppleJudge.minimumTranscriptCharacters {
            return "Add at least \(AppleJudge.minimumTranscriptCharacters) characters for useful feedback (\(transcriptCharacterCount)/\(AppleJudge.minimumTranscriptCharacters)). You can speak or paste your argument."
        }
        return "Your transcript is long enough for feedback."
    }
    var statusText: String {
        switch phase {
        case .idle: hasCaptureFailure
            ? "Speech capture stopped. You can retry or paste your speech below."
            : "Your microphone starts only when you’re ready."
        case .starting: usesCloudProcessing ? "Preparing the microphone. Audio stays in memory until you finish." : "Preparing microphone and on-device transcription…"
        case .recording: usesCloudProcessing ? "Recording in memory. Finish or the timer sends audio to Groq; words appear afterward." : "Listening on this device. Your words appear below."
        case .finalizing: usesCloudProcessing ? "Sending your speech to Groq for transcription…" : "Finishing your transcript…"
        }
    }

    init(voice: (any PracticeVoiceInput)? = nil,
         transcriber: (any PracticeTranscribing)? = nil,
         judge: (any PracticeCoaching)? = nil) {
        self.voice = voice ?? VoiceService()
        self.transcriber = transcriber ?? SpeechTranscriber()
        self.judge = judge ?? AppleJudge()
    }

    func refreshCapabilities() {
        if !hasCaptureFailure { message = nil }
        speechCapability = usesCloudProcessing ? nil : SpeechTranscriber.capability(for: language)
        judge.refreshAvailability(language: language)
    }

    /// Provider changes preserve the editable draft and can only replace idle services.
    @discardableResult
    func configureServices(transcriber: any PracticeTranscribing, judge: any PracticeCoaching,
                           cloudConnectionIsCurrent: (@MainActor () -> Bool)? = nil) -> Bool {
        guard phase == .idle, finalizationTask == nil else { return false }
        cancelReview()
        self.transcriber.cancel()
        self.transcriber = transcriber
        self.judge = judge
        self.cloudConnectionIsCurrent = cloudConnectionIsCurrent
        cloudConnection = nil
        feedback = nil
        lastRoom = nil
        hasCaptureFailure = false
        message = nil
        refreshCapabilities()
        return true
    }

    @discardableResult
    func configureCloud(connection: CloudPracticeConnection, status: CloudPracticeStatus,
                        isConnectionCurrent: @escaping @MainActor () -> Bool) -> Bool {
        guard status.available, isConnectionCurrent() else { return false }
        let api = CloudPracticeAPI(connection: connection)
        guard configureServices(transcriber: CloudPracticeTranscriber(api: api),
                                judge: CloudPracticeCoach(api: api, status: status),
                                cloudConnectionIsCurrent: isConnectionCurrent) else { return false }
        cloudConnection = connection
        duration = min(duration, min(420, max(1, status.maxAudioSeconds)))
        return true
    }

    /// Revoking consent invalidates both in-flight uploads and results before switching back.
    func useOnDevice(message reason: String? = nil) {
        guard usesCloudProcessing else { return }
        abortCloudCapture()
        _ = configureServices(transcriber: SpeechTranscriber(), judge: AppleJudge())
        message = reason
    }

    @discardableResult
    func validateCloudConnection(_ connection: CloudPracticeConnection?) -> Bool {
        guard usesCloudProcessing else { return true }
        guard let cloudConnection, cloudConnection == connection else {
            useOnDevice(message: "The server connection changed. Review Groq consent again before using cloud Practice.")
            return false
        }
        return ensureCloudConsent()
    }

    private func ensureCloudConsent() -> Bool {
        guard usesCloudProcessing, let cloudConnectionIsCurrent else { return true }
        guard cloudConnectionIsCurrent() else {
            useOnDevice(message: "The server connection changed. Review Groq consent again before using cloud Practice.")
            return false
        }
        return true
    }

    func clearFeedbackForInputChange() {
        cancelReview()
        feedback = nil
        if !hasCaptureFailure { message = nil }
    }

    func requestReview() {
        guard reviewTask == nil, !isCapturing, !judge.isGenerating else { return }
        let request = UUID()
        reviewTaskID = request
        reviewTask = Task { @MainActor in
            guard !Task.isCancelled, self.reviewTaskID == request else { return }
            await self.review()
            if self.reviewTaskID == request { self.reviewTask = nil }
        }
    }

    private func cancelReview() {
        reviewGeneration = UUID()
        reviewTaskID = UUID()
        reviewTask?.cancel()
        reviewTask = nil
    }

    func start() async {
        guard phase == .idle, finalizationTask == nil, !judge.isGenerating, ensureCloudConsent() else { return }
        let attempt = UUID()
        generation = attempt
        reviewGeneration = UUID()
        phase = .starting
        microphoneReady = false
        transcriptionRequested = false
        transcriptionReady = false
        message = nil
        hasCaptureFailure = false
        feedback = nil
        observeCapture(generation: attempt)
        do {
            // Acquire microphone permission before starting recognition: a permission alert
            // must not leave an already-running recognizer waiting indefinitely for audio.
            let transcriber = self.transcriber
            try await voice.startMicrophone(onAudio: { _ in }, onBuffer: { buffer in transcriber.append(buffer) })
            guard generation == attempt else { return }
            try Task.checkCancellation()
            guard ensureCloudConsent() else { return }
            guard voice.isMicrophoneEnabled, voice.errorMessage == nil else {
                throw PracticeCaptureError(message: voice.errorMessage ?? "The microphone could not start.")
            }
            microphoneReady = true
            transcriptionRequested = true
            try await transcriber.start(language: language)
            guard generation == attempt else { return }
            try Task.checkCancellation()
            guard ensureCloudConsent() else { return }
            guard voice.isMicrophoneEnabled, voice.errorMessage == nil else {
                throw PracticeCaptureError(message: voice.errorMessage ?? "The microphone stopped while preparing your speech.")
            }
            guard transcriber.isRecording, transcriber.errorMessage == nil else {
                throw PracticeCaptureError(message: transcriber.errorMessage ?? "Speech capture could not start.")
            }
            transcriptionReady = true
            if !usesCloudProcessing { transcript = transcriber.partialText }
            deadline = Date().addingTimeInterval(Double(usesCloudProcessing ? min(duration, 420) : duration))
            phase = .recording
        } catch {
            // An old permission request may finish after a new attempt has started. Only
            // its owner can clean up; stale completions must not stop the new microphone.
            guard generation == attempt else { return }
            // User cancellation already invalidates generation above. A current audio
            // operation can also be cancelled by an interruption: retain its real cause.
            let reason = error is CancellationError ? voice.errorMessage
                : "\(error.localizedDescription) You can edit or paste a speech below to keep practicing."
            if let task = beginFinalization(message: reason) { await task.value }
        }
    }

    func stop() async {
        guard ensureCloudConsent() else { return }
        if let task = beginFinalization(allowCloudUpload: true) { await task.value }
    }

    /// Called synchronously on disappearance/backgrounding to close input immediately,
    /// even if a permission dialog or transcript finalization is still outstanding.
    func endSession() {
        cancelReview()
        if usesCloudProcessing { useOnDevice() }
        else { _ = beginFinalization() }
    }

    private func observeCapture(generation attempt: UUID) {
        guard generation == attempt, phase == .starting || phase == .recording else { return }
        withObservationTracking {
            _ = voice.isMicrophoneEnabled
            _ = voice.errorMessage
            _ = transcriber.partialText
            _ = transcriber.isRecording
            _ = transcriber.errorMessage
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == attempt else { return }
                // Observation's callback fires before mutation. Read on the main actor's
                // next turn and rearm before handling any further service changes.
                self.observeCapture(generation: attempt)
                self.captureDidChange()
            }
        }
    }

    private func captureDidChange() {
        guard phase == .starting || phase == .recording else { return }
        if transcriptionReady, !transcriber.partialText.isEmpty { transcript = transcriber.partialText }
        if microphoneReady, !voice.isMicrophoneEnabled || voice.errorMessage != nil {
            _ = beginFinalization(message: voice.errorMessage ?? "The microphone stopped. Any transcribed words have been kept below.")
        } else if transcriptionReady, !transcriber.isRecording || transcriber.errorMessage != nil {
            // Runtime recognition failure is a session failure, not a healthy 'Listening'
            // state. Keep accumulated words and let the user retry or edit them.
            let cause = transcriber.errorMessage ?? "Speech capture stopped. Try again, or paste a speech to continue."
            _ = beginFinalization(message: "\(cause) Any recognized words have been kept below.")
        }
    }

    private func abortCloudCapture(message reason: String? = nil) {
        generation = UUID()
        cancelReview()
        finalizationTask?.cancel()
        finalizationTask = nil
        voice.stop()
        transcriber.cancel()
        microphoneReady = false
        transcriptionRequested = false
        transcriptionReady = false
        deadline = nil
        phase = .idle
        if let reason { message = reason; hasCaptureFailure = true }
    }

    private func beginFinalization(message reason: String? = nil, allowCloudUpload: Bool = false) -> Task<Void, Never>? {
        // Finishing is an upload for cloud services. Only Finish/the timer may initiate it.
        if transcriber.usesCloudProcessing,
           !allowCloudUpload || reason != nil || phase == .starting {
            abortCloudCapture(message: reason)
            return nil
        }
        if transcriber.usesCloudProcessing, phase == .recording,
           !voice.isMicrophoneEnabled || voice.errorMessage != nil || !transcriber.isRecording || transcriber.errorMessage != nil {
            abortCloudCapture(message: transcriber.errorMessage ?? voice.errorMessage ?? "Speech capture stopped. Unsent audio was discarded.")
            return nil
        }
        if let reason { message = reason; hasCaptureFailure = true }
        if let finalizationTask { return finalizationTask }
        guard phase == .starting || phase == .recording else { return nil }
        generation = UUID()
        let finishingGeneration = generation
        phase = .finalizing
        deadline = nil
        voice.stop()
        microphoneReady = false
        let partial = transcriptionRequested ? transcriber.partialText : ""
        if !partial.isEmpty { transcript = partial }
        let canFinish = transcriptionRequested && (transcriptionReady || transcriber.isRecording || !partial.isEmpty)
        transcriptionReady = false
        transcriptionRequested = false
        if !canFinish { transcriber.cancel() }
        let finishingTranscriber = transcriber
        let task = Task { @MainActor in
            guard self.generation == finishingGeneration, !Task.isCancelled else { return }
            if finishingTranscriber.usesCloudProcessing {
                guard self.ensureCloudConsent() else { return }
                if let error = finishingTranscriber.errorMessage {
                    self.abortCloudCapture(message: error)
                    return
                }
            }
            let finalText = canFinish ? await finishingTranscriber.finish() : ""
            guard self.generation == finishingGeneration, !Task.isCancelled else { return }
            // A recognizer may return no final result after an error. Never erase its last
            // useful partial result (or a pasted speech retained during failed startup).
            if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.transcript = finalText }
            if let error = finishingTranscriber.errorMessage {
                self.message = error
                self.hasCaptureFailure = true
            }
            self.phase = .idle
            self.finalizationTask = nil
        }
        finalizationTask = task
        return task
    }

    func review() async {
        guard !Task.isCancelled, !isCapturing, !judge.isGenerating, ensureCloudConsent() else { return }
        let attempt = UUID()
        reviewGeneration = attempt
        let reviewedText = transcript
        let reviewedMotion = motion
        let reviewedLanguage = language
        message = nil
        hasCaptureFailure = false
        feedback = nil
        refreshCapabilities()
        guard transcriptCharacterCount >= AppleJudge.minimumTranscriptCharacters else {
            message = feedbackRequirement
            return
        }
        guard judge.isAvailable else {
            message = judge.availabilityMessage
            return
        }
        let format = FormatCatalog.duel
        guard let turn = format.turns.first, let team = format.teams.first else { return }
        let room = DebateRoom(id: "practice-\(UUID().uuidString)", title: motion, language: language,
                              format: format, visibility: "private", status: "finished", hostID: "local",
                              participants: [Participant(id: "local", displayName: "You", teamID: team.id, seatIndex: 0)],
                              transcript: [TranscriptSegment(id: UUID().uuidString, participantID: "local", turnID: turn.id, text: transcript, createdAt: Date().timeIntervalSince1970)])
        lastRoom = room
        do {
            let result = try await judge.feedback(for: room, participantID: nil)
            guard reviewGeneration == attempt, !Task.isCancelled, !isCapturing,
                  transcript == reviewedText, motion == reviewedMotion, language == reviewedLanguage else { return }
            feedback = result
        } catch {
            guard reviewGeneration == attempt, !(error is CancellationError), !Task.isCancelled,
                  transcript == reviewedText, motion == reviewedMotion, language == reviewedLanguage else { return }
            message = error.localizedDescription
        }
    }
}

private struct PracticeCaptureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PracticeView: View {
    private struct CloudConsentRequest: Identifiable {
        let id = UUID()
        let serverAddress: String
    }

    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var practice: PracticeSession
    @State private var showSignIn = false
    @State private var cloudConsentRequest: CloudConsentRequest?
    @State private var cloudSetupMessage: String?
    @State private var isSettingUpCloud = false
    @State private var cloudSetupTask: Task<Void, Never>?
    @State private var cloudSetupGeneration = UUID()
    @State private var pendingCloudConnection: CloudPracticeConnection?

    init() { _practice = State(initialValue: PracticeSession()) }

    #if DEBUG
    init(previewSession: PracticeSession) { _practice = State(initialValue: previewSession) }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { Pill(title: "JUST YOU & YOUR IDEAS", icon: "sparkle"); Spacer() }
                Text("Find your voice.\nThen make your case.").font(.system(.largeTitle, design: .rounded).weight(.bold)).tracking(-1)
                Text("A quiet place to try an argument before you take the floor.").font(.subheadline).foregroundStyle(.secondary)
                if store.needsSignIn { SignInPrompt() }
                processingCard
                VStack(alignment: .leading, spacing: 14) {
                    Text("YOUR MOTION").font(.caption.bold()).tracking(1.2).foregroundStyle(.secondary)
                    TextField("What would you like to debate?", text: $practice.motion, axis: .vertical).font(.title3.weight(.semibold)).lineLimit(2...4)
                    Divider()
                    Picker("Language", selection: $practice.language) { ForEach(debateLanguages, id: \.self) { Text($0) } }
                    if let capability = practice.speechCapability {
                        Label(capability.message, systemImage: capability.isAvailable ? "waveform" : "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("practice.speechAvailability")
                    }
                    Picker("Speaking time", selection: $practice.duration) { Text("1 minute").tag(60); Text("3 minutes").tag(180); Text("7 minutes").tag(420) }
                }.cardStyle().disabled(practice.isCapturing)
                PracticeRecordingCard(practice: practice)
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "Your speech", subtitle: practice.isRecording
                                   ? (practice.usesCloudProcessing ? "Your transcript arrives after Finish. Any existing draft stays here until then." : "Live words appear here. You can edit them when you finish.")
                                   : "Record above or paste a transcript to review.")
                    TextEditor(text: $practice.transcript).frame(minHeight: 140).padding(8)
                        .scrollContentBackground(.hidden).background(Design.surface, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(alignment: .topLeading) {
                            if practice.transcript.isEmpty {
                                Text(practice.isRecording ? (practice.usesCloudProcessing ? "Your transcript will appear after Finish…" : "Your words will appear here as you speak…") : "Your argument goes here…")
                                    .foregroundStyle(.tertiary).padding(14).allowsHitTesting(false)
                            }
                        }.disabled(practice.isCapturing)
                        .accessibilityLabel("Your speech transcript")
                        .accessibilityIdentifier("practice.transcript")
                    Text(practice.feedbackRequirement).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("practice.feedbackRequirement")
                    InfoBanner(text: practice.judge.availabilityMessage,
                               icon: practice.judge.isAvailable ? "sparkles" : "info.circle")
                        .accessibilityIdentifier("practice.feedbackAvailability")
                    if !practice.judge.isAvailable, !practice.usesCloudProcessing {
                        DisclosureGroup("Apple Intelligence setup") {
                            Text("Open Settings → Apple Intelligence & Siri. Turn on Apple Intelligence and let its model finish downloading while connected to Wi-Fi and power. Your iPhone and Siri languages must match a supported language. Then return here and check availability. Turning on Apple Intelligence does not change which speech-to-text languages are available.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }.font(.subheadline)
                        Button("Check availability") { practice.refreshCapabilities() }
                            .font(.subheadline).disabled(practice.isCapturing)
                    }
                    if !practice.hasCaptureFailure, let message = practice.message {
                        InfoBanner(text: message, icon: "exclamationmark.bubble")
                            .accessibilityIdentifier("practice.feedbackError")
                    }
                    PrimaryButton(title: practice.usesCloudProcessing ? "Get Groq feedback" : "Get speech feedback", icon: "sparkles", busy: practice.judge.isGenerating) { practice.requestReview() }
                        .disabled(practice.isCapturing)
                        .accessibilityIdentifier("practice.feedback")
                    if let feedback = practice.feedback { FeedbackCard(feedback: feedback) }
                }
                InfoBanner(text: practice.usesCloudProcessing
                           ? "Groq Practice sends audio after Finish or the timer, and sends a transcript excerpt and your motion only when you request feedback. Experimental coaching does not determine a winner or award a competitive rating."
                           : "Apple Practice stays on this device. Experimental Apple Intelligence feedback reviews a limited speech excerpt; it does not determine a winner or award a competitive rating. Availability depends on your device and language.", icon: practice.usesCloudProcessing ? "network" : "lock.shield")
            }.padding(22)
        }.background(Design.background).navigationTitle("Practice studio").navigationBarTitleDisplayMode(.inline)
            .onAppear { practice.language = store.preferredLanguage; practice.refreshCapabilities() }
            .sheet(item: $cloudConsentRequest) { request in cloudConsentSheet(for: request) }
            .sheet(isPresented: $showSignIn) { NavigationStack { AccountSignInView() } }
            .onDisappear { cancelCloudSetup(); practice.endSession() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { cloudConsentRequest = nil; cancelCloudSetup(); practice.endSession() }
                if phase == .active { practice.refreshCapabilities() }
            }
            .onChange(of: store.serverAddress) { _, _ in
                guard cloudConsentRequest != nil || isSettingUpCloud || practice.usesCloudProcessing else { return }
                cloudConsentRequest = nil
                cancelCloudSetup()
                practice.useOnDevice()
                cloudSetupMessage = "The server address changed. Review Groq consent again for the new server."
            }
            .onChange(of: store.cloudPracticeConnection) { _, connection in
                if practice.usesCloudProcessing { _ = practice.validateCloudConnection(connection) }
                if let pendingCloudConnection, pendingCloudConnection != connection {
                    cancelCloudSetup()
                    cloudSetupMessage = "The server connection changed. Review Groq consent again."
                }
            }
            .onChange(of: practice.transcript) { _, _ in practice.clearFeedbackForInputChange() }
            .onChange(of: practice.motion) { _, _ in practice.clearFeedbackForInputChange() }
            .onChange(of: practice.language) { _, _ in practice.clearFeedbackForInputChange(); practice.refreshCapabilities() }
    }

    private var processingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SPEECH & FEEDBACK").font(.caption.bold()).tracking(1.2).foregroundStyle(.secondary)
            processingSelector
                .disabled(practice.isCapturing || practice.judge.isGenerating || isSettingUpCloud)
                .accessibilityIdentifier("practice.processing")
            if isSettingUpCloud {
                ProgressView("Checking Groq on your server…").font(.footnote)
                Button("Cancel") { cancelCloudSetup() }.font(.footnote)
            } else if practice.usesCloudProcessing {
                Text("Groq transcribes finished recordings and reviews your speech over the internet. Per-person and shared usage limits apply.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Revoke Groq consent", role: .destructive) {
                    cancelCloudSetup()
                    practice.useOnDevice(message: "Groq consent revoked. Unsent audio was discarded and pending work was cancelled. Data already sent cannot be recalled.")
                }.font(.footnote)
                    .accessibilityIdentifier("practice.revokeCloudConsent")
                Link("Groq data handling", destination: URL(string: "https://console.groq.com/docs/your-data")!).font(.footnote)
            } else {
                Text("Apple processes speech and feedback on your device where supported. Groq supports cloud transcription and coaching with your permission.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(store.needsSignIn ? "Sign in to use Groq" : "Set up Groq for this session",
                       systemImage: store.needsSignIn ? "person.crop.circle" : "sparkles") {
                    requestCloudSetup()
                }.font(.subheadline.weight(.semibold))
                    .disabled(practice.isCapturing || practice.judge.isGenerating)
                    .accessibilityIdentifier("practice.setupCloud")
            }
            if let cloudSetupMessage {
                InfoBanner(text: cloudSetupMessage, icon: "exclamationmark.bubble")
                    .accessibilityIdentifier("practice.cloudSetupError")
                Button("Open Your corner") { store.selectedTab = 3 }.font(.footnote)
            }
        }.cardStyle()
    }

    @ViewBuilder private var processingSelector: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                processingOption("Apple · on device", useCloud: false)
                processingOption("Groq · cloud", useCloud: true)
            }
        } else {
            Picker("Practice processing", selection: Binding(get: { practice.usesCloudProcessing }, set: { selectProcessing($0) })) {
                Text("Apple · on device").tag(false)
                Text("Groq · cloud").tag(true)
            }.pickerStyle(.segmented)
        }
    }

    private func processingOption(_ title: String, useCloud: Bool) -> some View {
        let selected = practice.usesCloudProcessing == useCloud
        return Button { selectProcessing(useCloud) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
            }.font(.body.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        }.buttonStyle(.plain).foregroundStyle(selected ? Design.accent : Color.primary)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(useCloud ? "practice.processing.groq" : "practice.processing.apple")
    }

    private func selectProcessing(_ useCloud: Bool) {
        if useCloud {
            requestCloudSetup()
        } else {
            cancelCloudSetup()
            practice.useOnDevice()
            cloudSetupMessage = nil
        }
    }

    private func requestCloudSetup() {
        guard !practice.isCapturing, !practice.judge.isGenerating, !isSettingUpCloud else { return }
        if store.needsSignIn {
            showSignIn = true
            return
        }
        cloudConsentRequest = CloudConsentRequest(serverAddress: store.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func cloudConsentSheet(for request: CloudConsentRequest) -> some View {
        NavigationStack {
            Form {
                Section("Use Groq for this Practice session?") {
                    Text("Debattle forwards your requests to Groq through this server:")
                    Text(Self.serverLabel(request.serverAddress)).font(.footnote).textSelection(.enabled)
                    Text("Recording stays in memory until you tap Finish or your selected timer ends, up to 7 minutes. Then your audio is sent for transcription; words appear afterward.")
                    Text("Get Groq feedback sends a transcript excerpt and your debate motion for experimental coaching. Choosing Groq does not send a speech or request feedback by itself.")
                }
                Section("Your choice") {
                    Text("Leaving Practice, backgrounding the app, or revoking consent cancels pending work and discards unsent audio. Data already sent cannot be recalled.")
                    Text("AI usage has per-person and shared limits. Transcription and feedback each use allowance. Internet is required; Groq may temporarily be unavailable when a limit is reached. Debattle will not switch providers automatically.")
                    Text("Debattle does not save Practice audio or text on its server. Groq may retain submitted data under its policy. Avoid sharing sensitive information.")
                    Link("Read Groq’s data handling policy", destination: URL(string: "https://console.groq.com/docs/your-data")!)
                }
                Section {
                    Button("Use Groq for this session") {
                        cloudConsentRequest = nil
                        enableCloudPractice(consentedAddress: request.serverAddress)
                    }
                        .accessibilityIdentifier("practice.acceptCloudConsent")
                    Button("Keep Apple on device", role: .cancel) { cloudConsentRequest = nil }
                }
            }.navigationTitle("Cloud Practice").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cloudConsentRequest = nil } } }
        }
    }

    private static func serverLabel(_ address: String) -> String {
        guard var components = URLComponents(string: address), components.host != nil else { return "Debattle is not connected. Please reconnect from Explore." }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "Your configured Debattle server"
    }

    private func cancelCloudSetup() {
        cloudSetupGeneration = UUID()
        cloudSetupTask?.cancel()
        cloudSetupTask = nil
        pendingCloudConnection = nil
        isSettingUpCloud = false
    }

    private func enableCloudPractice(consentedAddress: String) {
        cancelCloudSetup()
        guard consentedAddress == store.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines) else {
            cloudSetupMessage = "The server address changed. Review Groq consent again."
            return
        }
        let attempt = UUID()
        cloudSetupGeneration = attempt
        isSettingUpCloud = true
        cloudSetupMessage = nil
        cloudSetupTask = Task { @MainActor in
            defer {
                if cloudSetupGeneration == attempt {
                    isSettingUpCloud = false
                    pendingCloudConnection = nil
                    cloudSetupTask = nil
                }
            }
            if store.cloudPracticeConnection == nil { await store.connect() }
            guard cloudSetupGeneration == attempt, !Task.isCancelled else { return }
            guard consentedAddress == store.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                  let connection = store.cloudPracticeConnection else {
                cloudSetupMessage = "Groq was not enabled. Sign in from Your corner, then try again. \(store.connectionMessage ?? "")"
                return
            }
            pendingCloudConnection = connection
            do {
                let status = try await CloudPracticeAPI(connection: connection).status()
                guard cloudSetupGeneration == attempt, !Task.isCancelled else { return }
                guard store.cloudPracticeConnection == connection else {
                    cloudSetupMessage = "The server connection changed. Review Groq consent again."
                    return
                }
                guard status.available else {
                    cloudSetupMessage = "Groq was not enabled. \(status.message) The server owner may need to configure Groq."
                    return
                }
                guard practice.configureCloud(connection: connection, status: status, isConnectionCurrent: { [weak connectedStore = store] in
                    connectedStore?.cloudPracticeConnection == connection
                }) else {
                    cloudSetupMessage = "Groq could not be enabled while Practice was busy. Finish your current activity, then review consent again."
                    return
                }
            } catch {
                guard cloudSetupGeneration == attempt, !Task.isCancelled else { return }
                cloudSetupMessage = "Groq was not enabled. \(error.localizedDescription) Please check your internet connection and try again."
            }
        }
    }
}

private struct PracticeRecordingCard: View {
    let practice: PracticeSession

    var body: some View {
        VStack(spacing: 18) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = practice.deadline.map { max(0, Int(ceil($0.timeIntervalSince(context.date)))) } ?? practice.duration
                Text(DebateRules.clockText(remaining)).font(.system(size: 62, weight: .medium, design: .rounded)).monospacedDigit().tracking(-2)
                    .onChange(of: remaining) { _, value in if value == 0, practice.isRecording { Task { await practice.stop() } } }
            }
            PracticeLevelMeter(level: practice.microphoneLevel, isRecording: practice.isRecording)
            if practice.hasCaptureFailure, let message = practice.message {
                InfoBanner(text: message, icon: "exclamationmark.bubble")
                    .accessibilityIdentifier("practice.captureFailure")
            }
            PrimaryButton(title: practice.isFinalizing ? (practice.usesCloudProcessing ? "Transcribing with Groq…" : "Finishing transcript…") : practice.isStarting ? "Preparing…" : practice.isRecording ? (practice.usesCloudProcessing ? "Finish & send to Groq" : "Finish speech") : "Start speaking",
                          icon: practice.isRecording ? "stop.fill" : "mic.fill", busy: practice.isStarting || practice.isFinalizing) {
                Task { if practice.isRecording { await practice.stop() } else { await practice.start() } }
            }.disabled(practice.motion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || practice.judge.isGenerating)
                .accessibilityIdentifier("practice.record")
            if practice.isStarting {
                Button("Cancel preparation") { practice.endSession() }.font(.subheadline)
            } else if practice.usesCloudProcessing, practice.isCapturing {
                Button(practice.isFinalizing ? "Cancel pending transcription" : "Discard recording", role: .destructive) { practice.endSession() }.font(.subheadline)
            }
            Text(practice.statusText).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.cardStyle()
    }
}

private struct PracticeLevelMeter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let level: Float
    let isRecording: Bool

    private var intensity: CGFloat {
        // The input is measured microphone energy. This gain curve makes quiet speech
        // visible; zero input stays flat. No random or repeating animation simulates speech.
        guard isRecording, level.isFinite else { return 0 }
        return CGFloat(sqrt(min(1, max(0, level))))
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<19, id: \.self) { index in
                let shape = 0.4 + 0.6 * (1 - abs(Double(index - 9)) / 9)
                Capsule().fill(Design.accent.opacity(isRecording ? 0.85 : 0.25))
                    .frame(width: 5, height: 3 + 38 * intensity * CGFloat(shape))
            }
        }
        .frame(height: 45)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: intensity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone input level")
        .accessibilityValue(isRecording ? (level > 0.01 ? "Sound detected" : "Quiet") : "Microphone off")
    }
}

struct FeedbackCard: View {
    let feedback: JudgeFeedback
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Pill(title: "EXPERIMENTAL FEEDBACK", icon: "sparkles")
            Text(feedback.summary).font(.headline)
            if !feedback.strengths.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keep doing this").font(.subheadline.bold()).foregroundStyle(Design.green)
                    ForEach(feedback.strengths, id: \.self) { Text("• \($0)").font(.subheadline) }
                }
            }
            if !feedback.improvements.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Try this next").font(.subheadline.bold()).foregroundStyle(Design.accent)
                    ForEach(feedback.improvements, id: \.self) { Text("• \($0)").font(.subheadline) }
                }
            }
            ForEach(feedback.evidence) { evidence in
                VStack(alignment: .leading, spacing: 8) {
                    Text("“\(evidence.quote)”").font(.subheadline.italic())
                    Text(evidence.explanation).font(.footnote).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Design.purple.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            }
            Text(feedback.limitation).font(.caption).foregroundStyle(.secondary)
        }.cardStyle()
    }
}
