import Foundation
import WatchManCore

/// What the Live Activity shows: the session it's about, what else is going on in a few words, and the counts,
/// from the latest Glance.
struct LiveGlance: Codable, Hashable, Sendable {
    var focus: Glance.Session?
    /// The next session that waits on you, besides the one shown: "Harbor Web asks", with "+1" for more.
    var next: String?
    /// The first result not read yet.
    var newResult: String?
    var waiting: Int
    var working: Int
    var newResults: Int
    var sessionPercent: Double?
    var weekPercent: Double?
    /// The prompt you answered (its session and `Glance.Prompt.key`), until the Mac catches up.
    var sentFor: String?
    var sentPrompt: String?
    /// Nothing has worked or waited since then; the activity ends a while later.
    var quietSince: Date?
    /// The Dynamic Island is turned off in Settings: its closed island stays plain.
    var plainIsland: Bool?

    init(_ glance: Glance, sentFor: String? = nil, sentPrompt: String? = nil, quietSince: Date? = nil) {
        focus = glance.focus
        let others = glance.waiting.filter { $0.id != glance.focus?.id }
        next = others.first.map { session in
            let what = session.prompt?.heading ?? (session.state == .limited ? "\(session.name) hit the usage limit"
                : session.state == .failed ? "\(session.name) stopped" : "\(session.name) needs you")
            return others.count > 1 ? "\(what) +\(others.count - 1)" : what
        }
        newResult = glance.newResults.first?.id
        waiting = glance.waiting.count
        working = glance.working.count
        newResults = glance.newResults.count
        sessionPercent = glance.sessionPercent
        weekPercent = glance.weekPercent
        // A "Sent" holds only while that same prompt is still the one shown
        let same = focus?.id == sentFor && focus?.prompt?.key == sentPrompt
        self.sentFor = same ? sentFor : nil
        self.sentPrompt = same ? sentPrompt : nil
        self.quietSince = quietSince
    }

    /// You answered the prompt shown, and the Mac hasn't caught up yet.
    var answered: Bool { sentFor != nil && sentFor == focus?.id && sentPrompt == focus?.prompt?.key }

    /// The ball's mood: the focus session's state, or all done.
    var mood: SessionSnapshot.State? { focus?.state }

    /// What else is going on, in a few words: "Next: Harbor Web asks · 2 more working · 1 new".
    var others: String? {
        var parts: [String] = []
        if let next { parts.append("Next: " + next) }
        let more = working - (focus?.state == .working ? 1 : 0)
        if more > 0 { parts.append(focus?.state == .working ? "\(more) more working" : "\(more) working") }
        // With nothing else shown, the headline already says how many new results there are
        if newResults > 0, focus != nil { parts.append("\(newResults) new") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Where a tap on the activity goes: the session it shows, else a new result, else the app.
    var link: URL {
        if let id = focus?.id ?? newResult { return PhoneLinks.session(id) }
        return PhoneLinks.app
    }
}

extension Glance {
    /// The sessions the README's preview shows, for the widget gallery, previews and design snapshots.
    static func sample(now: Date = Date()) -> Glance {
        func session(_ id: String, _ name: String, _ state: SessionSnapshot.State, _ detail: String, ago: TimeInterval,
                     prompt: Prompt? = nil, unseen: Bool = false, tasks: (Int, Int) = (0, 0)) -> Session {
            Session(id: id, name: name, colorKey: name, state: state, detail: detail, since: now.addingTimeInterval(-ago),
                    updated: now.addingTimeInterval(-ago / 4), unseen: unseen, prompt: prompt,
                    tasksDone: tasks.0, tasksTotal: tasks.1)
        }
        return Glance(sessions: [
            session("k", "Lumen", .needsYou, "Build the release APK", ago: 480,
                    prompt: Prompt(kind: .permission, heading: "Lumen wants to run",
                                   text: "flutter build apk --release --split-per-abi", choices: [])),
            session("a", "Harbor Web", .needsYou, "Which icon set should I use?", ago: 180,
                    prompt: Prompt(kind: .question, heading: "Harbor Web asks", text: "Which icon set should I use?",
                                   choices: ["Lucide", "Heroicons", "Phosphor"])),
            session("m", "Trailmap", .working, "Edit · workout_screen.dart", ago: 120, tasks: (2, 5)),
            session("w", "WatchMan", .working, "Run · xcodebuild test", ago: 300),
            session("c", "Shipyard", .done, "Build passed on Shipyard.", ago: 600, unseen: true),
        ], sessionPercent: 23, weekPercent: 41, macName: "MacBook Pro", updated: now)
    }
}
