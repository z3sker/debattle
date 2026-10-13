import Foundation

enum DebateRules {
    static func speaker(for turn: SpeechTurn, in room: DebateRoom) -> Participant? {
        room.participants.first { $0.teamID == turn.teamID && $0.seatIndex == turn.speakerIndex }
    }

    static func participant(_ participant: Participant, occupiesValidSeatIn room: DebateRoom) -> Bool {
        guard let teamID = participant.teamID, let seatIndex = participant.seatIndex else { return false }
        return room.format.teams.contains { $0.id == teamID }
            && seatIndex >= 0 && seatIndex < room.format.speakersPerTeam
    }

    static func canStart(_ room: DebateRoom) -> Bool {
        guard room.status == "waiting", room.format.validate().isEmpty, room.isFull,
              room.participants.contains(where: { $0.id == room.hostID }) else { return false }
        let seated = room.participants.filter { participant($0, occupiesValidSeatIn: room) }
        return seated.count == room.format.capacity && seated.allSatisfy(\.isReady)
            && Set(seated.map(\.id)).count == seated.count
    }

    static func remainingSeconds(in room: DebateRoom, at now: Double = Date().timeIntervalSince1970) -> Int {
        Int(ceil(remainingTime(in: room, at: now)))
    }

    static func elapsedSpeechSeconds(in room: DebateRoom, at now: Double = Date().timeIntervalSince1970) -> Double {
        guard room.status == "live", let turn = room.currentTurn,
              room.phaseEndsAt != nil || room.pausedRemainingSeconds != nil else { return 0 }
        let allocated = Double(turn.durationSeconds) + Double(room.format.graceSeconds)
        return max(0, min(allocated, allocated - remainingTime(in: room, at: now)))
    }

    static func canOfferPOI(participantID: String, in room: DebateRoom,
                            at now: Double = Date().timeIntervalSince1970) -> Bool {
        guard room.status == "live", !room.isPaused, room.format.poiEnabled,
              room.phaseEndsAt != nil, remainingTime(in: room, at: now) > 0,
              let turn = room.currentTurn, turn.kind == "substantive",
              let participant = room.participants.first(where: { $0.id == participantID }),
              self.participant(participant, occupiesValidSeatIn: room),
              let offeringTeam = room.format.teams.first(where: { $0.id == participant.teamID }),
              let speakingTeam = room.format.teams.first(where: { $0.id == turn.teamID }),
              offeringTeam.side != speakingTeam.side,
              room.currentSpeaker != nil else { return false }
        if room.poiSpeakerID != nil, let deadline = room.poiEndsAt, deadline > now { return false }
        let elapsed = elapsedSpeechSeconds(in: room, at: now)
        return elapsed >= Double(room.format.protectedSeconds)
            && elapsed < Double(turn.durationSeconds) - Double(room.format.protectedSeconds)
    }

    static func eligiblePOISpeakers(in room: DebateRoom, at now: Double = Date().timeIntervalSince1970) -> [Participant] {
        room.participants.filter { canOfferPOI(participantID: $0.id, in: room, at: now) }
    }

    /// During an accepted POI, only its speaker has the floor. The main clock keeps running.
    static func canSpeak(participantID: String, in room: DebateRoom,
                         at now: Double = Date().timeIntervalSince1970) -> Bool {
        guard room.status == "live", !room.isPaused, remainingTime(in: room, at: now) > 0 else { return false }
        if let poiSpeakerID = room.poiSpeakerID, let deadline = room.poiEndsAt, deadline > now {
            return participantID == poiSpeakerID
        }
        return room.currentSpeaker?.id == participantID
    }

    static func isInGracePeriod(_ room: DebateRoom, at now: Double = Date().timeIntervalSince1970) -> Bool {
        guard room.status == "live", let turn = room.currentTurn, room.format.graceSeconds > 0 else { return false }
        return elapsedSpeechSeconds(in: room, at: now) >= Double(turn.durationSeconds)
            && remainingTime(in: room, at: now) > 0
    }

    static func clockText(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        return String(format: "%02d:%02d", safe / 60, safe % 60)
    }

    private static func remainingTime(in room: DebateRoom, at now: Double) -> Double {
        guard ["preparing", "live"].contains(room.status), now.isFinite else { return 0 }
        let remaining = room.pausedRemainingSeconds ?? room.phaseEndsAt.map { $0 - now } ?? 0
        guard remaining.isFinite else { return 0 }
        return max(0, min(86_400, remaining))
    }
}
