import Foundation

/// Transcripts can be large; store the journal as a protected file instead of preferences.
enum LocalDebateArchive {
    private static var file: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Debattle", isDirectory: true).appendingPathComponent("journal.json")
    }
    static func load() -> [DebateRoom] {
        if let data = try? Data(contentsOf: file), let rooms = try? JSONDecoder().decode([DebateRoom].self, from: data) { return rooms }
        // Migrate the first development build's preference-based archive without losing data.
        guard let data = UserDefaults.standard.data(forKey: "completedDebates"),
              let rooms = try? JSONDecoder().decode([DebateRoom].self, from: data) else { return [] }
        if (try? save(rooms)) != nil { UserDefaults.standard.removeObject(forKey: "completedDebates") }
        return rooms
    }
    static func save(_ rooms: [DebateRoom]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(rooms.prefix(20))).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func clear() throws {
        UserDefaults.standard.removeObject(forKey: "completedDebates")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
