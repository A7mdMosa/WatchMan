import Foundation

// What the iPhone can see of the Mac beyond the sessions (its WatchMan settings, projects, earlier chats, work not
// saved yet, memory), and what it can ask the Mac to do with them. They travel in the Mac's status record and in
// the phone's commands, through the private iCloud database.

/// Everything extra the Mac shares. Settings always come along; the lists are filled in when the phone asks for
/// them (a tab on screen), so the Mac never scans anything on its own.
public struct MacExtras: Codable, Equatable, Sendable {
    /// The parts the phone asks for when it shows them.
    public enum Part: String, Codable, Sendable, CaseIterable { case projects, recent, unsaved, system }

    public var settings: MacSettings
    public var projects: [ProjectSnapshot]?
    public var recent: [PastChat]?
    public var search: ChatSearchResult?
    public var unsaved: [UnsavedSnapshot]?
    public var system: SystemSnapshot?
    /// How the last thing asked of the Mac went ("Dev Log written", "Couldn't start: …").
    public var note: MacNote?
    /// When the Mac last answered the phone's ping: it's awake and WatchMan is running.
    public var answeredAt: Date?
    /// The uncommitted changes of the session the phone has open, with their diffs.
    public var changes: ProjectChanges?

    public init(settings: MacSettings, projects: [ProjectSnapshot]? = nil, recent: [PastChat]? = nil,
                search: ChatSearchResult? = nil, unsaved: [UnsavedSnapshot]? = nil, system: SystemSnapshot? = nil,
                note: MacNote? = nil, answeredAt: Date? = nil, changes: ProjectChanges? = nil) {
        self.settings = settings
        self.projects = projects
        self.recent = recent
        self.search = search
        self.unsaved = unsaved
        self.system = system
        self.note = note
        self.answeredAt = answeredAt
        self.changes = changes
    }
}

/// A line from the Mac about what it just did for the phone.
public struct MacNote: Codable, Equatable, Sendable {
    public var text: String
    public var at: Date

    public init(text: String, at: Date = Date()) {
        self.text = text
        self.at = at
    }
}

/// The Mac's WatchMan settings that matter away from it.
public struct MacSettings: Codable, Equatable, Sendable {
    /// Hold prompts so they can be answered from WatchMan (and the phone).
    public var approvalsEnabled: Bool
    /// Seconds before a permission prompt goes back to the terminal.
    public var handBackSeconds: Double
    /// Minutes a prompt waits for the phone while you're away.
    public var awayHoldMinutes: Double
    /// Idle minutes (or locked) after which you count as away.
    public var awayAfterMinutes: Double
    public var iphoneAlerts: Bool
    public var iphoneAlertsWhenAway: Bool
    /// Alerts on the iPhone for finished turns too, not only for what needs you. Nil from a Mac before it: on.
    public var iphoneFinishedAlerts: Bool?
    public var autoContinue: Bool
    public var notchMessages: Bool
    public var sounds: Bool
    public var volume: Double
    /// No sounds or messages until then (nil: not quiet).
    public var quietUntil: Date?
    public var quietWhilePresenting: Bool
    public var stuckAlerts: Bool
    public var stuckIdleMinutes: Double
    public var stuckRepeatCount: Int
    public var stuckLongRunMinutes: Double
    public var devLog: Bool
    /// Minutes after midnight.
    public var devLogMinutes: Int
    public var devLogHaiku: Bool
    /// Quick replies for projects with none of their own.
    public var quickReplies: [String]

    public init(approvalsEnabled: Bool, handBackSeconds: Double, awayHoldMinutes: Double, awayAfterMinutes: Double,
                iphoneAlerts: Bool, iphoneAlertsWhenAway: Bool, autoContinue: Bool, notchMessages: Bool, sounds: Bool,
                volume: Double, quietUntil: Date?, quietWhilePresenting: Bool, stuckAlerts: Bool, stuckIdleMinutes: Double,
                stuckRepeatCount: Int, stuckLongRunMinutes: Double, devLog: Bool, devLogMinutes: Int, devLogHaiku: Bool,
                quickReplies: [String], iphoneFinishedAlerts: Bool? = nil) {
        self.approvalsEnabled = approvalsEnabled
        self.handBackSeconds = handBackSeconds
        self.awayHoldMinutes = awayHoldMinutes
        self.awayAfterMinutes = awayAfterMinutes
        self.iphoneAlerts = iphoneAlerts
        self.iphoneAlertsWhenAway = iphoneAlertsWhenAway
        self.iphoneFinishedAlerts = iphoneFinishedAlerts
        self.autoContinue = autoContinue
        self.notchMessages = notchMessages
        self.sounds = sounds
        self.volume = volume
        self.quietUntil = quietUntil
        self.quietWhilePresenting = quietWhilePresenting
        self.stuckAlerts = stuckAlerts
        self.stuckIdleMinutes = stuckIdleMinutes
        self.stuckRepeatCount = stuckRepeatCount
        self.stuckLongRunMinutes = stuckLongRunMinutes
        self.devLog = devLog
        self.devLogMinutes = devLogMinutes
        self.devLogHaiku = devLogHaiku
        self.quickReplies = quickReplies
    }

    /// The same ranges the Mac's Settings allow.
    public enum Range {
        public static let handBackSeconds: ClosedRange<Double> = 15...110
        public static let awayHoldMinutes: ClosedRange<Double> = 2...9
        public static let awayAfterMinutes: ClosedRange<Double> = 1...60
        public static let stuckIdleMinutes: ClosedRange<Double> = 3...60
        public static let stuckRepeatCount: ClosedRange<Int> = 2...10
        public static let stuckLongRunMinutes: ClosedRange<Double> = 10...240
    }

    /// The settings with one change made, kept inside the allowed ranges.
    public func applying(_ change: MacSettingChange) -> MacSettings {
        var value = self
        switch change {
        case .approvals(let on): value.approvalsEnabled = on
        case .handBackSeconds(let seconds): value.handBackSeconds = seconds.clamped(to: Range.handBackSeconds)
        case .awayHoldMinutes(let minutes): value.awayHoldMinutes = minutes.clamped(to: Range.awayHoldMinutes)
        case .awayAfterMinutes(let minutes): value.awayAfterMinutes = minutes.clamped(to: Range.awayAfterMinutes)
        case .iphoneAlerts(let on): value.iphoneAlerts = on
        case .iphoneAlertsWhenAway(let on): value.iphoneAlertsWhenAway = on
        case .iphoneFinishedAlerts(let on): value.iphoneFinishedAlerts = on
        case .autoContinue(let on): value.autoContinue = on
        case .notchMessages(let on): value.notchMessages = on
        case .sounds(let on): value.sounds = on
        case .volume(let level): value.volume = level.clamped(to: 0...1)
        case .quietUntil(let date): value.quietUntil = date
        case .quietWhilePresenting(let on): value.quietWhilePresenting = on
        case .stuckAlerts(let on): value.stuckAlerts = on
        case .stuckIdleMinutes(let minutes): value.stuckIdleMinutes = minutes.clamped(to: Range.stuckIdleMinutes)
        case .stuckRepeatCount(let count): value.stuckRepeatCount = count.clamped(to: Range.stuckRepeatCount)
        case .stuckLongRunMinutes(let minutes): value.stuckLongRunMinutes = minutes.clamped(to: Range.stuckLongRunMinutes)
        case .devLog(let on): value.devLog = on
        case .devLogMinutes(let minutes): value.devLogMinutes = minutes.clamped(to: 0...(24 * 60 - 1))
        case .devLogHaiku(let on): value.devLogHaiku = on
        case .quickReplies(let replies):
            value.quickReplies = replies.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        case .muted: break
        }
        return value
    }
}

/// One change to the Mac's settings, made on the phone.
public enum MacSettingChange: Codable, Equatable, Sendable {
    case approvals(Bool)
    case handBackSeconds(Double)
    case awayHoldMinutes(Double)
    case awayAfterMinutes(Double)
    case iphoneAlerts(Bool)
    case iphoneAlertsWhenAway(Bool)
    case iphoneFinishedAlerts(Bool)
    case autoContinue(Bool)
    case notchMessages(Bool)
    case sounds(Bool)
    case volume(Double)
    case quietUntil(Date?)
    case quietWhilePresenting(Bool)
    case stuckAlerts(Bool)
    case stuckIdleMinutes(Double)
    case stuckRepeatCount(Int)
    case stuckLongRunMinutes(Double)
    case devLog(Bool)
    case devLogMinutes(Int)
    case devLogHaiku(Bool)
    case quickReplies([String])
    /// No sounds, messages or phone alerts for one project.
    case muted(project: String, Bool)
}

/// What the phone asks of the Mac beyond answering prompts and replying.
public enum MacCommand: Codable, Equatable, Sendable {
    // For the command's session
    /// Press Esc in it (Ghostty and iTerm2).
    case stop
    /// Type "continue" after an error.
    case retry
    /// Drop one of the messages queued for when Claude finishes.
    case removeFollowUp(Int)
    /// "It's fine": stop warning that it looks stuck.
    case dismissStuck
    /// You looked at its result on the phone.
    case seen
    /// Share its chat now (at any age), with up to this many items.
    case chat(limit: Int)
    /// Share its project's uncommitted changes, with their diffs.
    case changes

    // For the Mac
    case setting(MacSettingChange)
    /// Open a new tab running Claude in a project, with a first message (or none).
    case start(folder: String, prompt: String)
    /// Pick up an earlier chat again (`claude --resume`).
    case resume(chatId: String, folder: String)
    /// Fill in a list for a tab the phone shows.
    case refresh(MacExtras.Part)
    /// Search every past chat on the Mac.
    case search(String)
    /// Ask Claude in that project to commit, or to push.
    case askProject(root: String, GitAsk)
    /// Quit a leftover process the System page lists.
    case quitLeftover(pid: Int32)
    case writeDevLog
    /// A test notification on the phone.
    case testAlert
    /// "Are you there?": the Mac answers with the time, so the phone can tell it's asleep or WatchMan is closed.
    case ping

    public enum GitAsk: String, Codable, Sendable { case commit, push }

    /// Checks a chat id before it goes on a command line: transcript names are UUIDs.
    public static func isChatId(_ text: String) -> Bool {
        text.range(of: #"^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil
    }
}

/// A project on the Mac, for starting a session there and for its settings.
public struct ProjectSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { root }
    public var root: String
    public var name: String
    /// Its parent folder ("Feb_2026"), to group by.
    public var group: String
    public var muted: Bool
    /// Skills to start Claude with ("/app-audit").
    public var starters: [String]
    public var quickReplies: [String]
    /// Open To-dos from its Obsidian note.
    public var todos: [ProjectTodo]

    public init(root: String, name: String, group: String, muted: Bool, starters: [String], quickReplies: [String],
                todos: [ProjectTodo]) {
        self.root = root
        self.name = name
        self.group = group
        self.muted = muted
        self.starters = starters
        self.quickReplies = quickReplies
        self.todos = todos
    }
}

public struct ProjectTodo: Codable, Equatable, Sendable {
    public var text: String
    public var due: Date?

    public init(text: String, due: Date?) {
        self.text = text
        self.due = due
    }

    /// What Claude is told when you start it on this To-do (the Mac's To-dos page says the same).
    public var prompt: String { "Work on this To-do from the project's Obsidian note: \(text)" }
}

/// An earlier chat that can be resumed, from the recent list or a search.
public struct PastChat: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var folder: String
    public var modified: Date
    /// The words around a search match.
    public var snippet: String?

    public init(id: String, title: String, folder: String, modified: Date, snippet: String? = nil) {
        self.id = id
        self.title = title
        self.folder = folder
        self.modified = modified
        self.snippet = snippet
    }

    public var folderName: String { (folder as NSString).lastPathComponent }
}

public struct ChatSearchResult: Codable, Equatable, Sendable {
    public var query: String
    public var hits: [PastChat]
    /// Only the newest matches came back.
    public var limited: Bool
    public var at: Date

    public init(query: String, hits: [PastChat], limited: Bool, at: Date = Date()) {
        self.query = query
        self.hits = hits
        self.limited = limited
        self.at = at
    }
}

/// A project with changed files or commits not pushed.
public struct UnsavedSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { root }
    public var root: String
    public var name: String
    public var colorKey: String
    public var branch: String?
    public var changed: Int
    public var ahead: Int
    public var hasUpstream: Bool
    /// A session there can take the message.
    public var canAsk: Bool

    public init(root: String, name: String, colorKey: String, branch: String?, changed: Int, ahead: Int,
                hasUpstream: Bool, canAsk: Bool) {
        self.root = root
        self.name = name
        self.colorKey = colorKey
        self.branch = branch
        self.changed = changed
        self.ahead = ahead
        self.hasUpstream = hasUpstream
        self.canAsk = canAsk
    }

    /// "3 files changed · 2 commits not pushed".
    public var summary: String {
        var parts: [String] = []
        if changed > 0 { parts.append(changed == 1 ? "1 file changed" : "\(changed) files changed") }
        if ahead > 0 { parts.append(ahead == 1 ? "1 commit not pushed" : "\(ahead) commits not pushed") }
        return parts.joined(separator: " · ")
    }
}

/// The Mac's System page: memory, what each session uses, leftovers, tokens.
public struct SystemSnapshot: Codable, Equatable, Sendable {
    public struct SessionMemory: Codable, Equatable, Sendable {
        public var name: String
        public var megabytes: Int
        public init(name: String, megabytes: Int) {
            self.name = name
            self.megabytes = megabytes
        }
    }

    public struct Leftover: Codable, Equatable, Identifiable, Sendable {
        public var id: Int32 { pid }
        public var pid: Int32
        public var kind: String
        public var megabytes: Int
        public init(pid: Int32, kind: String, megabytes: Int) {
            self.pid = pid
            self.kind = kind
            self.megabytes = megabytes
        }
    }

    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    /// 1 normal, 2 high, 4 critical.
    public var pressure: Int
    public var sessions: [SessionMemory]
    public var leftovers: [Leftover]
    public var blockTokens: Int?
    public var blockEnds: Date?
    public var weekTokens: Int?
    /// Tokens budgeted for a 5-hour block (0: none).
    public var budget: Int
    public var at: Date

    public init(memoryUsed: UInt64, memoryTotal: UInt64, pressure: Int, sessions: [SessionMemory], leftovers: [Leftover],
                blockTokens: Int?, blockEnds: Date?, weekTokens: Int?, budget: Int, at: Date = Date()) {
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.pressure = pressure
        self.sessions = sessions
        self.leftovers = leftovers
        self.blockTokens = blockTokens
        self.blockEnds = blockEnds
        self.weekTokens = weekTokens
        self.budget = budget
        self.at = at
    }

    public var usedGB: Double { Double(memoryUsed) / 1_073_741_824 }
    public var totalGB: Double { Double(memoryTotal) / 1_073_741_824 }
    public var usedFraction: Double { memoryTotal == 0 ? 0 : min(1, Double(memoryUsed) / Double(memoryTotal)) }
    public var pressureLabel: String { pressure >= 4 ? "critical" : pressure >= 2 ? "high" : "normal" }
}

/// What a session's page on the phone shows beyond its state and prompt.
public struct SessionExtras: Codable, Equatable, Sendable {
    public struct Helper: Codable, Equatable, Sendable {
        public var type: String
        public var description: String
        public var step: String?
        public init(type: String, description: String, step: String?) {
            self.type = type
            self.description = description
            self.step = step
        }
    }

    /// Messages waiting for Claude to finish, sent one by one.
    public var followUps: [String]
    /// Why it looks stuck.
    public var stuck: String?
    /// What went wrong, when it stopped with an error.
    public var error: String?
    /// Esc can be pressed in its terminal.
    public var canStop: Bool
    /// When it continues by itself after the usage limit.
    public var continuesAt: Date?
    public var subagents: [Helper]
    public var quickReplies: [String]
    public var projectRoot: String?
    /// Its Remote Control page on claude.ai, when Remote Control is on.
    public var remoteURL: String?

    public init(followUps: [String], stuck: String?, error: String?, canStop: Bool, continuesAt: Date?,
                subagents: [Helper], quickReplies: [String], projectRoot: String?, remoteURL: String? = nil) {
        self.followUps = followUps
        self.stuck = stuck
        self.error = error
        self.canStop = canStop
        self.continuesAt = continuesAt
        self.subagents = subagents
        self.quickReplies = quickReplies
        self.projectRoot = projectRoot
        self.remoteURL = remoteURL
    }
}

/// A project's uncommitted changes, as the Mac's Changes tab shows them.
public struct ProjectChanges: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Identifiable, Sendable {
        public var id: String { path }
        public var path: String
        /// "M", "A", "D", "??"…
        public var status: String
        public var added: Int?
        public var removed: Int?
        /// The diff's hunks (git's header lines left out), cut short for a big file.
        public var diff: [String]
        public var cut: Bool

        public init(path: String, status: String, added: Int?, removed: Int?, diff: [String], cut: Bool) {
            self.path = path
            self.status = status
            self.added = added
            self.removed = removed
            self.diff = diff
            self.cut = cut
        }
    }

    public var sessionId: String
    public var root: String
    public var files: [File]
    public var at: Date

    public init(sessionId: String, root: String, files: [File], at: Date = Date()) {
        self.sessionId = sessionId
        self.root = root
        self.files = files
        self.at = at
    }

    /// Lines per file and in all, so the status record stays well inside iCloud's 1 MB.
    public static let linesPerFile = 400
    public static let totalLines = 3000

    /// A diff's lines without git's headers, within the limits left.
    public static func hunks(_ diff: String, budget: Int) -> (lines: [String], cut: Bool) {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
            !(line.hasPrefix("diff --git") || line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
              || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode") || line.hasPrefix("similarity index"))
        }
        let limit = max(0, min(linesPerFile, budget))
        let kept = lines.prefix(limit).map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }
        return (Array(kept), lines.count > limit)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
