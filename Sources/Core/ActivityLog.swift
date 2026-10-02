import Foundation

/// What happened in a session, for the window's timeline: it started, asked you something, finished, or stopped.
public struct ActivityEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case started, asked, finished, failed, limited }

    public var id: UUID
    public var at: Date
    public var sessionId: String
    /// The session's name and colour key then, so the entry still reads right after the session ends.
    public var name: String
    public var colorKey: String
    public var kind: Kind
    public var text: String

    public init(at: Date, sessionId: String, name: String, colorKey: String, kind: Kind, text: String) {
        self.id = UUID()
        self.at = at
        self.sessionId = sessionId
        self.name = name
        self.colorKey = colorKey
        self.kind = kind
        self.text = text
    }
}

/// The last two days of session events, newest last, capped so the file stays small.
public struct ActivityLog: Codable, Equatable, Sendable {
    public private(set) var entries: [ActivityEntry] = []

    public static let keep: TimeInterval = 48 * 3600
    public static let cap = 400

    public init(entries: [ActivityEntry] = []) {
        self.entries = entries
    }

    /// Adds an event; the same kind with the same text right after for the same session is dropped as a repeat.
    public mutating func add(_ entry: ActivityEntry) {
        if let last = entries.last(where: { $0.sessionId == entry.sessionId }),
           last.kind == entry.kind, last.text == entry.text {
            return
        }
        entries.append(entry)
        prune(now: entry.at)
    }

    /// Drops events older than two days, and the oldest beyond the cap.
    public mutating func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.at) > Self.keep }
        if entries.count > Self.cap { entries.removeFirst(entries.count - Self.cap) }
    }

    /// Events within `interval` of `now`, newest first.
    public func recent(within interval: TimeInterval, now: Date = Date()) -> [ActivityEntry] {
        entries.filter { now.timeIntervalSince($0.at) <= interval }.reversed()
    }
}
