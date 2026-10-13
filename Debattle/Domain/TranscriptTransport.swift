import Foundation

/// JavaScript measures string payload limits in UTF-16 code units. Splitting at
/// Swift Character boundaries preserves both the words and composed Unicode text.
enum TranscriptTransport {
    static func chunks(_ text: String, maximumUTF16Units: Int = 3_000) throws -> [String] {
        guard maximumUTF16Units > 0 else { throw ChunkError.invalidLimit }
        var chunks: [String] = []
        var current = ""
        var length = 0
        for character in text {
            let units = String(character).utf16.count
            guard units <= maximumUTF16Units else { throw ChunkError.oversizedCharacter }
            if length + units > maximumUTF16Units {
                chunks.append(current)
                current = ""
                length = 0
            }
            current.append(character)
            length += units
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
    enum ChunkError: LocalizedError {
        case invalidLimit, oversizedCharacter
        var errorDescription: String? { "The transcript contains a text sequence too large to upload safely." }
    }
}
