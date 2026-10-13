import Foundation

/// A recovery copy is not a room transcript or judging input. Upload acknowledgement
/// may be lost after server acceptance, so this text must never be retried automatically.
struct RecoveredTranscript: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var roomID: String
    var roomTitle: String
    var turnID: String
    var turnLabel: String
    var language: String
    var participantID: String
    var speakerName: String
    var text: String
    var createdAt: Double
}

struct TranscriptRecoveryArchive: Sendable {
    let fileURL: URL
    let maximumRecords: Int
    let maximumBytes: Int

    init(fileURL: URL = URL.applicationSupportDirectory.appendingPathComponent("Debattle", isDirectory: true)
        .appendingPathComponent("transcript-recovery.json"), maximumRecords: Int = 20,
         maximumBytes: Int = 2_000_000) {
        self.fileURL = fileURL
        self.maximumRecords = maximumRecords
        self.maximumBytes = maximumBytes
    }

    func load() throws -> [RecoveredTranscript] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= maximumBytes else { throw RecoveryError.storageFull }
        let data = try Data(contentsOf: fileURL)
        let records: [RecoveredTranscript]
        do { records = try JSONDecoder().decode([RecoveredTranscript].self, from: data) }
        catch { throw RecoveryError.unreadableArchive }
        guard records.count <= maximumRecords, Set(records.map(\.id)).count == records.count,
              records.allSatisfy(Self.isValid) else { throw RecoveryError.unreadableArchive }
        return records
    }

    /// Bounds reject a new recovery rather than silently evicting an older unsent speech.
    @discardableResult
    func preserve(_ record: RecoveredTranscript) throws -> [RecoveredTranscript] {
        guard Self.isValid(record) else { throw RecoveryError.invalidRecord }
        var records = try load()
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        guard records.count <= maximumRecords else { throw RecoveryError.storageFull }
        try write(records)
        return records
    }

    @discardableResult
    func remove(id: String) throws -> [RecoveredTranscript] {
        let records = try load().filter { $0.id != id }
        try write(records)
        return records
    }

    private func write(_ records: [RecoveredTranscript]) throws {
        let data = try JSONEncoder().encode(records)
        guard data.count <= maximumBytes else { throw RecoveryError.storageFull }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func isValid(_ record: RecoveredTranscript) -> Bool {
        !record.id.isEmpty && !record.roomID.isEmpty && !record.turnID.isEmpty
            && !record.participantID.isEmpty && record.createdAt.isFinite
            && !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum RecoveryError: LocalizedError, Equatable {
        case storageFull
        case unreadableArchive
        case invalidRecord

        var errorDescription: String? {
            switch self {
            case .storageFull: "Local speech recovery is full. Copy and delete older recovered speeches in You to make space. Existing copies were kept."
            case .unreadableArchive: "The local speech recovery file could not be read. It was left unchanged."
            case .invalidRecord: "This speech could not be stored as a local recovery copy."
            }
        }
    }
}
