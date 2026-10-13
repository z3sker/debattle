import Foundation
import Observation

@MainActor @Observable
final class AppStore {
    var rooms: [DebateRoom] = []
    var activeRoom: DebateRoom?
    var session: GuestSession? {
        didSet { if oldValue?.token != session?.token { cancelCloudRoomWork() } }
    }
    var isLoading = false
    var isWorking = false
    var connectionMessage: String?
    var alertMessage: String?
    var pendingInvite: String?
    var selectedTab = 0
    var displayName: String { didSet { UserDefaults.standard.set(displayName, forKey: "displayName") } }
    var preferredLanguage: String { didSet { UserDefaults.standard.set(preferredLanguage, forKey: "preferredLanguage") } }
    var serverAddress: String {
        didSet {
            UserDefaults.standard.set(serverAddress, forKey: "serverAddress")
            if oldValue != serverAddress { cancelCloudRoomWork() }
        }
    }
    var completedDebates: [DebateRoom] = []
    var recoveredTranscripts: [RecoveredTranscript] = []
    var recoveryMessage: String?
    var streamConnected = false
    var isTranscribing = false
    var transcriptionMessage: String?
    var hasConsented = false
    var isTransitioningAccount = false
    @ObservationIgnored var pendingAppleCredentialRevocation = false
    var serverConfiguration: ServerConfiguration?
    var needsSignIn: Bool { serverConfiguration?.authenticationRequired == true && session?.authProvider != "apple" }
    private(set) var isCloudRecording = false
    private(set) var cloudUploadsInProgress = 0
    private(set) var isChangingCloudConsent = false
    private var roomCloudConsentSuppressed = false
    let voice = VoiceService()
    let transcriber = SpeechTranscriber()
    let judge = AppleJudge()
    @ObservationIgnored var api: RoomAPI?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var cloudCapture: (ticket: CloudRoomCapture, audio: CloudRoomAudioBuffer, api: CloudRoomAPI)?
    @ObservationIgnored private var cloudUploadTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var cloudWorkGeneration = UUID()
    @ObservationIgnored private var speechTurnID: String?
    @ObservationIgnored private var finishSpeechTask: Task<Void, Never>?
    @ObservationIgnored private var finishingSpeech: (room: DebateRoom, turnID: String, participantID: String)?
    @ObservationIgnored private var audioWatchTask: Task<Void, Never>?
    @ObservationIgnored var connectionGeneration = UUID()
    @ObservationIgnored private(set) var roomGeneration = UUID()
    @ObservationIgnored private var streamGeneration = UUID()
    @ObservationIgnored private var microphoneGeneration = UUID()
    @ObservationIgnored private var isStartingMicrophone = false
    @ObservationIgnored private var isLeavingRoom = false
    @ObservationIgnored private var isResettingConnection = false
    @ObservationIgnored private var audioPacketsInFlight = 0
    @ObservationIgnored private let historyWriter: ([DebateRoom]) throws -> Void
    @ObservationIgnored private let recoveryArchive: TranscriptRecoveryArchive
    @ObservationIgnored let apiFactory: @MainActor (URL) -> RoomAPI

    init(historyLoader: () -> [DebateRoom] = { LocalDebateArchive.load() },
         historyWriter: @escaping ([DebateRoom]) throws -> Void = { try LocalDebateArchive.save($0) },
         recoveryArchive: TranscriptRecoveryArchive = TranscriptRecoveryArchive(),
         apiFactory: @escaping @MainActor (URL) -> RoomAPI = { RoomAPI(baseURL: $0) }) {
        self.historyWriter = historyWriter
        self.recoveryArchive = recoveryArchive
        self.apiFactory = apiFactory
        displayName = UserDefaults.standard.string(forKey: "displayName") ?? ""
        preferredLanguage = UserDefaults.standard.string(forKey: "preferredLanguage") ?? "English"
        #if DEBUG
        serverAddress = UserDefaults.standard.string(forKey: "serverAddress") ?? "http://localhost:8787"
        #else
        // The public app has one configured service; beta LAN settings never migrate into it.
        serverAddress = "https://debattle.mans.team"
        #endif
        completedDebates = historyLoader()
        do { recoveredTranscripts = try recoveryArchive.load() }
        catch { recoveryMessage = error.localizedDescription }
    }

    var participantID: String { session?.participantID ?? "" }
    /// Only hand Practice a verified identity for the currently selected endpoint.
    /// Editing the address immediately invalidates this handoff, before reconnecting.
    var cloudPracticeConnection: CloudPracticeConnection? {
        guard !isTransitioningAccount, !pendingAppleCredentialRevocation, let api, let session, api.token == session.token,
              let selected = URL(string: serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)),
              selected == api.baseURL else { return nil }
        return CloudPracticeConnection(baseURL: api.baseURL, token: session.token)
    }
    var hasRoomCloudConsent: Bool {
        !roomCloudConsentSuppressed && activeRoom?.cloudConsentParticipantIDs.contains(participantID) == true
    }

    func setRoomCloudConsent(_ enabled: Bool) async {
        guard let room = activeRoom, let connection = cloudPracticeConnection, !isChangingCloudConsent else { return }
        let generation = roomGeneration
        isChangingCloudConsent = true
        defer { isChangingCloudConsent = false }
        if !enabled { roomCloudConsentSuppressed = true; cancelCloudRoomWork(); await stopSpeaking() }
        do {
            let response = try await CloudRoomAPI(connection: connection).setConsent(roomID: room.id, enabled: enabled)
            guard matchesRoom(room.id, generation: generation), !Task.isCancelled else { return }
            roomCloudConsentSuppressed = !enabled
            await update(response, generation: generation)
            transcriptionMessage = enabled ? "Groq is enabled for your speeches in this room. Transcripts appear after you mute or your turn ends." : "Cloud AI is off for this room. Unsent recordings were discarded."
        } catch {
            if matchesRoom(room.id, generation: generation) { alertMessage = error.localizedDescription }
        }
    }

    /// A lifecycle interruption never implicitly sends newly captured cloud audio.
    func suspendRoomAudio() async {
        cancelCloudRoomWork()
        await stopSpeaking()
    }

    func cancelCloudRoomWork() {
        cloudWorkGeneration = UUID()
        if let capture = cloudCapture, let roomID = activeRoom?.id {
            capture.audio.cancel()
            Task { await capture.api.cancelCapture(roomID: roomID, captureID: capture.ticket.captureID) }
        }
        cloudCapture = nil
        isCloudRecording = false
        for task in cloudUploadTasks.values { task.cancel() }
        cloudUploadTasks.removeAll()
        cloudUploadsInProgress = 0
    }

    var me: Participant? { activeRoom?.participants.first { $0.id == participantID } }
    var amHost: Bool { activeRoom?.hostID == participantID }
    var canSpeak: Bool {
        guard let room = activeRoom else { return false }
        return DebateRules.canSpeak(participantID: participantID, in: room)
    }

    func connect() async {
        guard !isLoading, activeRoom == nil else { return }
        let generation = UUID()
        connectionGeneration = generation
        let address = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = true
        defer { if connectionGeneration == generation { isLoading = false } }
        connectionMessage = nil
        api = nil
        session = nil
        rooms = []
        serverConfiguration = nil
        do {
            guard let url = URL(string: address),
                  ["http", "https"].contains(url.scheme ?? ""), url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw APIError(message: "The Debattle server address is invalid.")
            }
            let client = apiFactory(url)
            // Server mode is explicit: a broken production login must never fall back to guests.
            let configuration: ServerConfiguration = try await client.request("v1/config")
            guard connectionGeneration == generation, !Task.isCancelled else { return }
            serverConfiguration = configuration
            var candidate = SecureSessionStore.read(server: address)
            if candidate?.isExpired == true || (configuration.authenticationRequired && candidate?.authProvider != "apple") {
                SecureSessionStore.remove(server: address)
                candidate = nil
            }
            if let candidate { client.token = candidate.token }
            if candidate == nil, !configuration.authenticationRequired {
                let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (2...30).contains(name.count) else { throw APIError(message: "Choose a display name between 2 and 30 characters.") }
                let guest: GuestSession = try await client.request("v1/sessions", method: "POST", body: ["displayName": name])
                guard connectionGeneration == generation, !Task.isCancelled else { return }
                candidate = guest
                client.token = guest.token
                SecureSessionStore.write(guest, server: address)
            }
            let response: RoomAPI.RoomsResponse
            do {
                response = try await client.request("v1/rooms")
            } catch {
                guard connectionGeneration == generation, !Task.isCancelled else { return }
                guard (error as? APIError)?.statusCode == 401, candidate != nil else { throw error }
                SecureSessionStore.remove(server: address)
                client.token = nil
                candidate = nil
                if !configuration.authenticationRequired {
                    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let recovered: GuestSession = try await client.request("v1/sessions", method: "POST", body: ["displayName": name])
                    guard connectionGeneration == generation, !Task.isCancelled else { return }
                    candidate = recovered
                    client.token = recovered.token
                    SecureSessionStore.write(recovered, server: address)
                }
                response = try await client.request("v1/rooms")
            }
            guard connectionGeneration == generation, !Task.isCancelled else { return }
            api = client
            session = candidate
            if let candidate, candidate.authProvider == "apple" { displayName = candidate.displayName }
            rooms = response.rooms
        } catch { if connectionGeneration == generation { connectionMessage = friendlyNetworkError(error) } }
    }

    func refreshRooms() async {
        guard let api else { await connect(); return }
        let generation = connectionGeneration
        do {
            let response: RoomAPI.RoomsResponse = try await api.request("v1/rooms")
            guard connectionGeneration == generation, self.api === api, !Task.isCancelled else { return }
            rooms = response.rooms
            connectionMessage = nil
        } catch { if connectionGeneration == generation { connectionMessage = friendlyNetworkError(error) } }
    }

    func createRoom(title: String, language: String, format: DebateFormat, visibility: String) async -> Bool {
        guard !isWorking else { return false }
        guard activeRoom == nil, !isLeavingRoom, !isResettingConnection else {
            alertMessage = "Leave your current room before creating another one."
            return false
        }
        let generation = roomGeneration
        let connection = connectionGeneration
        isWorking = true; defer { isWorking = false }
        do {
            let api = try requireAPI()
            let formatJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(format))
            let response: RoomAPI.RoomResponse = try await api.request("v1/rooms", method: "POST", body: ["title": title, "language": language, "format": formatJSON, "visibility": visibility, "transcriptionConsent": true])
            guard roomGeneration == generation, connectionGeneration == connection, !Task.isCancelled else {
                await discardMembership(response.room.id, using: api)
                return false
            }
            await enter(response.room)
            await refreshRooms()
            return true
        } catch {
            if roomGeneration == generation, connectionGeneration == connection { alertMessage = friendlyNetworkError(error) }
            return false
        }
    }

    func join(roomID: String? = nil, inviteCode: String? = nil) async -> Bool {
        guard !isWorking else { return false }
        guard activeRoom == nil, !isLeavingRoom, !isResettingConnection else {
            alertMessage = "Leave your current room before joining another one."
            return false
        }
        let generation = roomGeneration
        let connection = connectionGeneration
        isWorking = true; defer { isWorking = false }
        do {
            let api = try requireAPI()
            var body: [String: Any] = ["transcriptionConsent": true]
            if let roomID { body["roomID"] = roomID }
            if let inviteCode { body["inviteCode"] = inviteCode.uppercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            let response: RoomAPI.RoomResponse = try await api.request("v1/rooms/join", method: "POST", body: body)
            guard roomGeneration == generation, connectionGeneration == connection, !Task.isCancelled else {
                await discardMembership(response.room.id, using: api)
                return false
            }
            await enter(response.room)
            return true
        } catch {
            if roomGeneration == generation, connectionGeneration == connection { alertMessage = friendlyNetworkError(error) }
            return false
        }
    }

    func action(_ name: String, values: [String: Any] = [:]) async {
        guard let room = activeRoom, !isWorking else { return }
        let generation = roomGeneration
        isWorking = true; defer { isWorking = false }
        do {
            let api = try requireAPI()
            // Finalize the host's own speech before advancing or yielding the floor.
            if ["next", "pause", "acceptPOI", "endPOI"].contains(name) { await stopSpeaking() }
            guard matchesRoom(room.id, generation: generation), !Task.isCancelled else { return }
            var body = values; body["action"] = name
            let response: RoomAPI.RoomResponse = try await api.request("v1/rooms/\(room.id)/actions", method: "POST", body: body)
            guard matchesRoom(room.id, generation: generation), !Task.isCancelled else { return }
            await update(response.room, generation: generation)
        } catch { if matchesRoom(room.id, generation: generation) { alertMessage = friendlyNetworkError(error) } }
    }

    func leaveRoom() async {
        guard !isLeavingRoom else { return }
        isLeavingRoom = true
        defer { isLeavingRoom = false }
        guard let room = activeRoom else {
            roomGeneration = UUID() // Also cancels a pending create/join response.
            microphoneGeneration = UUID()
            return
        }
        cancelCloudRoomWork()
        let client = api
        let leavingParticipantID = participantID
        preserveMemberHistory(room, participantID: leavingParticipantID)
        // Capture finalization while the original room is still known, then invalidate all
        // inbound work immediately. The old HTTP response cannot restore this membership.
        let finishing = beginFinishingSpeech()
        roomGeneration = UUID()
        disconnectStream()
        voice.stop()
        activeRoom = nil
        await finishing.value
        do {
            if let client {
                // Membership still exists until the leave action. This final read includes
                // uploads received while local finalization was in progress. The leave
                // response itself is redacted and must never replace the journal snapshot.
                if let response: RoomAPI.RoomResponse = try? await client.request("v1/rooms/\(room.id)") {
                    preserveMemberHistory(response.room, participantID: leavingParticipantID)
                }
                let _: RoomAPI.RoomResponse = try await client.request("v1/rooms/\(room.id)/actions", method: "POST", body: ["action": "leave"])
            }
        } catch {
            // A dropped connection must not prevent stopping the microphone and leaving the screen.
            connectionMessage = "Your microphone and room connection are closed. If the server did not receive your departure, its reconnect grace will release your seat."
        }
        await refreshRooms()
    }

    func toggleMicrophone() async {
        if voice.isMicrophoneEnabled || isStartingMicrophone { await stopSpeaking(); return }
        guard finishSpeechTask == nil, !isWorking, canSpeak, streamConnected,
              let room = activeRoom, let turn = room.currentTurn, let api else {
            alertMessage = "Your microphone opens on your turn, or when your point of information is accepted."
            return
        }
        let generation = roomGeneration
        let stream = streamGeneration
        let microphone = UUID()
        microphoneGeneration = microphone
        isStartingMicrophone = true
        defer { if microphoneGeneration == microphone { isStartingMicrophone = false } }
        do {
            let response: RoomAPI.RoomResponse = try await api.request("v1/rooms/\(room.id)/actions", method: "POST", body: ["action": "setMuted", "isMuted": false])
            guard microphoneIsCurrent(microphone, roomID: room.id, room: generation, stream: stream, turnID: turn.id) else { throw CancellationError() }
            await update(response.room, generation: generation)
            guard microphoneIsCurrent(microphone, roomID: room.id, room: generation, stream: stream, turnID: turn.id), me?.isMuted == false else { throw CancellationError() }
            speechTurnID = turn.id
            var cloudAudio: CloudRoomAudioBuffer?
            if hasRoomCloudConsent, let connection = cloudPracticeConnection {
                do {
                    guard cloudUploadTasks.count < 2 else { throw CloudRoomError.quota }
                    let cloudAPI = CloudRoomAPI(connection: connection)
                    let ticket = try await cloudAPI.startCapture(roomID: room.id, turnID: turn.id)
                    guard microphoneIsCurrent(microphone, roomID: room.id, room: generation, stream: stream, turnID: turn.id), hasRoomCloudConsent else {
                        Task { await cloudAPI.cancelCapture(roomID: room.id, captureID: ticket.captureID) }
                        throw CancellationError()
                    }
                    let buffer = CloudRoomAudioBuffer(maximumSeconds: ticket.maxAudioSeconds)
                    cloudCapture = (ticket, buffer, cloudAPI)
                    cloudAudio = buffer
                    isCloudRecording = true
                    isTranscribing = false
                    transcriptionMessage = "Recording your speech for Groq. It will be sent when you mute or this speaking segment ends."
                } catch {
                    guard microphoneIsCurrent(microphone, roomID: room.id, room: generation, stream: stream, turnID: turn.id) else { throw CancellationError() }
                    isTranscribing = false
                    transcriptionMessage = "Voice is available. \(error.localizedDescription)"
                }
            } else {
                do {
                    try await transcriber.start(language: room.language)
                    guard microphoneIsCurrent(microphone, roomID: room.id, room: generation, stream: stream, turnID: turn.id) else { throw CancellationError() }
                    isTranscribing = true
                    transcriptionMessage = nil
                } catch {
                    guard microphoneIsCurrent(microphone, roomID: room.id, room: generation, stream: stream, turnID: turn.id) else { throw CancellationError() }
                    isTranscribing = false
                    transcriptionMessage = "Voice is available. On-device transcription: \(error.localizedDescription)"
                }
            }
            let transcriber = self.transcriber
            let captureBuffer = cloudAudio
            let usesOnDeviceTranscription = isTranscribing
            try await voice.startMicrophone(onAudio: { [weak self] data in
                Task { @MainActor in
                    guard let self, self.microphoneIsCurrent(microphone, roomID: room.id, room: generation, stream: stream, turnID: turn.id),
                          self.voice.isMicrophoneEnabled, self.me?.isMuted == false,
                          self.audioPacketsInFlight < 8, let socket = self.socket else { return }
                    self.audioPacketsInFlight += 1
                    socket.send(.data(data)) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.streamGeneration == stream else { return }
                            self.audioPacketsInFlight = max(0, self.audioPacketsInFlight - 1)
                        }
                    }
                }
            }, onBuffer: { buffer in
                if let captureBuffer { captureBuffer.append(buffer) }
                else if usesOnDeviceTranscription { transcriber.append(buffer) }
            })
            guard microphoneIsCurrent(microphone, roomID: room.id, room: generation, stream: stream, turnID: turn.id) else {
                if microphoneGeneration == microphone { await stopSpeaking() }
                return
            }
        } catch {
            guard microphoneGeneration == microphone else { return }
            await stopSpeaking()
            if matchesRoom(room.id, generation: generation), !(error is CancellationError) { alertMessage = error.localizedDescription }
        }
    }

    func stopSpeaking() async {
        await beginFinishingSpeech().value
    }

    private func beginFinishingSpeech() -> Task<Void, Never> {
        microphoneGeneration = UUID()
        let wasSpeaking = voice.isMicrophoneEnabled || isTranscribing || isCloudRecording || isStartingMicrophone || speechTurnID != nil
        isStartingMicrophone = false
        if let finishSpeechTask { return finishSpeechTask }
        // Capture every value before suspension: this speech always belongs to this room.
        let speechRoom = activeRoom
        let roomID = speechRoom?.id
        let generation = roomGeneration
        let client = api
        let speakingParticipantID = participantID
        let turnID = speechTurnID
        let shouldFinishTranscript = isTranscribing
        let cloudSpeech = cloudCapture
        let capturedWorkGeneration = cloudWorkGeneration
        cloudCapture = nil
        isCloudRecording = false
        if shouldFinishTranscript, let speechRoom, let turnID {
            finishingSpeech = (speechRoom, turnID, speakingParticipantID)
        }
        speechTurnID = nil
        isTranscribing = false
        if !shouldFinishTranscript { transcriber.cancel() } // Invalidates pending authorization.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishSpeechTask = nil; self.finishingSpeech = nil }
            try? await self.voice.setMicrophoneEnabled(false)
            if let cloudSpeech, let speechRoom, self.cloudWorkGeneration == capturedWorkGeneration, self.matchesRoom(speechRoom.id, generation: generation), self.hasRoomCloudConsent {
                self.uploadCloudSpeech(cloudSpeech, room: speechRoom, generation: generation, participantID: speakingParticipantID)
            } else if let cloudSpeech, let speechRoom {
                cloudSpeech.audio.cancel()
                Task { await cloudSpeech.api.cancelCapture(roomID: speechRoom.id, captureID: cloudSpeech.ticket.captureID) }
            }
            let text = shouldFinishTranscript ? await self.transcriber.finish() : ""
            if let speechRoom, let turnID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await self.submitTranscript(text, for: speechRoom, turnID: turnID, participantID: speakingParticipantID,
                                            generation: generation) { chunk in
                    guard let client else { throw APIError(message: "The room connection is no longer available.") }
                    let response: RoomAPI.RoomResponse = try await client.request("v1/rooms/\(speechRoom.id)/transcript", method: "POST", body: ["turnID": turnID, "text": chunk])
                    return response.room
                }
            }
            if wasSpeaking, !Task.isCancelled, let roomID, let client {
                if let response: RoomAPI.RoomResponse = try? await client.request("v1/rooms/\(roomID)/actions", method: "POST", body: ["action": "setMuted", "isMuted": true]) {
                    self.applyFinalizedSnapshot(response.room, generation: generation, participantID: speakingParticipantID)
                }
            }
        }
        finishSpeechTask = task
        return task
    }

    private func uploadCloudSpeech(_ capture: (ticket: CloudRoomCapture, audio: CloudRoomAudioBuffer, api: CloudRoomAPI),
                                   room: DebateRoom, generation: UUID, participantID: String) {
        let work = cloudWorkGeneration
        let uploadID = UUID()
        do {
            let wav = try capture.audio.finish()
            cloudUploadsInProgress += 1
            transcriptionMessage = "Transcribing your finished speech with Groq… Your microphone is free for the next turn."
            cloudUploadTasks[uploadID] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.cloudUploadTasks.removeValue(forKey: uploadID)
                    self.cloudUploadsInProgress = self.cloudUploadTasks.count
                }
                do {
                    try Task.checkCancellation()
                    guard self.cloudWorkGeneration == work, self.matchesRoom(room.id, generation: generation), self.hasRoomCloudConsent else { return }
                    let updated = try await capture.api.transcribe(roomID: room.id, capture: capture.ticket, wav: wav)
                    guard self.cloudWorkGeneration == work, !Task.isCancelled,
                          self.matchesRoom(room.id, generation: generation), self.hasRoomCloudConsent else { return }
                    self.applyFinalizedSnapshot(updated, generation: generation, participantID: participantID)
                    self.transcriptionMessage = "Your speech transcript is ready in Room transcript."
                } catch {
                    if self.cloudWorkGeneration == work, !Task.isCancelled, self.matchesRoom(room.id, generation: generation) {
                        self.transcriptionMessage = "Speech transcription could not finish. \(error.localizedDescription) The recording was discarded; voice debate is still available."
                    }
                }
            }
        } catch {
            Task { await capture.api.cancelCapture(roomID: room.id, captureID: capture.ticket.captureID) }
            transcriptionMessage = error.localizedDescription
        }
    }

    /// Preserve the entire captured speech before the first network request. Only all
    /// successful acknowledgements remove this safety copy; uncertain requests are not retried.
    func submitTranscript(_ text: String, for room: DebateRoom, turnID: String, participantID: String,
                          generation: UUID, upload: (String) async throws -> DebateRoom) async {
        let recovery = RecoveredTranscript(id: UUID().uuidString, roomID: room.id, roomTitle: room.title,
            turnID: turnID, turnLabel: room.format.turns.first { $0.id == turnID }?.label ?? "Speech",
            language: room.language, participantID: participantID,
            speakerName: (room.participants + room.debateParticipants).first { $0.id == participantID }?.displayName ?? "Speaker",
            text: text, createdAt: Date().timeIntervalSince1970)
        var safelyPreserved = false
        do {
            recoveredTranscripts = try recoveryArchive.preserve(recovery)
            safelyPreserved = true
            recoveryMessage = nil
        } catch {
            recoveryMessage = "A local backup could not be saved. \(error.localizedDescription)"
            transcriptionMessage = recoveryMessage
        }
        do {
            for chunk in try TranscriptTransport.chunks(text) {
                try Task.checkCancellation()
                let response = try await upload(chunk)
                applyFinalizedSnapshot(response, generation: generation, participantID: participantID)
            }
            if safelyPreserved {
                do { recoveredTranscripts = try recoveryArchive.remove(id: recovery.id) }
                catch { recoveryMessage = "The upload was confirmed, but its local recovery copy could not be removed. \(error.localizedDescription)" }
            }
        } catch {
            let message = safelyPreserved
                ? "Your speech upload was not fully confirmed. A full local copy is available in You → Recovered speeches. Some text may already be in the room transcript."
                : "Your speech upload was not confirmed, and its local backup could not be saved. \(recoveryMessage ?? "")"
            recoveryMessage = message
            if matchesRoom(room.id, generation: generation) { transcriptionMessage = message }
            else { alertMessage = message }
        }
    }

    @discardableResult
    func deleteRecoveredTranscript(id: String) -> Bool {
        do {
            recoveredTranscripts = try recoveryArchive.remove(id: id)
            recoveryMessage = nil
            return true
        } catch {
            recoveryMessage = error.localizedDescription
            return false
        }
    }

    func report(reason: String, participant: String? = nil) async -> Bool {
        guard let room = activeRoom else { return false }
        let generation = roomGeneration
        do {
            var body: [String: Any] = ["roomID": room.id, "reason": reason]
            if let participant { body["participantID"] = participant }
            let _: RoomAPI.Acknowledgement = try await requireAPI().request("v1/reports", method: "POST", body: body)
            return true
        } catch {
            if matchesRoom(room.id, generation: generation) { alertMessage = error.localizedDescription }
            return false
        }
    }

    func block(_ participantID: String) async {
        let roomID = activeRoom?.id
        let generation = roomGeneration
        do {
            let _: RoomAPI.Acknowledgement = try await requireAPI().request("v1/blocks", method: "POST", body: ["participantID": participantID])
            if let roomID, matchesRoom(roomID, generation: generation) { await leaveRoom() }
        } catch { if roomGeneration == generation { alertMessage = error.localizedDescription } }
    }

    func resetConnection() async {
        guard !isResettingConnection else { return }
        isResettingConnection = true
        defer { isResettingConnection = false }
        await leaveRoom()
        connectionGeneration = UUID()
        isLoading = false
        api = nil; session = nil; rooms = []
        await connect()
    }

    func saveHistory(_ room: DebateRoom) {
        guard room.status == "finished" else { return }
        if let previous = completedDebates.first(where: { $0.id == room.id }) {
            guard previous != room, room.revision >= previous.revision else { return }
            // Legacy servers have no revision counter. Equal-revision snapshots must not
            // remove already archived fragments, including a late upload after departure.
            if room.revision == previous.revision {
                let incoming = Set(room.transcript)
                guard previous.transcript.allSatisfy({ incoming.contains($0) }) else { return }
            }
        }
        completedDebates.removeAll { $0.id == room.id }
        completedDebates.insert(room, at: 0)
        completedDebates = Array(completedDebates.prefix(20))
        do { try historyWriter(completedDebates) }
        catch { transcriptionMessage = "The round is available now, but it could not be saved to this device: \(error.localizedDescription)" }
    }

    /// Upload completion can outlive room UI membership. Keep the finished member record
    /// without reopening its screen or replacing a newer room's state.
    func applyFinalizedSnapshot(_ room: DebateRoom, generation: UUID, participantID: String) {
        guard room.participants.contains(where: { $0.id == participantID }) else { return }
        applySnapshot(room, generation: generation)
        preserveMemberHistory(room, participantID: participantID)
    }

    private func preserveMemberHistory(_ room: DebateRoom, participantID: String) {
        guard room.participants.contains(where: { $0.id == participantID }) else { return }
        saveHistory(room)
    }

    private func requireAPI() throws -> RoomAPI {
        guard let api else { throw APIError(message: "Connect to the Debattle server first. You can still explore formats and use Practice.") }
        return api
    }

    private func enter(_ room: DebateRoom) async {
        guard activeRoom == nil, !isLeavingRoom else { return }
        cancelCloudRoomWork()
        disconnectStream()
        voice.stop()
        transcriber.cancel()
        roomGeneration = UUID()
        let generation = roomGeneration
        activeRoom = room
        roomCloudConsentSuppressed = false
        selectedTab = 0
        connectStream(roomID: room.id, generation: generation)
        startAudioWatch(roomID: room.id, generation: generation)
        do {
            try await voice.startReceiving()
        } catch {
            if matchesRoom(room.id, generation: generation) { transcriptionMessage = "Audio could not start: \(error.localizedDescription)" }
        }
    }

    private func connectStream(roomID: String, generation: UUID) {
        guard let api, matchesRoom(roomID, generation: generation) else { return }
        streamTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        streamConnected = false
        audioPacketsInFlight = 0
        streamGeneration = UUID()
        let stream = streamGeneration
        let task = api.stream(roomID: roomID)
        socket = task
        task.resume()
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard !Task.isCancelled, self.matchesRoom(roomID, generation: generation), self.streamGeneration == stream else { return }
                    self.streamConnected = true
                    switch message {
                    case .data(let data): self.voice.receiveAudio(data)
                    case .string(let value):
                        guard let data = value.data(using: .utf8) else { continue }
                        if let event = try? JSONDecoder().decode(RoomEvent.self, from: data), event.type == "room", let room = event.room { await self.update(room, generation: generation) }
                        else if let event = try? JSONDecoder().decode(RoomEvent.self, from: data), event.type == "error" { self.alertMessage = event.message }
                    @unknown default: break
                    }
                }
            } catch {
                guard !Task.isCancelled, self.matchesRoom(roomID, generation: generation), self.streamGeneration == stream else { return }
                self.streamConnected = false
                if task.closeCode == .policyViolation {
                    self.endMembership(message: "Your room membership ended. You may have been removed by the host.")
                    return
                }
                self.cancelCloudRoomWork()
                await self.stopSpeaking()
                guard !Task.isCancelled, self.matchesRoom(roomID, generation: generation), self.streamGeneration == stream else { return }
                self.transcriptionMessage = "Voice connection interrupted. Reconnecting…"
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                if !Task.isCancelled, self.matchesRoom(roomID, generation: generation), self.streamGeneration == stream {
                    self.connectStream(roomID: roomID, generation: generation)
                }
            }
        }
        startRoomPolling(roomID: roomID, generation: generation, using: api)
    }

    /// Keep this room-scoped poll alive across socket reconnect attempts. It is also the
    /// fallback for an HTTP handshake refusal that cannot deliver a WebSocket close code.
    func startRoomPolling(roomID: String, generation: UUID, using api: RoomAPI) {
        // Membership polling belongs to the room, not to a particular socket attempt.
        // Otherwise a 2-second reconnect loop continually cancels the 3-second poll,
        // leaving an expired or kicked membership stuck reconnecting forever.
        guard pollTask == nil, matchesRoom(roomID, generation: generation) else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard !Task.isCancelled, let self, self.matchesRoom(roomID, generation: generation) else { return }
                do {
                    let response: RoomAPI.RoomResponse = try await api.request("v1/rooms/\(roomID)")
                    guard !Task.isCancelled, self.matchesRoom(roomID, generation: generation) else { return }
                    await self.update(response.room, generation: generation)
                } catch {
                    guard !Task.isCancelled, self.matchesRoom(roomID, generation: generation) else { return }
                    if let status = (error as? APIError)?.statusCode, [401, 403, 404].contains(status) {
                        self.endMembership(message: "This room is no longer available to your account.")
                        return
                    }
                }
            }
        }
    }

    func update(_ room: DebateRoom, generation: UUID) async {
        // Validate freshness before membership checks or microphone/history side effects.
        // A rejected poll response must have no effect on the currently active turn.
        guard acceptsSnapshot(room, generation: generation) else { return }
        guard room.participants.contains(where: { $0.id == participantID }) else {
            endMembership(message: "You are no longer in this room.")
            return
        }
        let previousTurn = activeRoom?.currentTurn?.id
        if hasRoomCloudConsent && !room.cloudConsentParticipantIDs.contains(participantID) { cancelCloudRoomWork() }
        applySnapshot(room, generation: generation)
        if !canSpeak || previousTurn != room.currentTurn?.id {
            if voice.isMicrophoneEnabled || isTranscribing || isStartingMicrophone { await stopSpeaking() }
        }
        guard matchesRoom(room.id, generation: generation) else { return }
        if let current = activeRoom, current.status == "finished" {
            saveHistory(current)
            voice.stop()
            audioWatchTask?.cancel()
            audioWatchTask = nil
        }
    }

    private func applySnapshot(_ room: DebateRoom, generation: UUID) {
        guard acceptsSnapshot(room, generation: generation) else { return }
        activeRoom = room
    }

    private func acceptsSnapshot(_ room: DebateRoom, generation: UUID) -> Bool {
        guard matchesRoom(room.id, generation: generation), let current = activeRoom,
              room.revision >= current.revision else { return false }
        // Older servers lack revisions. These phase checks also protect legacy snapshots.
        let phases = ["waiting": 0, "preparing": 1, "live": 2, "finished": 3]
        guard (phases[room.status] ?? -1) >= (phases[current.status] ?? -1) else { return false }
        return room.status != current.status || room.currentTurnIndex >= current.currentTurnIndex
    }

    private func matchesRoom(_ roomID: String, generation: UUID) -> Bool {
        roomGeneration == generation && activeRoom?.id == roomID
    }

    private func microphoneIsCurrent(_ microphone: UUID, roomID: String, room: UUID, stream: UUID, turnID: String) -> Bool {
        microphoneGeneration == microphone && matchesRoom(roomID, generation: room)
            && streamGeneration == stream && streamConnected && activeRoom?.currentTurn?.id == turnID && canSpeak
    }

    private func discardMembership(_ roomID: String, using client: RoomAPI) async {
        guard activeRoom?.id != roomID else { return }
        let _: RoomAPI.RoomResponse? = try? await client.request("v1/rooms/\(roomID)/actions", method: "POST", body: ["action": "leave"])
    }

    private func endMembership(message: String) {
        // Host removal or expired membership must not discard the already recognized
        // speech. Save locally before cancelling recognition; this path never uploads.
        var speech = finishingSpeech
        if speech == nil, isTranscribing, let room = activeRoom, let turnID = speechTurnID ?? room.currentTurn?.id {
            speech = (room, turnID, participantID)
        }
        let recoveryNotice = speech.flatMap {
            preserveInterruptedSpeech(transcriber.partialText, room: $0.room, turnID: $0.turnID, participantID: $0.participantID)
        }
        cancelCloudRoomWork()
        finishSpeechTask?.cancel()
        roomGeneration = UUID()
        microphoneGeneration = UUID()
        isStartingMicrophone = false
        disconnectStream()
        voice.stop()
        transcriber.cancel()
        isTranscribing = false
        speechTurnID = nil
        activeRoom = nil
        alertMessage = [message, recoveryNotice].compactMap { $0 }.joined(separator: " ")
    }

    /// A local-only fallback for forced departure, separate from acknowledged room text.
    @discardableResult
    func preserveInterruptedSpeech(_ text: String, room: DebateRoom, turnID: String, participantID: String) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let record = RecoveredTranscript(id: UUID().uuidString, roomID: room.id, roomTitle: room.title,
            turnID: turnID, turnLabel: room.format.turns.first { $0.id == turnID }?.label ?? "Speech",
            language: room.language, participantID: participantID,
            speakerName: (room.participants + room.debateParticipants).first { $0.id == participantID }?.displayName ?? "Speaker",
            text: text, createdAt: Date().timeIntervalSince1970)
        do {
            // A finishing upload may already have preserved this exact recognition result.
            if !recoveredTranscripts.contains(where: { $0.roomID == room.id && $0.turnID == turnID && $0.participantID == participantID && $0.text == text }) {
                recoveredTranscripts = try recoveryArchive.preserve(record)
            }
            recoveryMessage = "Your speech so far was saved in Recovered speeches. This local copy is not added to the room transcript or its results."
        } catch {
            recoveryMessage = "Your interrupted speech could not be saved locally. \(error.localizedDescription)"
        }
        return recoveryMessage
    }

    /// Also available to audience members after an audio route or phone interruption.
    func reconnectAudio() async {
        guard let room = activeRoom else { return }
        let generation = roomGeneration
        await stopSpeaking()
        guard matchesRoom(room.id, generation: generation) else { return }
        do {
            try await voice.startReceiving()
            if matchesRoom(room.id, generation: generation) { transcriptionMessage = nil }
        } catch {
            if matchesRoom(room.id, generation: generation) { transcriptionMessage = error.localizedDescription }
        }
    }

    private func startAudioWatch(roomID: String, generation: UUID) {
        audioWatchTask?.cancel()
        audioWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.matchesRoom(roomID, generation: generation), !Task.isCancelled else { return }
                if !self.canSpeak && (self.voice.isMicrophoneEnabled || self.isStartingMicrophone || self.isTranscribing) {
                    await self.stopSpeaking()
                }
                guard self.matchesRoom(roomID, generation: generation), !Task.isCancelled else { return }
                if !self.voice.isConnected, let message = self.voice.errorMessage {
                    self.transcriptionMessage = message
                    self.cancelCloudRoomWork()
                    if self.isTranscribing || self.isStartingMicrophone || self.speechTurnID != nil { await self.stopSpeaking() }
                } else if let message = self.transcriber.errorMessage, self.isTranscribing {
                    self.transcriptionMessage = message
                }
            }
        }
    }

    private func disconnectStream() {
        streamGeneration = UUID()
        microphoneGeneration = UUID()
        streamTask?.cancel(); streamTask = nil
        pollTask?.cancel(); pollTask = nil
        audioWatchTask?.cancel(); audioWatchTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        streamConnected = false
        audioPacketsInFlight = 0
    }

    private func friendlyNetworkError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .timedOut:
                return "The room server is unavailable. Check your connection or the server address in Profile. Formats and Practice are still available."
            default: break
            }
        }
        return error.localizedDescription
    }

    private struct RoomEvent: Decodable {
        let type: String
        let room: DebateRoom?
        let message: String?
    }
}
