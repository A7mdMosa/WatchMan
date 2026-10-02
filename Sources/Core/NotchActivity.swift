import Foundation

/// The one line the closed notch shows on its left: what is happening right now, most urgent first.
public struct NotchActivity: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// You just acted from WatchMan ("Sent", "Allowed"): shown for a moment as confirmation.
        case feedback
        /// WatchMan can't work properly (hooks missing, no socket).
        case problem
        /// A session stopped with an error and needs a retry.
        case failed
        /// A session hit Claude's usage limit.
        case limited
        case needsYou
        /// A result that arrived in the last few seconds.
        case finished
        case working
        /// A moment worth a line but not a message: a session started, may be stuck, usage passed 80%, you're
        /// back. Shown for a few seconds while the ball reacts.
        case news(Tone)
    }

    /// The colour a news line takes.
    public enum Tone: Equatable, Sendable { case started, finished, warning, error, limit, info }

    public var kind: Kind
    public var sessionId: String
    public var name: String
    /// The full line, e.g. "Lumen needs you", "Trailmap · Edit main.dart", "Sent · Trailmap".
    public var text: String
    /// What's left when the full line doesn't fit: the name, or the verb for feedback.
    public var short: String

    public init(kind: Kind, sessionId: String, name: String, text: String, short: String) {
        self.kind = kind
        self.sessionId = sessionId
        self.name = name
        self.text = text
        self.short = short
    }

    /// How long a new result stays on the left before the line moves on.
    public static let freshFor: TimeInterval = 10
    /// The longest step text shown for a working session.
    public static let maxStepLength = 30

    public static func needsYou(_ sessionId: String, name: String) -> NotchActivity {
        NotchActivity(kind: .needsYou, sessionId: sessionId, name: name, text: "\(name) needs you", short: name)
    }

    public static func finished(_ sessionId: String, name: String) -> NotchActivity {
        NotchActivity(kind: .finished, sessionId: sessionId, name: name, text: "\(name) finished", short: name)
    }

    public static func news(_ text: String, short: String, tone: Tone, sessionId: String = "") -> NotchActivity {
        NotchActivity(kind: .news(tone), sessionId: sessionId, name: short, text: text, short: short)
    }

    public static func working(_ session: Session, name: String? = nil) -> NotchActivity {
        var step = (session.lastStep ?? "Working").replacingOccurrences(of: " · ", with: " ")
        if step.count > maxStepLength { step = String(step.prefix(maxStepLength - 1)) + "…" }
        let name = name ?? session.displayName
        return NotchActivity(kind: .working, sessionId: session.id, name: name, text: "\(name) · \(step)", short: name)
    }

    public static func problem(_ text: String) -> NotchActivity {
        NotchActivity(kind: .problem, sessionId: "", name: "WatchMan", text: text, short: "WatchMan")
    }

    public static func feedback(_ sessionId: String, name: String, verb: String) -> NotchActivity {
        NotchActivity(kind: .feedback, sessionId: sessionId, name: name, text: "\(verb) · \(name)", short: verb)
    }

    /// Working sessions in a stable order (by when they started), so the rotation doesn't jump around.
    public static func working(in sessions: [Session]) -> [Session] {
        sessions.filter { $0.status == .working }
            .sorted { $0.statusSince != $1.statusSince ? $0.statusSince < $1.statusSince : $0.id < $1.id }
    }

    /// The line to show. `sessions` is in display order; `rotation` picks which working session to show
    /// when several are working.
    /// `name` gives a session's name on the notch (default: its own name).
    public static func pick(_ sessions: [Session], feedback: NotchActivity?, problem: String? = nil, now: Date,
                            rotation: Int, name: (Session) -> String = { $0.displayName }) -> NotchActivity? {
        if let feedback { return feedback }
        if let problem { return .problem(problem) }
        if let limited = sessions.first(where: \.rateLimited) {
            let name = name(limited)
            let resets = limited.limitReset.map { " · resets \($0)" } ?? ""
            return NotchActivity(kind: .limited, sessionId: limited.id, name: name, text: "\(name) hit the usage limit\(resets)", short: name)
        }
        if let broken = sessions.first(where: \.failed) {
            let name = name(broken)
            return NotchActivity(kind: .failed, sessionId: broken.id, name: name, text: "\(name) stopped with an error", short: name)
        }
        if let waiting = sessions.first(where: { $0.status.isNeedsYou }) {
            return needsYou(waiting.id, name: name(waiting))
        }
        if let fresh = sessions.filter({ $0.isUnseenResult && now.timeIntervalSince($0.statusSince) < freshFor })
            .max(by: { $0.statusSince < $1.statusSince }) {
            return finished(fresh.id, name: name(fresh))
        }
        let busy = working(in: sessions)
        guard !busy.isEmpty else { return nil }
        let session = busy[((rotation % busy.count) + busy.count) % busy.count]
        return working(session, name: name(session))
    }

    /// When the line should be picked again even if nothing else changes (a new result stops being new).
    public static func expiry(of activity: NotchActivity?, in sessions: [Session]) -> Date? {
        guard let activity, activity.kind == .finished,
              let session = sessions.first(where: { $0.id == activity.sessionId }) else { return nil }
        return session.statusSince.addingTimeInterval(freshFor)
    }
}

/// The notch island's mood, which drives how it moves and the light on its edge.
public enum NotchMood: Equatable, Sendable {
    case quiet, asleep, working, needsYou, done, worried

    /// How long without any activity before the island goes to sleep.
    public static let sleepAfter: TimeInterval = 20 * 60

    /// `sessions` in display order; `problem`: WatchMan can't hear Claude Code.
    public static func pick(_ sessions: [Session], problem: Bool, now: Date) -> NotchMood {
        if problem || sessions.contains(where: { $0.failed && !$0.rateLimited }) { return .worried }
        if sessions.contains(where: { $0.status.isNeedsYou || $0.rateLimited }) { return .needsYou }
        if sessions.contains(where: { $0.isUnseenResult && now.timeIntervalSince($0.statusSince) < NotchActivity.freshFor }) {
            return .done
        }
        if sessions.contains(where: { $0.status == .working }) { return .working }
        guard let latest = sessions.map(\.lastActivity).max(), now.timeIntervalSince(latest) < sleepAfter else { return .asleep }
        return .quiet
    }

    /// When the mood changes by itself if nothing else happens: a new result stops being new, or the island falls asleep.
    public static func nextChange(_ sessions: [Session], now: Date) -> Date? {
        var dates: [Date] = sessions.filter(\.isUnseenResult).map { $0.statusSince.addingTimeInterval(NotchActivity.freshFor) }
        if let latest = sessions.map(\.lastActivity).max() { dates.append(latest.addingTimeInterval(sleepAfter)) }
        return dates.filter { $0 > now }.min()
    }
}
