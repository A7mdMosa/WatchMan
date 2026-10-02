import Foundation

/// One of Claude's usage windows: how much is used and when it resets.
public struct UsageWindow: Codable, Equatable, Sendable {
    public var percent: Double
    public var resetsAt: Date?

    public init(percent: Double, resetsAt: Date?) {
        self.percent = percent
        self.resetsAt = resetsAt
    }

    /// From the status line's `{"used_percentage": 41, "resets_at": 1790967600}` (seconds, or an ISO date).
    static func parse(_ value: Any?) -> UsageWindow? {
        guard let object = value as? [String: Any] else { return nil }
        guard let percent = (object["used_percentage"] ?? object["utilization"]) as? NSNumber else { return nil }
        var resets: Date?
        if let seconds = object["resets_at"] as? NSNumber {
            resets = Date(timeIntervalSince1970: seconds.doubleValue)
        } else if let text = object["resets_at"] as? String {
            resets = ISO8601DateFormatter().date(from: text)
        }
        return UsageWindow(percent: percent.doubleValue, resetsAt: resets)
    }
}

/// Your plan's limits as Claude Code reports them: the current 5-hour session and the week.
public struct PlanUsage: Codable, Equatable, Sendable {
    public var session: UsageWindow?
    public var week: UsageWindow?

    public init(session: UsageWindow?, week: UsageWindow?) {
        self.session = session
        self.week = week
    }

    /// The higher of the two, for one gauge.
    public var peak: Double { max(session?.percent ?? 0, week?.percent ?? 0) }
}

/// What Claude Code gives its status line: the session, how full its context is, and the plan's usage.
public struct StatusLineInfo: Equatable, Sendable {
    public var sessionId: String?
    public var contextPercent: Double?
    /// Nil when the status line carries no plan limits (an API key, or limits not loaded yet).
    public var usage: PlanUsage?

    public init(sessionId: String?, contextPercent: Double?, usage: PlanUsage?) {
        self.sessionId = sessionId
        self.contextPercent = contextPercent
        self.usage = usage
    }

    public static func parse(_ payload: [String: Any]) -> StatusLineInfo {
        let context = (payload["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber
        let limits = payload["rate_limits"] as? [String: Any]
        let session = UsageWindow.parse(limits?["five_hour"])
        let week = UsageWindow.parse(limits?["seven_day"])
        return StatusLineInfo(sessionId: payload["session_id"] as? String,
                              contextPercent: context?.doubleValue,
                              usage: session == nil && week == nil ? nil : PlanUsage(session: session, week: week))
    }

    /// The event name watchman-hook gives status line data on WatchMan's socket.
    public static let eventName = "StatusLine"
}

/// Where a usage window is heading at the pace it has gone since it started.
public enum UsageForecast {
    public static let sessionLength: TimeInterval = 5 * 3600
    public static let weekLength: TimeInterval = 7 * 24 * 3600

    /// When it reaches 100% at that pace, or nil when it won't before it resets (or it's too early to tell).
    public static func runsOut(_ window: UsageWindow, length: TimeInterval, now: Date = Date()) -> Date? {
        guard let rate = rate(window, length: length, now: now), let resets = window.resetsAt, window.percent < 100 else { return nil }
        let full = now.addingTimeInterval((100 - window.percent) / rate)
        return full < resets ? full : nil
    }

    /// The share it will have used when it resets, at that pace.
    public static func percentAtReset(_ window: UsageWindow, length: TimeInterval, now: Date = Date()) -> Double? {
        guard let rate = rate(window, length: length, now: now), let resets = window.resetsAt else { return nil }
        return window.percent + rate * max(0, resets.timeIntervalSince(now))
    }

    /// Percent per second since the window began; nil in its first tenth (too little to go on) or with no use.
    private static func rate(_ window: UsageWindow, length: TimeInterval, now: Date) -> Double? {
        guard let resets = window.resetsAt, window.percent > 0 else { return nil }
        let elapsed = now.timeIntervalSince(resets.addingTimeInterval(-length))
        guard elapsed > length / 10 else { return nil }
        return window.percent / elapsed
    }
}

