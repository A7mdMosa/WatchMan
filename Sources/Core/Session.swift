import Foundation

public enum SessionStatus: Equatable, Sendable {
    case working
    case needsYou(String)   // why: permission, question, error
    case finished
    case idle
    case closed

    public var isNeedsYou: Bool {
        if case .needsYou = self { return true }
        return false
    }

    /// Same kind of status, ignoring the reason text.
    public func sameKind(as other: SessionStatus) -> Bool {
        switch (self, other) {
        case (.working, .working), (.needsYou, .needsYou), (.finished, .finished),
             (.idle, .idle), (.closed, .closed): true
        default: false
        }
    }
}

public struct PendingApproval: Equatable, Sendable {
    public enum Kind: Sendable { case command, edit, write, question, plan, other }

    public var tool: String
    /// The short step line, e.g. "Run · Build the release APK" or "Edit · main.dart".
    public var detail: String
    public var requestedAt: Date
    /// Claude's own description of a command (Bash's `description`).
    public var description: String?
    /// The full command, as it would run.
    public var command: String?
    public var filePath: String?
    /// The folder the session runs in.
    public var cwd: String?
    /// Edit's one replacement or MultiEdit's several.
    public var edits: [TextEdit]
    /// Write's whole new content.
    public var content: String?
    /// What "Always" would allow, e.g. "Bash(flutter build:*)".
    public var rules: [String]
    /// When WatchMan hands the prompt back to the terminal (nil until it holds it).
    public var handBackAt: Date?
    /// Claude's questions (AskUserQuestion): answered by picking a choice, not allowed or denied.
    public var questions: [AskedQuestion]
    /// Claude's plan, when it asks to leave plan mode and start (ExitPlanMode), in markdown.
    public var plan: String?

    public init(tool: String, detail: String, requestedAt: Date, description: String? = nil, command: String? = nil,
                filePath: String? = nil, cwd: String? = nil, edits: [TextEdit] = [], content: String? = nil,
                rules: [String] = [], handBackAt: Date? = nil, questions: [AskedQuestion] = [], plan: String? = nil) {
        self.tool = tool
        self.detail = detail
        self.requestedAt = requestedAt
        self.description = description
        self.command = command
        self.filePath = filePath
        self.cwd = cwd
        self.edits = edits
        self.content = content
        self.rules = rules
        self.handBackAt = handBackAt
        self.questions = questions
        self.plan = plan
    }

    /// Built from a PermissionRequest: the raw command, file and edits, not just the step line.
    public init(event: HookEvent, at now: Date) {
        let tool = event.toolName ?? "Tool"
        let input = event.toolInput
        var edits = event.edits
        if let old = input["old_string"], let new = input["new_string"] { edits.insert(TextEdit(oldString: old, newString: new), at: 0) }
        if let source = input["new_source"] { edits.append(TextEdit(oldString: "", newString: source)) }   // NotebookEdit
        self.init(tool: tool, detail: Session.stepLabel(tool: tool, input: input), requestedAt: now,
                  description: input["description"].flatMap { $0.isEmpty ? nil : $0 },
                  command: tool == "Bash" ? input["command"] : nil,
                  filePath: input["file_path"] ?? input["notebook_path"],
                  cwd: event.cwd.isEmpty ? nil : event.cwd,
                  edits: edits,
                  content: tool == "Write" ? input["content"] : nil,
                  rules: event.permissionRules,
                  questions: tool == "AskUserQuestion" ? event.questions : [],
                  plan: tool == "ExitPlanMode" ? (input["plan"] ?? "") : nil)
    }

    public var kind: Kind {
        if !questions.isEmpty { return .question }
        if plan != nil { return .plan }
        if command != nil { return .command }
        if content != nil { return .write }
        if !edits.isEmpty { return .edit }
        return .other
    }

    /// What risk is judged on: the real command, never Claude's description of it.
    public var riskText: String { command ?? detail }
    public var isRisky: Bool { CommandRisk.isRisky(riskText) }

    /// The card's title: the question, the plan's heading, else Claude's description, else the step line.
    public var title: String { questions.first?.question ?? planTitle ?? description ?? detail }

    /// Claude asks something instead of asking permission.
    public var isQuestion: Bool { !questions.isEmpty }

    /// Claude has a plan ready and asks to start on it.
    public var isPlan: Bool { plan != nil && questions.isEmpty }

    /// The plan's first heading or line, without the markdown ("Add the login screen").
    public var planTitle: String? {
        guard let plan else { return nil }
        let first = plan.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        guard var line = first else { return "Claude's plan is ready" }
        line = line.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"^(Plan|Implementation plan)\s*[:—-]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        line = line.replacingOccurrences(of: "**", with: "")
        if line.isEmpty || line.lowercased() == "plan" { return "Claude's plan is ready" }
        return line.count > 90 ? String(line.prefix(89)) + "…" : line
    }

    /// The file's name, for edits and writes.
    public var fileName: String? { filePath.map { ($0 as NSString).lastPathComponent } }

    /// The change an edit or write makes, as lines.
    public var diff: LineDiff? {
        switch kind {
        case .write: return LineDiff.make(old: "", new: content ?? "")
        case .edit: return LineDiff.make(edits: edits)
        default: return nil
        }
    }
}

public struct Verification: Equatable, Sendable {
    public enum Result: Equatable, Sendable { case passed, failed }
    public struct Check: Equatable, Sendable {
        public var result: Result
        public var at: Date
        public init(result: Result, at: Date) { self.result = result; self.at = at }
    }
    public var analyze: Check?
    public var test: Check?
    public init(analyze: Check? = nil, test: Check? = nil) { self.analyze = analyze; self.test = test }
}

/// Everything WatchMan knows about one Claude Code session.
public struct Session: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String?
    public var cwd: String
    public var host: HostKind
    public var tty: String?
    public var pid: Int32?
    public var transcriptPath: String?
    public var status: SessionStatus
    public var statusSince: Date
    public var lastActivity: Date
    public var lastStep: String?
    /// Remote Control is on: the session's id in the Claude app, so it can be used from the phone or the web.
    public var remoteSessionId: String?
    /// Stopped by Claude's usage limit (with when it resets, when Claude Code said).
    public var rateLimited = false
    public var limitReset: String?
    /// The tool step before the current one, and a count of tool steps this turn (gives each step an identity).
    public var previousStep: String?
    public var stepNumber = 0
    public var lastReply: String?
    public var pendingApproval: PendingApproval?
    public var permissionMode: String?
    public var verification = Verification()
    public var projectRoot: String?
    public var editedAfterSync = false
    public var summary: String?
    /// False from the moment a session finishes until you open, expand or answer it.
    public var seen = true
    /// The conversation moved on to this session; this one is only a viewer and is hidden.
    public var continuedIn: String?
    /// The step that failed last, and how many times in a row it failed.
    public var failureStep: String?
    public var failureCount = 0
    /// Set by the stuck check while the session looks stuck.
    public var stuck: StuckReason?
    /// What the last turn did, from the transcript.
    public var lastTurn: TurnSummary?
    /// The last turn stopped with an error (an API error, a limit): it needs a retry.
    public var failed = false
    public var errorText: String?
    /// Claude's to-do list for the work, and the subagents running right now.
    public var tasks: [ClaudeTask] = []
    public var subagents: [Subagent] = []
    /// How full the conversation's context window is (0–100), from Claude Code's status line.
    public var contextPercent: Double?

    /// Finished with a result you haven't looked at yet.
    public var isUnseenResult: Bool { status == .finished && !seen }

    public init(id: String, cwd: String, host: HostKind, now: Date) {
        self.id = id
        self.cwd = cwd
        self.host = host
        self.status = .idle
        self.statusSince = now
        self.lastActivity = now
    }

    /// Which project a session belongs to, for grouping: its project folder, else its working folder.
    public var projectKey: String { (projectRoot ?? cwd).lowercased() }

    public var displayName: String {
        if let title, !title.isEmpty { return title }
        if let projectRoot { return (projectRoot as NSString).lastPathComponent }
        let folder = (cwd as NSString).lastPathComponent
        return folder.isEmpty ? "Claude session" : folder
    }

    mutating func setStatus(_ new: SessionStatus, at now: Date) {
        if !status.sameKind(as: new) { statusSince = now }
        status = new
    }

    /// Updates the session from a hook event.
    public mutating func apply(_ event: HookEvent, now: Date) {
        lastActivity = now
        if ["UserPromptSubmit", "PreToolUse", "Stop"].contains(event.name) {
            failed = false
            errorText = nil
        }
        if !event.cwd.isEmpty { cwd = event.cwd }
        if event.host != .other { host = event.host }
        if let tty = event.tty { self.tty = tty }
        if let pid = event.claudePid { self.pid = pid }
        if let path = event.transcriptPath { transcriptPath = path }
        if let mode = event.permissionMode { permissionMode = mode }

        switch event.name {
        case "SessionStart":
            setStatus(.idle, at: now)
            lastStep = "Ready"
        case "UserPromptSubmit":
            rateLimited = false
            limitReset = nil
            previousStep = nil
            stepNumber = 0
            seen = true
            stuck = nil
            failureStep = nil
            failureCount = 0
            pendingApproval = nil
            setStatus(.working, at: now)
            lastStep = "Thinking…"
        case "PreToolUse":
            if pendingApproval == nil { setStatus(.working, at: now) }
            let step = Session.stepLabel(tool: event.toolName ?? "Tool", input: event.toolInput)
            if stepNumber > 0 { previousStep = lastStep }
            stepNumber += 1
            lastStep = step
        case "PostToolUse", "PostToolUseFailure":
            pendingApproval = nil
            setStatus(.working, at: now)
            if event.name == "PostToolUseFailure" {
                let step = Session.stepLabel(tool: event.toolName ?? "Tool", input: event.toolInput)
                failureCount = step == failureStep ? failureCount + 1 : 1
                failureStep = step
            } else {
                failureStep = nil
                failureCount = 0
            }
        case "PermissionRequest":
            let approval = PendingApproval(event: event, at: now)
            pendingApproval = approval
            // A question reads as one (with its own words), not as a permission
            setStatus(.needsYou(approval.isQuestion ? approval.title
                                : approval.isPlan ? "Plan ready · \(approval.title)" : "Permission · \(approval.detail)"), at: now)
        case "Notification":
            let message = event.message ?? "Needs you"
            // The idle reminder after a finished turn isn't a new question
            if message.lowercased().contains("waiting for your input") { break }
            // Claude Code's reminder about the prompt WatchMan already shows keeps the prompt's own words
            if pendingApproval != nil, message.hasPrefix("Claude needs your permission") { break }
            if RateLimit.isLimit(message) {
                rateLimited = true
                limitReset = RateLimit.resetTime(message)
                setStatus(.needsYou("Usage limit reached"), at: now)
                break
            }
            setStatus(.needsYou(message), at: now)
        case "Stop":
            stuck = nil
            pendingApproval = nil
            if status != .finished { seen = false }
            setStatus(.finished, at: now)
            lastStep = "Finished"
        case "StopFailure":
            pendingApproval = nil
            failed = true
            errorText = event.error ?? event.message
            if RateLimit.isLimit(event.error) || RateLimit.isLimit(event.message) {
                rateLimited = true
                limitReset = RateLimit.resetTime(event.message) ?? RateLimit.resetTime(event.error)
            }
            setStatus(.needsYou("Stopped with an error"), at: now)
        case "SubagentStart":
            lastStep = "Subagent running"
        case "SubagentStop":
            lastStep = "Subagent done"
        case "SessionEnd":
            pendingApproval = nil
            setStatus(.closed, at: now)
        default:
            break
        }
    }

    /// Short English description of a tool call, e.g. "Edit · main.dart".
    public static func stepLabel(tool: String, input: [String: String]) -> String {
        func file(_ key: String) -> String? { input[key].map { ($0 as NSString).lastPathComponent } }
        func short(_ text: String?, _ limit: Int = 50) -> String? {
            guard let text else { return nil }
            let line = text.split(separator: "\n").first.map(String.init) ?? text
            return line.count > limit ? String(line.prefix(limit)) + "…" : line
        }
        let detail: String?
        let label: String
        switch tool {
        case "Bash":
            label = "Run"; detail = short(input["description"]) ?? short(input["command"])
        case "Read":
            label = "Read"; detail = file("file_path")
        case "Edit", "MultiEdit":
            label = "Edit"; detail = file("file_path")
        case "Write":
            label = "Write"; detail = file("file_path")
        case "NotebookEdit":
            label = "Edit"; detail = file("notebook_path")
        case "Grep":
            label = "Search"; detail = short(input["pattern"])
        case "Glob":
            label = "Find"; detail = short(input["pattern"])
        case "WebFetch":
            label = "Fetch"; detail = input["url"].flatMap { URL(string: $0)?.host }
        case "WebSearch":
            label = "Web search"; detail = short(input["query"])
        case "Task", "Agent":
            label = "Agent"; detail = short(input["description"])
        case "Skill":
            label = "Skill"; detail = input["skill"]
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            label = "Update tasks"; detail = nil
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                label = parts.dropFirst().first.map(String.init) ?? "MCP"
                detail = parts.dropFirst(2).joined(separator: "_")
            } else {
                label = tool; detail = nil
            }
        }
        guard let detail, !detail.isEmpty else { return label }
        return "\(label) · \(detail)"
    }

    /// Needs-you first (longest waiting on top), then unseen results, working, the rest. Closed ones are left out.
    public static func sortedForDisplay(_ sessions: [Session]) -> [Session] {
        func rank(_ s: Session) -> Int {
            switch s.status {
            case .needsYou: 0
            case .finished: s.seen ? 3 : 1
            case .working: 2
            case .idle: 4
            case .closed: 5
            }
        }
        return sessions
            .filter { $0.status != .closed && $0.continuedIn == nil }
            .sorted { a, b in
                let ra = rank(a), rb = rank(b)
                if ra != rb { return ra < rb }
                if ra == 0 { return a.statusSince < b.statusSince }
                // Working and idle sessions of the same project sit together
                if ra >= 2, a.projectKey != b.projectKey { return a.projectKey < b.projectKey }
                return a.lastActivity > b.lastActivity
            }
    }
}
