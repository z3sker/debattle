import Foundation

struct DebateTeam: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    /// Teams on the same bench share `government` or `opposition`.
    var side: String
}

struct SpeechTurn: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var teamID: String
    /// Zero-based seat within the team.
    var speakerIndex: Int
    var durationSeconds: Int
    /// `substantive` or `reply`. Replies never allow POIs.
    var kind: String
}

struct DebateFormat: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var summary: String
    var teams: [DebateTeam]
    var speakersPerTeam: Int
    var preparationSeconds: Int
    var turns: [SpeechTurn]
    var poiEnabled: Bool
    var protectedSeconds: Int
    var poiDurationSeconds: Int
    var graceSeconds: Int

    var capacity: Int {
        guard (1...4).contains(speakersPerTeam), teams.count <= 4 else { return 0 }
        return teams.count * speakersPerTeam
    }

    /// Preparation plus scheduled speeches, including each speech's grace period.
    var totalDurationSeconds: Int {
        let total = turns.reduce(Double(preparationSeconds)) {
            $0 + Double($1.durationSeconds) + Double(graceSeconds)
        }
        // Models can be decoded from an untrusted server; malformed arithmetic must not trap.
        return Int(min(Double(Int.max / 2), max(0, total)))
    }

    var speechDurationSeconds: Int {
        turns.reduce(0) { result, turn in
            let sum = result.addingReportingOverflow(max(0, turn.durationSeconds))
            return sum.overflow ? Int.max : sum.partialValue
        }
    }

    func validate() -> [String] {
        var errors: [String] = []
        if !Self.validID(id) { errors.append("Format IDs must contain 1–80 letters, numbers, dots, underscores, or hyphens.") }
        if !Self.validText(name, max: 80) { errors.append("Give the format a name of 1–80 characters.") }
        if !Self.validText(summary, max: 500, allowEmpty: true) { errors.append("Keep the format description within 500 characters.") }
        if !(2...4).contains(teams.count) { errors.append("Choose between 2 and 4 teams.") }
        if !(1...4).contains(speakersPerTeam) { errors.append("Choose between 1 and 4 speakers per team.") }
        if !(0...3_600).contains(preparationSeconds) { errors.append("Preparation must be between 0 and 60 minutes.") }
        if !(1...32).contains(turns.count) { errors.append("Schedule between 1 and 32 speeches.") }
        if !(0...60).contains(graceSeconds) { errors.append("Grace time must be between 0 and 60 seconds.") }
        if !(0...300).contains(protectedSeconds) { errors.append("Protected time must be between 0 and 300 seconds.") }
        if !(5...30).contains(poiDurationSeconds) { errors.append("A point of information must last between 5 and 30 seconds.") }
        if totalDurationSeconds > 14_400 { errors.append("The debate, including preparation and grace, cannot exceed 4 hours.") }
        let teamIDs = Set(teams.map(\.id))
        if teamIDs.count != teams.count { errors.append("Each team needs a unique ID.") }
        if Set(turns.map(\.id)).count != turns.count { errors.append("Each speech needs a unique ID.") }
        if teams.contains(where: { !Self.validID($0.id) || !Self.validText($0.name, max: 60) }) {
            errors.append("Each team needs a valid ID and a name of 1–60 characters.")
        }
        if teams.contains(where: { !["government", "opposition"].contains($0.side) }) {
            errors.append("Each team must take the government or opposition side.")
        }
        if Set(teams.map(\.side)) != Set(["government", "opposition"]) {
            errors.append("Include teams on both sides of the motion.")
        }
        var hasReachedReply = false
        var replyTeams = Set<String>()
        var scheduledSeats = Set<String>()
        for turn in turns {
            let label = turn.label.isEmpty ? "Speech" : turn.label
            if !Self.validID(turn.id) || !Self.validText(turn.label, max: 80) {
                errors.append("Each speech needs a valid ID and a label of 1–80 characters.")
            }
            if !teamIDs.contains(turn.teamID) { errors.append("\(label) refers to a missing team.") }
            if turn.speakerIndex < 0 || turn.speakerIndex >= speakersPerTeam {
                errors.append("\(label) refers to a missing speaker seat.")
            }
            if !(30...900).contains(turn.durationSeconds) { errors.append("\(label) must last between 30 seconds and 15 minutes.") }
            if !["substantive", "reply"].contains(turn.kind) { errors.append("\(label) has an unsupported speech type.") }
            if turn.kind == "reply" {
                hasReachedReply = true
                if turn.speakerIndex > 1 { errors.append("Only a team's first or second speaker can deliver its reply.") }
                if !replyTeams.insert(turn.teamID).inserted { errors.append("Each team may have only one reply speech.") }
                if !scheduledSeats.contains("\(turn.teamID):\(turn.speakerIndex)") {
                    errors.append("A reply speaker must give a substantive speech first.")
                }
            } else if turn.kind == "substantive" {
                scheduledSeats.insert("\(turn.teamID):\(turn.speakerIndex)")
                if hasReachedReply { errors.append("Substantive speeches must come before reply speeches.") }
                if poiEnabled, protectedSeconds >= 0,
                   Double(turn.durationSeconds) <= Double(protectedSeconds) * 2 {
                    errors.append("\(label) needs time for points of information between its protected periods.")
                }
            }
        }
        if (1...4).contains(speakersPerTeam) {
            for team in teams {
                for seat in 0..<speakersPerTeam where !scheduledSeats.contains("\(team.id):\(seat)") {
                    errors.append("\(team.name), speaker \(seat + 1), needs a substantive speech.")
                }
            }
        }
        // Preserve deterministic ordering while collapsing duplicate messages.
        var seen = Set<String>()
        return errors.filter { seen.insert($0).inserted }
    }

    private static func validID(_ value: String) -> Bool {
        !["__proto__", "constructor", "prototype"].contains(value)
            && value.range(of: "^[a-zA-Z0-9_.-]{1,80}$", options: .regularExpression) != nil
    }

    private static func validText(_ value: String, max: Int, allowEmpty: Bool = false) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return (allowEmpty || !normalized.isEmpty) && normalized.utf16.count <= max
            && !normalized.unicodeScalars.contains { scalar in
                scalar.value <= 8 || scalar.value == 11 || scalar.value == 12
                    || (14...31).contains(scalar.value) || scalar.value == 127
            }
    }
}

struct Participant: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var displayName: String
    var teamID: String?
    var seatIndex: Int?
    var isReady: Bool
    var isMuted: Bool

    init(id: String, displayName: String, teamID: String? = nil, seatIndex: Int? = nil,
         isReady: Bool = false, isMuted: Bool = true) {
        self.id = id; self.displayName = displayName; self.teamID = teamID
        self.seatIndex = seatIndex; self.isReady = isReady; self.isMuted = isMuted
    }

    private enum CodingKeys: String, CodingKey { case id, displayName, teamID, seatIndex, isReady, isMuted }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        teamID = try values.decodeIfPresent(String.self, forKey: .teamID)
        seatIndex = try values.decodeIfPresent(Int.self, forKey: .seatIndex)
        isReady = try values.decodeIfPresent(Bool.self, forKey: .isReady) ?? false
        isMuted = try values.decodeIfPresent(Bool.self, forKey: .isMuted) ?? true
    }
}

struct TranscriptSegment: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var participantID: String
    var turnID: String
    var text: String
    var createdAt: Double
}

struct DebateRoom: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var language: String
    var format: DebateFormat
    var visibility: String
    /// `waiting`, `preparing`, `live`, or `finished`. Pause is represented by pausedRemainingSeconds.
    var status: String
    var hostID: String
    var participants: [Participant]
    var createdAt: Double
    var currentTurnIndex: Int
    var phaseEndsAt: Double?
    var pausedRemainingSeconds: Double?
    var inviteCode: String?
    var transcript: [TranscriptSegment]
    var poiSpeakerID: String?
    var poiEndsAt: Double?
    var revision: Int
    var debateParticipants: [Participant]
    var poiRequests: [String]
    var cloudConsentParticipantIDs: [String]

    init(id: String, title: String, language: String, format: DebateFormat, visibility: String = "public",
         status: String = "waiting", hostID: String, participants: [Participant] = [],
         createdAt: Double = Date().timeIntervalSince1970, currentTurnIndex: Int = 0,
         phaseEndsAt: Double? = nil, pausedRemainingSeconds: Double? = nil, inviteCode: String? = nil,
         transcript: [TranscriptSegment] = [], poiSpeakerID: String? = nil, poiEndsAt: Double? = nil,
         poiRequests: [String] = [], revision: Int = 0, debateParticipants: [Participant] = [], cloudConsentParticipantIDs: [String] = []) {
        self.id = id; self.title = title; self.language = language; self.format = format
        self.visibility = visibility; self.status = status; self.hostID = hostID
        self.participants = participants; self.createdAt = createdAt; self.currentTurnIndex = currentTurnIndex
        self.phaseEndsAt = phaseEndsAt; self.pausedRemainingSeconds = pausedRemainingSeconds
        self.inviteCode = inviteCode; self.transcript = transcript
        self.poiSpeakerID = poiSpeakerID; self.poiEndsAt = poiEndsAt
        self.poiRequests = poiRequests
        self.revision = revision
        self.debateParticipants = debateParticipants
        self.cloudConsentParticipantIDs = cloudConsentParticipantIDs
    }

    var currentTurn: SpeechTurn? {
        guard format.turns.indices.contains(currentTurnIndex) else { return nil }
        return format.turns[currentTurnIndex]
    }

    var currentSpeaker: Participant? {
        guard let currentTurn else { return nil }
        return DebateRules.speaker(for: currentTurn, in: self)
    }

    var occupiedSeats: Int {
        let seatKeys = participants.compactMap { participant -> String? in
            guard let teamID = participant.teamID, let seat = participant.seatIndex,
                  format.teams.contains(where: { $0.id == teamID }),
                  seat >= 0, seat < format.speakersPerTeam else { return nil }
            return "\(teamID):\(seat)"
        }
        return Set(seatKeys).count
    }

    var availableSeats: Int { max(0, format.capacity - occupiedSeats) }
    var isFull: Bool { format.capacity > 0 && occupiedSeats == format.capacity }
    var isPaused: Bool { pausedRemainingSeconds != nil }

    private enum CodingKeys: String, CodingKey {
        case id, title, language, format, visibility, status, hostID, participants, createdAt
        case currentTurnIndex, phaseEndsAt, pausedRemainingSeconds, inviteCode, transcript, poiSpeakerID, poiEndsAt, poiRequests, revision, debateParticipants, cloudConsentParticipantIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        language = try values.decode(String.self, forKey: .language)
        format = try values.decode(DebateFormat.self, forKey: .format)
        visibility = try values.decode(String.self, forKey: .visibility)
        status = try values.decode(String.self, forKey: .status)
        hostID = try values.decode(String.self, forKey: .hostID)
        participants = try values.decodeIfPresent([Participant].self, forKey: .participants) ?? []
        createdAt = try values.decode(Double.self, forKey: .createdAt)
        currentTurnIndex = try values.decodeIfPresent(Int.self, forKey: .currentTurnIndex) ?? 0
        phaseEndsAt = try values.decodeIfPresent(Double.self, forKey: .phaseEndsAt)
        pausedRemainingSeconds = try values.decodeIfPresent(Double.self, forKey: .pausedRemainingSeconds)
        inviteCode = try values.decodeIfPresent(String.self, forKey: .inviteCode)
        transcript = try values.decodeIfPresent([TranscriptSegment].self, forKey: .transcript) ?? []
        poiSpeakerID = try values.decodeIfPresent(String.self, forKey: .poiSpeakerID)
        poiEndsAt = try values.decodeIfPresent(Double.self, forKey: .poiEndsAt)
        poiRequests = try values.decodeIfPresent([String].self, forKey: .poiRequests) ?? []
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        debateParticipants = try values.decodeIfPresent([Participant].self, forKey: .debateParticipants) ?? []
        cloudConsentParticipantIDs = try values.decodeIfPresent([String].self, forKey: .cloudConsentParticipantIDs) ?? []
    }
}
