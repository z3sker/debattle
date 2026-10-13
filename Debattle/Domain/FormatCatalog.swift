import Foundation

enum FormatCatalog {
    static let duel = DebateFormat(
        id: "duel", name: "Quick Duel", summary: "One motion. Two voices. A focused first debate.",
        teams: twoTeams, speakersPerTeam: 1, preparationSeconds: 60,
        turns: [
            turn("gov-open", "Government opening", "gov", 0, 180),
            turn("opp-open", "Opposition opening", "opp", 0, 180),
            turn("gov-close", "Government closing", "gov", 0, 120),
            turn("opp-close", "Opposition closing", "opp", 0, 120)
        ], poiEnabled: false, protectedSeconds: 0, poiDurationSeconds: 15, graceSeconds: 15
    )

    static let britishParliamentary = DebateFormat(
        id: "british-parliamentary", name: "British Parliamentary",
        summary: "Four teams, eight speakers. Opening cases, extensions, and a final clash.",
        teams: [
            DebateTeam(id: "og", name: "Opening Government", side: "government"),
            DebateTeam(id: "oo", name: "Opening Opposition", side: "opposition"),
            DebateTeam(id: "cg", name: "Closing Government", side: "government"),
            DebateTeam(id: "co", name: "Closing Opposition", side: "opposition")
        ], speakersPerTeam: 2, preparationSeconds: 900,
        turns: [
            turn("pm", "Prime Minister", "og", 0, 420),
            turn("lo", "Leader of Opposition", "oo", 0, 420),
            turn("dpm", "Deputy Prime Minister", "og", 1, 420),
            turn("dlo", "Deputy Leader of Opposition", "oo", 1, 420),
            turn("mg", "Member of Government", "cg", 0, 420),
            turn("mo", "Member of Opposition", "co", 0, 420),
            turn("gw", "Government Whip", "cg", 1, 420),
            turn("ow", "Opposition Whip", "co", 1, 420)
        ], poiEnabled: true, protectedSeconds: 60, poiDurationSeconds: 15, graceSeconds: 15
    )

    static let worldSchools = DebateFormat(
        id: "world-schools", name: "World Schools",
        summary: "Three speakers a side, with short replies to make the case for your team.",
        teams: [DebateTeam(id: "gov", name: "Proposition", side: "government"),
                DebateTeam(id: "opp", name: "Opposition", side: "opposition")],
        speakersPerTeam: 3, preparationSeconds: 3_600,
        turns: [
            turn("gov-1", "First Proposition", "gov", 0, 480),
            turn("opp-1", "First Opposition", "opp", 0, 480),
            turn("gov-2", "Second Proposition", "gov", 1, 480),
            turn("opp-2", "Second Opposition", "opp", 1, 480),
            turn("gov-3", "Third Proposition", "gov", 2, 480),
            turn("opp-3", "Third Opposition", "opp", 2, 480),
            turn("opp-reply", "Opposition reply", "opp", 0, 240, kind: "reply"),
            turn("gov-reply", "Proposition reply", "gov", 0, 240, kind: "reply")
        ], poiEnabled: true, protectedSeconds: 60, poiDurationSeconds: 15, graceSeconds: 15
    )

    static let asianParliamentary = DebateFormat(
        id: "asian-parliamentary", name: "Asian Parliamentary",
        summary: "Two teams of three. Build, challenge, and close with a reply.",
        teams: twoTeams, speakersPerTeam: 3, preparationSeconds: 1_800,
        turns: [
            turn("pm", "Prime Minister", "gov", 0, 420),
            turn("lo", "Leader of Opposition", "opp", 0, 420),
            turn("dpm", "Deputy Prime Minister", "gov", 1, 420),
            turn("dlo", "Deputy Leader of Opposition", "opp", 1, 420),
            turn("gw", "Government Whip", "gov", 2, 420),
            turn("ow", "Opposition Whip", "opp", 2, 420),
            turn("opp-reply", "Opposition reply", "opp", 0, 240, kind: "reply"),
            turn("gov-reply", "Government reply", "gov", 0, 240, kind: "reply")
        ], poiEnabled: true, protectedSeconds: 60, poiDurationSeconds: 15, graceSeconds: 15
    )

    static let presets: [DebateFormat] = [duel, britishParliamentary, worldSchools, asianParliamentary]

    /// Produces an editable round-robin speech schedule. Each round includes every speaker.
    /// Invalid inputs produce a format rejected by validate(), never an unbounded allocation.
    static func custom(teamCount: Int = 2, speakersPerTeam: Int = 2,
                       preparationSeconds: Int = 300, speechDurationSeconds: Int = 180,
                       rounds: Int = 1, poiEnabled: Bool = false, protectedSeconds: Int = 30,
                       poiDurationSeconds: Int = 15, graceSeconds: Int = 15) -> DebateFormat {
        let safeTeamCount = min(5, max(0, teamCount))
        let teams = (0..<safeTeamCount).map { index in
            DebateTeam(id: "team-\(index + 1)", name: "Team \(index + 1)",
                       side: index.isMultiple(of: 2) ? "government" : "opposition")
        }
        var turns: [SpeechTurn] = []
        if (1...4).contains(speakersPerTeam), (1...16).contains(rounds), (2...4).contains(teamCount) {
            schedule: for round in 0..<rounds {
                for speaker in 0..<speakersPerTeam {
                    for team in teams {
                        turns.append(turn("round-\(round + 1)-\(team.id)-\(speaker)",
                                          "\(team.name) · Speaker \(speaker + 1) · Round \(round + 1)",
                                          team.id, speaker, speechDurationSeconds))
                        if turns.count > 32 { break schedule }
                    }
                }
            }
        }
        return DebateFormat(id: "custom", name: "Custom format", summary: "Your teams. Your order. Your rules.",
                            teams: teams, speakersPerTeam: speakersPerTeam,
                            preparationSeconds: preparationSeconds, turns: turns, poiEnabled: poiEnabled,
                            protectedSeconds: protectedSeconds, poiDurationSeconds: poiDurationSeconds,
                            graceSeconds: graceSeconds)
    }

    private static let twoTeams = [DebateTeam(id: "gov", name: "Government", side: "government"),
                                   DebateTeam(id: "opp", name: "Opposition", side: "opposition")]

    private static func turn(_ id: String, _ label: String, _ teamID: String,
                             _ speakerIndex: Int, _ seconds: Int, kind: String = "substantive") -> SpeechTurn {
        SpeechTurn(id: id, label: label, teamID: teamID, speakerIndex: speakerIndex,
                   durationSeconds: seconds, kind: kind)
    }
}
