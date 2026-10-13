import SwiftUI

private enum RoomSheet: String, Identifiable {
    case schedule, transcript, report, cloudConsent
    var id: String { rawValue }
}

struct LiveRoomView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: RoomSheet?
    @State private var confirmLeave = false
    @State private var feedback: JudgeFeedback?
    @State private var feedbackError: String?
    var body: some View {
        Group {
            if let room = store.activeRoom {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        statusHeader(room)
                        Text(room.title).font(.system(.title, design: .rounded).weight(.bold)).tracking(-0.8)
                        HStack { Pill(title: room.format.name); Pill(title: room.language, icon: "globe") }
                        if room.status == "waiting" { lobby(room) }
                        else if room.status == "finished" { finished(room) }
                        else { stage(room) }
                        if room.status == "live" { microphone(room) }
                        roomCloudAI(room)
                        teams(room)
                        if let message = store.transcriptionMessage { InfoBanner(text: message) }
                        if let message = store.voice.errorMessage {
                            InfoBanner(text: message, icon: "waveform.slash")
                            Button("Reconnect audio", systemImage: "arrow.clockwise") { Task { await store.reconnectAudio() } }.font(.subheadline.bold())
                        }
                        if store.isTranscribing, !store.transcriber.partialText.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Your live transcript", systemImage: "text.bubble").font(.caption.bold()).foregroundStyle(Design.accent)
                                Text(store.transcriber.partialText).font(.subheadline).foregroundStyle(.secondary)
                            }.cardStyle()
                        }
                        if room.status == "waiting", let code = room.inviteCode {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("INVITE CODE").font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
                                    Text(code).font(.system(.subheadline, design: .monospaced).bold()).textSelection(.enabled)
                                }
                                Spacer()
                                ShareLink(item: "Join my Debattle room: debattle://join/\(code)\nInvite code: \(code)") { Image(systemName: "square.and.arrow.up").font(.title3) }.accessibilityLabel("Share invitation")
                            }.cardStyle()
                        }
                        hostControls(room)
                    }.padding(22).padding(.bottom, 12)
                }.background(Design.background)
            } else { ContentUnavailableView("You’ve left the room", systemImage: "door.left.hand.open") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let room = store.activeRoom, room.status == "live" {
                microphoneToggle(room)
                    .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 8)
                    .background(.regularMaterial)
            }
        }
        .navigationTitle("Debate room").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Leave") { confirmLeave = true }.tint(Design.orange) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Speaking order", systemImage: "list.number") { sheet = .schedule }
                    Button("Room transcript", systemImage: "text.alignleft") { sheet = .transcript }
                    Button("Cloud AI permission", systemImage: "cloud") { sheet = .cloudConsent }
                    Button("Report a problem", systemImage: "flag", role: .destructive) { sheet = .report }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Room options")
            }
        }
        .confirmationDialog("Leave this debate?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave room", role: .destructive) { Task { await store.leaveRoom(); dismiss() } }
        } message: {
            Text(store.activeRoom?.status == "finished" ? "Your transcript stays in your journal. Generate a cloud verdict before leaving; it requires current room membership." : store.me?.teamID != nil && ["preparing", "live"].contains(store.activeRoom?.status ?? "") ? "Leaving as a speaker ends this debate for everyone. Your microphone will stop." : "Your microphone will stop and your seat will become available.")
        }
        .sheet(item: $sheet) { item in
            NavigationStack {
                Group {
                    switch item {
                    case .schedule: ScrollView { if let room = store.activeRoom { TurnSchedule(format: room.format, currentIndex: room.status == "live" ? room.currentTurnIndex : nil).padding(20) } }.navigationTitle("Speaking order")
                    case .transcript: TranscriptView(room: store.activeRoom)
                    case .report: ReportView()
                    case .cloudConsent: CloudRoomConsentView()
                    }
                }.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }.navigationBarTitleDisplayMode(.inline)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await store.suspendRoomAudio() } }
        }
        .alert("Debattle", isPresented: Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })) {
            Button("OK", role: .cancel) { store.alertMessage = nil }
        } message: { Text(store.alertMessage ?? "") }
    }

    private func statusHeader(_ room: DebateRoom) -> some View {
        HStack {
            Pill(title: room.status == "waiting" ? "Taking seats" : room.status == "finished" ? "Round ended" : room.isPaused ? "Paused" : room.status == "preparing" ? "Preparation" : "On the floor", icon: room.status == "live" ? "waveform" : "circle.fill", color: room.status == "finished" ? Design.accent : Design.green)
            Spacer()
            Image(systemName: store.streamConnected ? "wifi" : "wifi.exclamationmark")
                .font(.caption).foregroundStyle(store.streamConnected ? Design.green : Design.orange)
                .accessibilityLabel(store.streamConnected ? "Room connected" : "Reconnecting to room")
            Text(room.visibility.capitalized).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func lobby(_ room: DebateRoom) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "person.2.wave.2").font(.title2).foregroundStyle(Design.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose your side").font(.headline)
                    Text("\(room.occupiedSeats) of \(room.format.capacity) speakers seated").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: Double(room.occupiedSeats), total: Double(max(1, room.format.capacity))).tint(Design.purple)
            Text("Take an open seat below, then mark yourself ready. The host can start when every seat is ready.").font(.footnote).foregroundStyle(.secondary)
            if let me = store.me, me.teamID != nil {
                PrimaryButton(title: me.isReady ? "Ready to debate ✓" : "I’m ready", icon: me.isReady ? nil : "checkmark", busy: store.isWorking) {
                    Task { await store.action("ready", values: ["isReady": !me.isReady]) }
                }
                Button("Move to audience") { Task { await store.action("spectate") } }.font(.footnote)
            } else { Text("You’re currently listening. Taking a seat makes you a speaker.").font(.caption).foregroundStyle(Design.accent) }
        }.cardStyle()
    }

    private func stage(_ room: DebateRoom) -> some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let remaining = DebateRules.remainingSeconds(in: room, at: context.date.timeIntervalSince1970)
            VStack(spacing: 14) {
                Text(room.status == "preparing" ? "PREPARE YOUR CASE" : room.currentTurn?.label.uppercased() ?? "YOUR TURN")
                    .font(.caption.bold()).tracking(1.3).foregroundStyle(Design.accent)
                Text(DebateRules.clockText(remaining)).font(.system(size: 69, weight: .medium, design: .rounded)).monospacedDigit().tracking(-3)
                    .foregroundStyle(DebateRules.isInGracePeriod(room, at: context.date.timeIntervalSince1970) ? Design.orange : .primary)
                    .contentTransition(.numericText(countsDown: true))
                if room.status == "live" {
                    Text(room.currentSpeaker?.displayName ?? "Waiting for the speaker").font(.headline)
                    Text("Turn \(room.currentTurnIndex + 1) of \(room.format.turns.count) · includes \(room.format.graceSeconds)s grace").font(.caption).foregroundStyle(.secondary)
                } else { Text("Gather your thoughts. The first speech starts automatically.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                if room.isPaused { Pill(title: "Clock paused by host", icon: "pause") }
                if let poiSpeaker = room.participants.first(where: { $0.id == room.poiSpeakerID }) {
                    Pill(title: "\(poiSpeaker.displayName) · point of information", icon: "hand.raised", color: Design.orange)
                }
            }.padding(26).frame(maxWidth: .infinity).background(Design.surface, in: RoundedRectangle(cornerRadius: 28))
        }
    }

    private func teams(_ room: DebateRoom) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            ForEach(room.format.teams) { team in
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Circle().fill(team.side == "government" ? Design.purple : Design.orange).frame(width: 8, height: 8)
                        Text(team.name).font(.subheadline.bold())
                        Spacer()
                        Text(team.side == "government" ? "FOR" : "AGAINST").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                    }
                    ForEach(0..<room.format.speakersPerTeam, id: \.self) { seat in
                        seatRow(room: room, team: team, seat: seat)
                    }
                }.cardStyle()
            }
            let audience = room.participants.filter { $0.teamID == nil }
            if !audience.isEmpty {
                HStack {
                    Image(systemName: "headphones").foregroundStyle(Design.accent)
                    Text("\(audience.count) in the audience").font(.subheadline)
                    Spacer()
                }.padding(.horizontal, 4)
            }
        }
    }

    private func seatRow(room: DebateRoom, team: DebateTeam, seat: Int) -> some View {
        let participant = room.participants.first { $0.teamID == team.id && $0.seatIndex == seat }
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill((team.side == "government" ? Design.purple : Design.orange).opacity(0.10))
                Text(participant.map { String($0.displayName.prefix(1)).uppercased() } ?? "+").font(.headline).foregroundStyle(team.side == "government" ? Design.accent : Design.orange)
            }.frame(width: 40, height: 40)
            if let participant {
                VStack(alignment: .leading, spacing: 3) {
                    Text(participant.displayName + (participant.id == store.participantID ? " (you)" : "")).font(.subheadline.weight(.medium))
                    Text(participant.id == room.hostID ? "Host · Speaker \(seat + 1)" : "Speaker \(seat + 1)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if participant.isReady, room.status == "waiting" { Image(systemName: "checkmark.circle.fill").foregroundStyle(Design.green).accessibilityLabel("Ready") }
                else if room.status == "live" { Image(systemName: participant.isMuted ? "mic.slash" : "waveform").foregroundStyle(participant.isMuted ? .secondary : Design.accent).accessibilityLabel(participant.isMuted ? "Microphone muted" : "Microphone enabled") }
                if participant.id != store.participantID {
                    Menu {
                        if store.amHost { Button("Remove from room", role: .destructive) { Task { await store.action("kick", values: ["participantID": participant.id]) } } }
                        Button("Block and leave", role: .destructive) { Task { await store.block(participant.id) } }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Options for \(participant.displayName)")
                }
            } else {
                Text("Open seat").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if room.status == "waiting" {
                    Button("Take seat") { Task { await store.action("takeSeat", values: ["teamID": team.id, "seatIndex": seat]) } }
                        .font(.caption.bold()).buttonStyle(.bordered).disabled(store.isWorking)
                        .accessibilityIdentifier("seat.\(team.id).\(seat)")
                }
            }
        }
    }

    private func microphone(_ room: DebateRoom) -> some View {
        VStack(spacing: 12) {
            if room.status == "live" {
                if DebateRules.canOfferPOI(participantID: store.participantID, in: room) {
                    Button(room.poiRequests.contains(store.participantID) ? "Point requested" : "Request a point of information", systemImage: "hand.raised") {
                        Task { await store.action("requestPOI") }
                    }.font(.subheadline).disabled(room.poiRequests.contains(store.participantID))
                }
                if room.currentSpeaker?.id == store.participantID {
                    ForEach(room.poiRequests, id: \.self) { participantID in
                        if let participant = room.participants.first(where: { $0.id == participantID }) {
                            Button("Accept point from \(participant.displayName)") { Task { await store.action("acceptPOI", values: ["participantID": participantID]) } }.font(.subheadline)
                        }
                    }
                }
                if room.poiSpeakerID != nil, store.canSpeak || room.currentSpeaker?.id == store.participantID || store.amHost {
                    Button("End point of information") { Task { await store.action("endPOI") } }.font(.subheadline)
                }
            }
        }
    }

    private func microphoneToggle(_ room: DebateRoom) -> some View {
        Button { Task { await store.toggleMicrophone() } } label: {
            HStack(spacing: 12) {
                Image(systemName: store.voice.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill").font(.title3)
                Text(store.voice.isMicrophoneEnabled ? "Microphone on · tap to mute" : !store.streamConnected ? "Voice reconnecting…" : room.isPaused ? "Debate paused · mic off" : store.canSpeak ? "Your floor · unmute" : "Listening · mic off")
                    .font(.subheadline.bold()).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(18).foregroundStyle(store.canSpeak && store.streamConnected ? .white : .secondary)
                .background(store.canSpeak && store.streamConnected ? Design.purple : Design.surface, in: RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain).disabled(!store.canSpeak || !store.streamConnected)
    }

    @ViewBuilder private func hostControls(_ room: DebateRoom) -> some View {
        if store.amHost, room.status != "finished" {
            VStack(spacing: 12) {
                if room.status == "waiting" {
                    PrimaryButton(title: "Start debate", icon: "play.fill", busy: store.isWorking) { Task { await store.action("start") } }.disabled(!DebateRules.canStart(room))
                    if !DebateRules.canStart(room) { Text("Every speaker seat must be filled and ready.").font(.caption).foregroundStyle(.secondary) }
                } else {
                    HStack {
                        Button(room.isPaused ? "Resume" : "Pause", systemImage: room.isPaused ? "play" : "pause") { Task { await store.action(room.isPaused ? "resume" : "pause") } }.buttonStyle(.bordered)
                        Spacer()
                        Button(room.currentTurnIndex == room.format.turns.count - 1 ? "Finish round" : room.status == "preparing" ? "End preparation" : "Next speech", systemImage: "forward.end") {
                            Task { await store.stopSpeaking(); await store.action("next") }
                        }.buttonStyle(.bordered)
                    }.font(.subheadline)
                }
            }
        }
    }

    private func roomCloudAI(_ room: DebateRoom) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(store.hasRoomCloudConsent ? "Groq enabled for your speeches" : "Speech transcription & AI judge", systemImage: "sparkles")
                .font(.subheadline.bold()).foregroundStyle(Design.accent)
            Text(store.hasRoomCloudConsent
                 ? "Your speech audio is sent after each speaking segment. Every speaker must allow cloud AI before the whole round can be judged."
                 : "Enable multilingual transcription and experimental round feedback. Your permission applies only to this room.")
                .font(.footnote).foregroundStyle(.secondary)
            let speakers = (room.debateParticipants.isEmpty ? room.participants : room.debateParticipants).filter { $0.teamID != nil }
            if !speakers.isEmpty {
                Text("\(speakers.filter { room.cloudConsentParticipantIDs.contains($0.id) }.count) of \(speakers.count) speakers have allowed Groq")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(store.hasRoomCloudConsent ? "Review cloud permission" : "Set up cloud AI", systemImage: "cloud") { sheet = .cloudConsent }
                .font(.subheadline.bold())
        }.cardStyle()
    }

    private func finished(_ room: DebateRoom) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.seal").font(.largeTitle).foregroundStyle(Design.accent)
            Text("Time to reflect.").font(.title2.bold())
            Text("Review the available transcript and reflect on the arguments. The round judge needs a transcript from every scheduled speech.").font(.subheadline).foregroundStyle(.secondary)
            Button("Read the transcript", systemImage: "text.alignleft") { sheet = .transcript }.font(.subheadline.bold())
            NavigationLink { RoundResultsView(room: room) } label: {
                Label("Team placements & speaker points", systemImage: "list.number").font(.subheadline.bold())
            }
            Text("Groq compares all submitted speeches after every speaker has allowed cloud AI. Team placements and speaker points are experimental, with quotations explaining the decision.")
                .font(.footnote).foregroundStyle(.secondary)
            if store.cloudUploadsInProgress > 0 {
                Label("Finishing speech transcription…", systemImage: "hourglass").font(.subheadline)
            }
        }.cardStyle()
    }
}

struct TranscriptView: View {
    let room: DebateRoom?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let room, !room.transcript.isEmpty {
                    ForEach(room.transcript) { segment in
                        VStack(alignment: .leading, spacing: 10) {
                            Text((room.participants + room.debateParticipants).first { $0.id == segment.participantID }?.displayName ?? "Speaker").font(.headline)
                            Text(room.format.turns.first { $0.id == segment.turnID }?.label ?? "Speech").font(.caption).foregroundStyle(Design.accent)
                            Text(segment.text).font(.body).textSelection(.enabled)
                        }.cardStyle()
                    }
                    InfoBanner(text: "Automatic transcripts can contain errors. They are shared with room members and should be checked before relying on AI feedback.")
                } else { EmptyCard(icon: "text.bubble", title: "No transcript yet", message: "Transcripts appear after a speaker mutes or finishes a turn. Each speaker can enable Groq in Cloud AI permission, or use available on-device recognition.") }
            }.padding(22)
        }.background(Design.background).navigationTitle("Transcript")
            .toolbar {
                if let room, room.status == "finished" {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { RoundResultsView(room: room) } label: { Image(systemName: "sparkles") }.accessibilityLabel("Round verdict")
                    }
                }
            }
    }
}

struct ReportView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var sent = false
    var body: some View {
        Form {
            Section("Tell us what happened") { TextField("Describe the issue", text: $reason, axis: .vertical).lineLimit(5...10) }
            Section {
                Button("Submit report") { Task { sent = await store.report(reason: reason); if sent { dismiss() } } }.disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).count < 5)
            } footer: { Text("Reports are saved for the server operator to review. This early beta does not have a staffed moderation team. Leave the room immediately if you feel uncomfortable.") }
        }.navigationTitle("Report a problem")
    }
}
