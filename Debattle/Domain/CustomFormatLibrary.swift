import Foundation

/// Saved templates are independent of room snapshots. Editing a template cannot change
/// a room that has already been created with an earlier copy.
enum CustomFormatLibrary {
    static let storageKey = "debattle.custom-formats.v1"

    static func load(from defaults: UserDefaults = .standard) -> [DebateFormat] {
        guard let data = defaults.data(forKey: storageKey),
              let formats = try? JSONDecoder().decode([DebateFormat].self, from: data) else { return [] }
        var seen = Set<String>()
        return formats.filter { $0.id.hasPrefix("custom-") && $0.validate().isEmpty && seen.insert($0.id).inserted }
    }

    /// A new custom draft receives a stable ID on first save; edits retain it.
    @discardableResult
    static func save(_ format: DebateFormat, to defaults: UserDefaults = .standard) throws -> DebateFormat {
        let errors = format.validate()
        guard errors.isEmpty else { throw LibraryError.invalidFormat(errors.joined(separator: " ")) }
        var saved = format
        if !saved.id.hasPrefix("custom-") { saved.id = "custom-\(UUID().uuidString.lowercased())" }
        var formats = load(from: defaults)
        formats.removeAll { $0.id == saved.id }
        formats.insert(saved, at: 0)
        defaults.set(try JSONEncoder().encode(formats), forKey: storageKey)
        return saved
    }

    static func remove(id: String, from defaults: UserDefaults = .standard) throws {
        let remaining = load(from: defaults).filter { $0.id != id }
        defaults.set(try JSONEncoder().encode(remaining), forKey: storageKey)
    }

    enum LibraryError: LocalizedError {
        case invalidFormat(String)
        var errorDescription: String? {
            switch self { case .invalidFormat(let description): description }
        }
    }
}
