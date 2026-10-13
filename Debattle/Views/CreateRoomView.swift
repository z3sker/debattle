import SwiftUI

struct CreateRoomView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var language = "English"
    @State private var visibility = "public"
    @State private var format: DebateFormat
    @State private var showCustom = false
    @State private var savedFormats: [DebateFormat] = []
    @State private var libraryError: String?
    @State private var consent = false
    init(initialFormat: DebateFormat = FormatCatalog.duel) { _format = State(initialValue: initialFormat) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Put an idea\non the table.").font(.system(.largeTitle, design: .rounded).weight(.bold)).tracking(-1)
                VStack(alignment: .leading, spacing: 10) {
                    Text("THE MOTION").font(.caption.bold()).tracking(1.4).foregroundStyle(.secondary)
                    TextField("This house believes that…", text: $title, axis: .vertical).font(.title3.weight(.medium)).lineLimit(3...5)
                        .accessibilityIdentifier("create.motion")
                    Text("A clear statement gives both sides something to work with.").font(.caption).foregroundStyle(.secondary)
                }.cardStyle()
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "Who can join?")
                    Picker("Visibility", selection: $visibility) { Text("Public").tag("public"); Text("Private").tag("private") }.pickerStyle(.segmented)
                    Text(visibility == "public" ? "Your room appears in Explore. Anyone can join, take an open seat, or listen." : "Only people with your invite code can join. Your room stays out of Explore.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Divider()
                    Picker("Debate language", selection: $language) { ForEach(debateLanguages, id: \.self) { Text($0) } }.tint(Design.accent)
                }.cardStyle()
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "Choose the ground rules")
                    ForEach(FormatCatalog.presets) { preset in
                        Button { format = preset } label: {
                            HStack(spacing: 12) {
                                Image(systemName: format.id == preset.id ? "largecircle.fill.circle" : "circle").foregroundStyle(Design.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.name).font(.subheadline.bold()).foregroundStyle(.primary)
                                    Text("\(preset.capacity) speakers · ~\(preset.totalDurationSeconds / 60) min").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                    }
                    if !savedFormats.isEmpty {
                        Divider()
                        Text("YOUR SAVED FORMATS").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(savedFormats) { saved in
                            Button { format = saved } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: format.id == saved.id ? "largecircle.fill.circle" : "circle").foregroundStyle(Design.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(saved.name).font(.subheadline.bold()).foregroundStyle(.primary)
                                        Text("\(saved.capacity) speakers · ~\(saved.totalDurationSeconds / 60) min").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }.padding(.vertical, 5)
                            }.buttonStyle(.plain)
                        }
                    }
                    Divider()
                    Button { showCustom = true } label: {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                            Text(format.id.hasPrefix("custom") ? format.name : "Build a custom format").font(.subheadline.bold())
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }.padding(.vertical, 6)
                    }
                }.cardStyle()
                DisclosureGroup("Review speaking order") { TurnSchedule(format: format) }.font(.subheadline.bold())
                ConsentPanel(consent: $consent)
                PrimaryButton(title: "Create \(visibility) room", icon: visibility == "public" ? "globe" : "lock", busy: store.isWorking) {
                    Task { if await store.createRoom(title: title.trimmingCharacters(in: .whitespacesAndNewlines), language: language, format: format, visibility: visibility) { dismiss() } }
                }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).count < 8 || title.utf16.count > 160 || !consent || !format.validate().isEmpty)
                    .accessibilityIdentifier("create.submit")
                if title.utf16.count > 160 { Text("Keep the motion within 160 characters.").font(.caption).foregroundStyle(Design.orange) }
            }.padding(22)
        }.background(Design.background).navigationTitle("Create a room").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showCustom) {
                NavigationStack {
                    CustomFormatView(initial: format.id.hasPrefix("custom") ? format : FormatCatalog.custom()) { edited in
                        do {
                            format = try CustomFormatLibrary.save(edited)
                            savedFormats = CustomFormatLibrary.load()
                        } catch { libraryError = error.localizedDescription }
                    }
                }
            }
            .onAppear { language = store.preferredLanguage; savedFormats = CustomFormatLibrary.load() }
            .alert("Format could not be saved", isPresented: Binding(get: { libraryError != nil }, set: { if !$0 { libraryError = nil } })) {
                Button("OK", role: .cancel) { libraryError = nil }
            } message: { Text(libraryError ?? "") }
    }
}
