import SwiftUI

struct FormatsView: View {
    @State private var editingFormat: DebateFormat?
    @State private var savedFormats: [DebateFormat] = []
    @State private var libraryError: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Same curiosity.\nDifferent rules.").font(.system(.largeTitle, design: .rounded).weight(.bold)).tracking(-1)
                Text("From a quick exchange to a full parliamentary debate. Find the format that fits.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(Array(FormatCatalog.presets.enumerated()), id: \.element.id) { index, format in
                    NavigationLink { FormatDetailView(format: format) } label: {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Image(systemName: ["bolt", "building.columns", "graduationcap", "globe.asia.australia"][index % 4])
                                    .font(.title2).foregroundStyle(Design.accent).frame(width: 46, height: 46)
                                    .background(Design.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                Spacer()
                                Text("\(format.capacity) voices").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                Image(systemName: "arrow.up.right").foregroundStyle(Design.accent)
                            }
                            Text(format.name).font(.title3.bold()).foregroundStyle(.primary)
                            Text(format.summary).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            HStack { Pill(title: "\(format.teams.count) teams"); Pill(title: "~\(format.totalDurationSeconds / 60) min", icon: "clock") }
                        }.cardStyle()
                    }.buttonStyle(.plain)
                }
                if !savedFormats.isEmpty {
                    SectionHeading(title: "Your formats", subtitle: "Saved on this device. Ready for your next room.")
                    ForEach(savedFormats) { format in
                        VStack(alignment: .leading, spacing: 14) {
                            NavigationLink { FormatDetailView(format: format) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(format.name).font(.headline).foregroundStyle(.primary)
                                        Text("\(format.capacity) speakers · ~\(format.totalDurationSeconds / 60) min")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Design.accent)
                                }
                            }.buttonStyle(.plain)
                            HStack {
                                Button("Edit", systemImage: "pencil") { editingFormat = format }
                                Spacer()
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    do {
                                        try CustomFormatLibrary.remove(id: format.id)
                                        savedFormats = CustomFormatLibrary.load()
                                    } catch { libraryError = error.localizedDescription }
                                }.accessibilityLabel("Delete \(format.name)")
                            }.font(.subheadline)
                        }.cardStyle()
                    }
                }
                Button { editingFormat = FormatCatalog.custom() } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "slider.horizontal.3").font(.title2)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Make it your own").font(.headline)
                            Text("Build a custom format, turn by turn.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "plus")
                    }.cardStyle()
                }.buttonStyle(.plain).foregroundStyle(Design.accent)
                InfoBanner(text: "These are practice presets based on common rules. Tournament procedures vary; review the schedule before starting.")
            }.padding(22)
        }.background(Design.background).navigationTitle("The playbook").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editingFormat) { format in
                NavigationStack {
                    CustomFormatView(initial: format) { edited in
                        do {
                            try CustomFormatLibrary.save(edited)
                            savedFormats = CustomFormatLibrary.load()
                        } catch { libraryError = error.localizedDescription }
                    }
                }
            }
            .onAppear { savedFormats = CustomFormatLibrary.load() }
            .alert("Format could not be saved", isPresented: Binding(get: { libraryError != nil }, set: { if !$0 { libraryError = nil } })) {
                Button("OK", role: .cancel) { libraryError = nil }
            } message: { Text(libraryError ?? "") }
    }
}

struct FormatDetailView: View {
    let format: DebateFormat
    @State private var create = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(format.name).font(.largeTitle.bold())
                Text(format.summary).foregroundStyle(.secondary)
                HStack { Pill(title: "\(format.capacity) speakers", icon: "person.2"); Pill(title: "~\(format.totalDurationSeconds / 60) min", icon: "clock") }
                VStack(alignment: .leading, spacing: 12) {
                    Label("\(durationLabel(format.preparationSeconds)) preparation", systemImage: "pencil.and.list.clipboard")
                    Label(format.poiEnabled ? "Points of information allowed" : "Uninterrupted speaking turns", systemImage: "hand.raised")
                    Label("\(format.graceSeconds)-second grace period", systemImage: "timer")
                }.font(.subheadline).cardStyle()
                SectionHeading(title: "The speaking order")
                TurnSchedule(format: format)
                PrimaryButton(title: "Create a room", icon: "plus") { create = true }
            }.padding(22)
        }.background(Design.background).navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $create) { NavigationStack { CreateRoomView(initialFormat: format) } }
    }
}

struct TurnSchedule: View {
    let format: DebateFormat
    var currentIndex: Int? = nil
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(format.turns.enumerated()), id: \.element.id) { index, turn in
                HStack(alignment: .top, spacing: 13) {
                    Text("\(index + 1)").font(.caption.bold()).foregroundStyle(currentIndex == index ? .white : Design.accent)
                        .frame(width: 29, height: 29).background(currentIndex == index ? Design.purple : Design.purple.opacity(0.08), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(turn.label).font(.subheadline.weight(.semibold))
                        Text("\(format.teams.first { $0.id == turn.teamID }?.name ?? "Team") · Speaker \(turn.speakerIndex + 1)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(durationLabel(turn.durationSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
                if index != format.turns.count - 1 { Divider() }
            }
        }.cardStyle()
    }
}

struct CustomFormatView: View {
    @Environment(\.dismiss) private var dismiss
    @State var format: DebateFormat
    @State private var rounds = 1
    @State private var baseSpeech = 180
    let onSave: (DebateFormat) -> Void

    init(initial: DebateFormat, onSave: @escaping (DebateFormat) -> Void) {
        _format = State(initialValue: initial)
        _baseSpeech = State(initialValue: initial.turns.first?.durationSeconds ?? 180)
        let completeRounds = initial.capacity > 0 ? initial.turns.filter { $0.kind == "substantive" }.count / initial.capacity : 1
        _rounds = State(initialValue: min(2, max(1, completeRounds)))
        self.onSave = onSave
    }
    var errors: [String] { format.validate() }
    var body: some View {
        Form {
            Section("Your format") {
                TextField("Format name", text: $format.name)
                TextField("A short description", text: $format.summary, axis: .vertical)
            }
            Section {
                Stepper("Teams: \(format.teams.count)", value: Binding(get: { format.teams.count }, set: { rebuild(teams: $0, speakers: format.speakersPerTeam) }), in: 2...4)
                Stepper("Speakers per team: \(format.speakersPerTeam)", value: Binding(get: { format.speakersPerTeam }, set: { rebuild(teams: format.teams.count, speakers: $0) }), in: 1...4)
                Stepper("Rounds: \(rounds)", value: $rounds, in: 1...2).onChange(of: rounds) { _, _ in rebuild(teams: format.teams.count, speakers: format.speakersPerTeam) }
                Stepper("Default speech: \(durationLabel(baseSpeech))", value: $baseSpeech, in: 30...900, step: 30)
                Button("Regenerate speaking order") { rebuild(teams: format.teams.count, speakers: format.speakersPerTeam) }
            } header: { Text("Structure") } footer: { Text("Changing the number of teams, speakers, or rounds regenerates the schedule. Edit individual turns below afterward.") }
            Section("Teams and sides") {
                ForEach($format.teams) { $team in
                    VStack(alignment: .leading) {
                        TextField("Team name", text: $team.name)
                        Picker("Side", selection: $team.side) {
                            Text("Government / for").tag("government")
                            Text("Opposition / against").tag("opposition")
                        }.font(.caption)
                    }
                }
            }
            Section("Clock and interruptions") {
                Stepper("Preparation: \(durationLabel(format.preparationSeconds))", value: $format.preparationSeconds, in: 0...3600, step: 60)
                Stepper("Grace: \(format.graceSeconds) sec", value: $format.graceSeconds, in: 0...60, step: 5)
                Toggle("Points of information", isOn: $format.poiEnabled)
                if format.poiEnabled {
                    Stepper("Protected at each end: \(format.protectedSeconds) sec", value: $format.protectedSeconds, in: 0...300, step: 15)
                    Stepper("POI length: \(format.poiDurationSeconds) sec", value: $format.poiDurationSeconds, in: 5...30, step: 5)
                }
            }
            Section {
                ForEach($format.turns) { $turn in
                    DisclosureGroup {
                        TextField("Speech title", text: $turn.label)
                        Picker("Team", selection: $turn.teamID) { ForEach(format.teams) { Text($0.name).tag($0.id) } }
                        Picker("Speaker", selection: $turn.speakerIndex) { ForEach(0..<format.speakersPerTeam, id: \.self) { Text("Speaker \($0 + 1)").tag($0) } }
                        Picker("Type", selection: $turn.kind) { Text("Substantive").tag("substantive"); Text("Reply").tag("reply") }
                        Stepper("\(durationLabel(turn.durationSeconds))", value: $turn.durationSeconds, in: 30...900, step: 30)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(turn.label).font(.subheadline.weight(.medium))
                            Text("\(durationLabel(turn.durationSeconds)) · \(turn.kind.capitalized)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.onMove { from, to in format.turns.move(fromOffsets: from, toOffset: to) }
                    .onDelete { offsets in format.turns.remove(atOffsets: offsets) }
                Button("Add a speech", systemImage: "plus") {
                    guard let team = format.teams.first else { return }
                    format.turns.append(SpeechTurn(id: UUID().uuidString, label: "Additional speech", teamID: team.id, speakerIndex: 0, durationSeconds: baseSpeech, kind: "substantive"))
                }.disabled(format.turns.count >= 32)
            } header: { Text("Speaking order · \(format.turns.count) turns") } footer: { Text("Use Edit to reorder or remove turns. Every seat needs a substantive speech. Reply speeches come last and have no POIs.") }
            if !errors.isEmpty {
                Section("Before you save") { ForEach(errors, id: \.self) { Text($0).font(.footnote).foregroundStyle(Design.orange) } }
            }
            Section {
                LabeledContent("Total duration", value: "~\(format.totalDurationSeconds / 60) min")
                PrimaryButton(title: "Save format", icon: "checkmark") { onSave(format); dismiss() }.disabled(!errors.isEmpty)
            }
        }.navigationTitle("Custom format").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
    }
    private func rebuild(teams: Int, speakers: Int) {
        let previous = format
        let name = format.name
        format = FormatCatalog.custom(teamCount: teams, speakersPerTeam: speakers, preparationSeconds: format.preparationSeconds,
                                      speechDurationSeconds: baseSpeech, rounds: rounds, poiEnabled: format.poiEnabled,
                                      protectedSeconds: format.protectedSeconds, poiDurationSeconds: format.poiDurationSeconds, graceSeconds: format.graceSeconds)
        format.name = name
        format.id = previous.id
        format.summary = previous.summary
        for index in format.teams.indices where previous.teams.indices.contains(index) {
            format.teams[index].name = previous.teams[index].name
            format.teams[index].side = previous.teams[index].side
        }
    }
}
