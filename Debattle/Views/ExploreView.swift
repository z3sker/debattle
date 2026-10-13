import SwiftUI

private enum ExploreSheet: String, Identifiable {
    case create, invite, signIn
    var id: String { rawValue }
}

struct ExploreView: View {
    @Environment(AppStore.self) private var store
    @State private var sheet: ExploreSheet?
    @State private var search = ""
    @State private var selectedFormat = "all"
    @State private var language = "All languages"
    @State private var joiningRoom: DebateRoom?
    private var hasFilters: Bool { !search.isEmpty || selectedFormat != "all" || language != "All languages" }
    var filteredRooms: [DebateRoom] {
        store.rooms.filter { room in
            (selectedFormat == "all" || room.format.id == selectedFormat)
            && (language == "All languages" || room.language == language)
            && (search.isEmpty || room.title.localizedCaseInsensitiveContains(search))
            && room.status != "finished"
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                hero
                if store.needsSignIn { SignInPrompt() }
                filters
                VStack(spacing: 15) {
                    HStack {
                        SectionHeading(title: "Find your next debate", subtitle: "Open rooms. Different perspectives.")
                        if store.isLoading { ProgressView() }
                    }
                    if let message = store.connectionMessage {
                        VStack(alignment: .leading, spacing: 12) {
                            InfoBanner(text: message, icon: "wifi.exclamationmark")
                            Button("Try connecting again") { Task { await store.connect() } }.font(.subheadline.bold())
                        }
                    }
                    if filteredRooms.isEmpty {
                        if store.connectionMessage == nil {
                            EmptyCard(icon: "bubble.left.and.bubble.right", title: hasFilters ? "No matching rooms" : "The floor is yours", message: hasFilters ? "Try another topic, language, or format." : "No open rooms here yet. Start a public debate and give someone a reason to join.")
                            if hasFilters {
                                Button("Clear filters") { search = ""; selectedFormat = "all"; language = "All languages" }
                                    .font(.subheadline.bold()).frame(minHeight: 44)
                            }
                            PrimaryButton(title: "Start a public room", icon: "plus") { sheet = store.needsSignIn ? .signIn : .create }
                        }
                    } else {
                        ForEach(filteredRooms) { room in
                            Button { if store.needsSignIn { sheet = .signIn } else { joiningRoom = room } } label: { RoomCard(room: room) }.buttonStyle(.plain)
                        }
                    }
                }
                Button { sheet = store.needsSignIn ? .signIn : .invite } label: { HStack(spacing: 14) {
                    Image(systemName: "ticket").font(.title2).foregroundStyle(Design.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Have an invitation?").font(.subheadline.bold()).foregroundStyle(.primary)
                        Text("Join a room with its code.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right").foregroundStyle(Design.accent)
                }.cardStyle() }.buttonStyle(.plain)
                    .accessibilityLabel("Join a room with an invite code")
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "A little preparation goes a long way")
                    Button { store.selectedTab = 2 } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "mic.badge.plus").font(.title).foregroundStyle(Design.accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Warm up in Practice").font(.headline).foregroundStyle(.primary)
                                Text("One idea. One speech. Your own pace.").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.cardStyle()
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 28)
        }
        .background(Design.background)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await store.refreshRooms() }
        .sheet(item: $sheet) { item in
            switch item {
            case .create: NavigationStack { CreateRoomView() }
            case .invite: NavigationStack { InviteView() }
            case .signIn: NavigationStack { AccountSignInView() }
            }
        }
        .sheet(item: $joiningRoom) { room in NavigationStack { JoinRoomView(room: room) } }
        .onChange(of: store.pendingInvite) { _, code in if code != nil { sheet = store.needsSignIn ? .signIn : .invite } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                if !Task.isCancelled { await store.refreshRooms() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            BrandMark()
            Text("Debattle").font(.system(size: 29, weight: .bold, design: .rounded)).tracking(-1)
            Spacer()
            Button { sheet = store.needsSignIn ? .signIn : .create } label: {
                Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                    .background(Design.surface, in: Circle())
            }.accessibilityLabel("Create a room").accessibilityIdentifier("explore.create")
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                Circle().fill(Color(red: 0.75, green: 1, blue: 0.65)).frame(width: 6, height: 6)
                Text("A DIFFERENT POINT OF VIEW").font(.system(size: 10, weight: .bold)).tracking(1.7)
            }.foregroundStyle(.white.opacity(0.85))
            Text("Good arguments.\nGreat conversations.")
                .font(.system(.largeTitle, design: .rounded).weight(.bold)).tracking(-1)
                .foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Take a side.\nKeep an open mind.").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                Spacer()
                HStack(alignment: .center, spacing: 4) {
                    ForEach(Array([16.0, 29, 43, 22, 51, 35, 19, 39, 26].enumerated()), id: \.offset) { _, height in
                        Capsule().fill(.white.opacity(0.6)).frame(width: 4, height: height)
                    }
                }.accessibilityHidden(true)
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Color(red: 0.33, green: 0.19, blue: 0.72), Design.purple, Color(red: 0.54, green: 0.37, blue: 0.92)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 28))
    }

    private var filters: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a motion or topic", text: $search).font(.subheadline)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(.secondary).accessibilityLabel("Clear search") }
            }.padding(15).background(Design.surface, in: RoundedRectangle(cornerRadius: 16))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip("All formats", id: "all")
                    ForEach(FormatCatalog.presets) { format in filterChip(format.name, id: format.id) }
                }
            }
            HStack {
                Menu {
                    Picker("Language", selection: $language) {
                        Text("All languages").tag("All languages")
                        ForEach(debateLanguages, id: \.self) { Text($0).tag($0) }
                    }
                } label: { Label(language, systemImage: "globe").font(.subheadline.weight(.medium)) }
                Spacer()
                Text(store.connectionMessage != nil ? "Rooms unavailable" : "\(filteredRooms.count) open \(filteredRooms.count == 1 ? "room" : "rooms")").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func filterChip(_ title: String, id: String) -> some View {
        Button { selectedFormat = id } label: {
            Text(title).font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 10)
                .foregroundStyle(selectedFormat == id ? .white : .primary)
                .background(selectedFormat == id ? Design.purple : Design.surface, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selectedFormat == id ? .isSelected : [])
    }
}

struct RoomCard: View {
    let room: DebateRoom
    private var statusTitle: String {
        switch room.status {
        case "waiting": "Taking seats"
        case "preparing": "Preparing"
        case "finished": "Completed"
        default: room.isPaused ? "Paused" : "Live"
        }
    }
    private var statusIcon: String {
        switch room.status {
        case "waiting": "person.2"
        case "preparing": "timer"
        case "finished": "checkmark.circle"
        default: room.isPaused ? "pause.circle" : "waveform"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Pill(title: statusTitle, icon: statusIcon, color: room.status == "finished" ? Design.accent : Design.green)
                Spacer()
                Text(room.language).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(room.title).font(.title3.bold()).foregroundStyle(.primary).multilineTextAlignment(.leading).lineLimit(3)
            HStack {
                Text(room.format.name).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Label("\(room.occupiedSeats)/\(room.format.capacity)", systemImage: "person.2").font(.caption.weight(.semibold)).foregroundStyle(Design.accent)
                Image(systemName: "arrow.up.right").font(.caption.bold()).foregroundStyle(Design.accent)
            }
        }.cardStyle()
    }
}

struct JoinRoomView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let room: DebateRoom
    @State private var consent = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Pill(title: "PUBLIC ROOM", icon: "globe")
                Text(room.title).font(.largeTitle.bold())
                HStack { Pill(title: room.format.name); Pill(title: room.language, icon: "globe") }
                Text(room.status != "waiting" ? "The debate has started. Join the audience to listen." : room.availableSeats == 0 ? "All speaker seats are taken. You can join the audience." : "\(room.availableSeats) speaker seats available · Join to choose a side or listen.").font(.subheadline).foregroundStyle(.secondary)
                ConsentPanel(consent: $consent)
                PrimaryButton(title: "Enter room", icon: "arrow.right", busy: store.isWorking) {
                    Task { if await store.join(roomID: room.id) { dismiss() } }
                }.disabled(!consent)
            }.padding(24)
        }.background(Design.background).navigationTitle("Join the conversation").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

struct InviteView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var consent = false
    var body: some View {
        Form {
            Section("Room invitation") {
                TextField("Invite code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
            }
            Section { ConsentPanel(consent: $consent) }
            Section {
                PrimaryButton(title: "Join room", icon: "arrow.right", busy: store.isWorking) {
                    Task { if await store.join(inviteCode: code) { store.pendingInvite = nil; dismiss() } }
                }.disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !consent)
            }.listRowBackground(Color.clear)
        }.navigationTitle("Join with a code").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.pendingInvite = nil; dismiss() } } }
            .onAppear { code = store.pendingInvite ?? "" }
    }
}

struct ConsentPanel: View {
    @Binding var consent: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("A respectful space", systemImage: "hand.raised").font(.headline)
            Text("Debate the idea, respect the person. Voices are relayed through the room server. Speeches may be transcribed and shared with room members for review. Groq processing needs separate permission from each speaker. The server does not save raw audio.")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("I agree to the room rules and transcription", isOn: $consent).font(.subheadline)
        }.cardStyle()
    }
}
