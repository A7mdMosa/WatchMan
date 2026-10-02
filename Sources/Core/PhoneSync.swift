import Foundation

/// What the Mac shares with the iPhone about one session (through the private iCloud database): enough to list
/// it, show what it waits on, and answer it.
public struct SessionSnapshot: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case needsYou, working, done, idle, limited, failed }

    public var id: String
    public var name: String
    public var task: String?
    public var colorKey: String
    /// The terminal it runs in ("Ghostty").
    public var host: String
    public var canReply: Bool
    public var state: State
    /// Why it waits, or the step it's on.
    public var detail: String
    public var since: Date
    public var unseen: Bool
    /// The prompt WatchMan holds for it, answerable from the phone.
    public var prompt: PromptSnapshot?
    public var contextPercent: Double?
    public var limitReset: Date?
    public var updated: Date
    /// What the last turn changed, and Claude's plan for the work (for the Changes tab). Optional, so records
    /// written before they existed still read.
    public var turn: TurnSnapshot?
    public var tasks: [TaskSnapshot]?
    /// Its queued messages, why it looks stuck, its subagents, its quick replies (set by the Mac after init).
    public var extras: SessionExtras?

    public init(id: String, name: String, task: String?, colorKey: String, host: String, canReply: Bool, state: State,
                detail: String, since: Date, unseen: Bool, prompt: PromptSnapshot?, contextPercent: Double?,
                limitReset: Date?, updated: Date, turn: TurnSnapshot? = nil, tasks: [TaskSnapshot]? = nil) {
        self.id = id
        self.name = name
        self.task = task
        self.colorKey = colorKey
        self.host = host
        self.canReply = canReply
        self.state = state
        self.detail = detail
        self.since = since
        self.unseen = unseen
        self.prompt = prompt
        self.contextPercent = contextPercent
        self.limitReset = limitReset
        self.updated = updated
        self.turn = turn
        self.tasks = tasks
    }

    /// From the Mac's session; `held` is whether WatchMan holds its prompt (so the phone can answer it).
    public init(session: Session, name: String, colorKey: String, task: String?, held: Bool, limitReset: Date?, now: Date = Date()) {
        let state: State
        if session.rateLimited { state = .limited }
        else if session.failed { state = .failed }
        else {
            switch session.status {
            case .needsYou: state = .needsYou
            case .working: state = .working
            case .finished: state = .done
            case .idle, .closed: state = .idle
            }
        }
        let detail: String
        switch session.status {
        case .needsYou(let reason): detail = session.pendingApproval?.title ?? reason
        case .working: detail = session.lastStep ?? "Working"
        default: detail = session.lastReply.map { String($0.split(separator: "\n").first ?? "") } ?? ""
        }
        self.init(id: session.id, name: name, task: task, colorKey: colorKey, host: session.host.label,
                  canReply: session.host.canSend, state: state, detail: detail, since: session.statusSince,
                  unseen: session.isUnseenResult,
                  prompt: held ? session.pendingApproval.map(PromptSnapshot.init(approval:)) : nil,
                  contextPercent: session.contextPercent, limitReset: limitReset, updated: now,
                  turn: session.lastTurn.flatMap { $0.isEmpty ? nil : TurnSnapshot($0) },
                  tasks: session.tasks.isEmpty ? nil : session.tasks.map(TaskSnapshot.init))
    }
}

/// What the last turn did: the files it edited, the tests, the commits.
public struct TurnSnapshot: Codable, Equatable, Sendable {
    public var prompt: String?
    public var files: [String]
    public var testsPassed: Bool?
    public var commits: Int

    public init(_ turn: TurnSummary) {
        prompt = turn.prompt.map { String($0.prefix(300)) }
        files = turn.filesEdited.map { ($0 as NSString).lastPathComponent }.sorted()
        testsPassed = turn.testsPassed
        commits = turn.commits
    }
}

/// One step of Claude's plan.
public struct TaskSnapshot: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case pending, inProgress, done }
    public var text: String
    public var state: State

    public init(_ task: ClaudeTask) {
        text = task.text
        state = switch task.status {
        case .pending: .pending
        case .inProgress: .inProgress
        case .done: .done
        }
    }
}

/// A prompt the phone can answer: a permission (Allow / Deny), a question (its choices) or a plan (Approve /
/// Keep Planning).
public struct PromptSnapshot: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case permission, question, plan }

    public var kind: Kind
    public var title: String
    public var command: String?
    public var file: String?
    /// An edit's changed lines, prefixed "+ " or "− " (a few, to read on the phone).
    public var diff: [String]
    public var risky: Bool
    public var questions: [AskedQuestion]
    public var plan: String?
    public var handBackAt: Date?
    /// What "Always" saves, e.g. "Bash(flutter build:*)" (optional, so records from before it still read).
    public var rules: [String]?
    /// When the prompt came, which tells it from the next one in the same session (optional, as above).
    public var asked: Date?

    public init(approval: PendingApproval) {
        kind = approval.isQuestion ? .question : approval.isPlan ? .plan : .permission
        title = approval.title
        command = approval.command
        file = approval.fileName
        diff = (approval.diff?.lines ?? []).filter { $0.kind != .context }.prefix(12).map {
            ($0.kind == .added ? "+ " : $0.kind == .removed ? "− " : "  ") + $0.text
        }
        risky = approval.isRisky
        questions = approval.questions
        plan = approval.plan.map { $0.count > 20_000 ? String($0.prefix(20_000)) + "…" : $0 }
        handBackAt = approval.handBackAt
        rules = approval.rules.isEmpty ? nil : approval.rules
        asked = approval.requestedAt
    }
}

/// What you did on the phone, for the Mac to carry out (then delete).
public struct PhoneCommand: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case allow
        case alwaysAllow
        case deny(message: String?)
        case answer(QuestionAnswers)
        case reply(String)
        case continueAfterLimit
        /// Choice number `n` of a single question (from a notification's buttons, which only know its place).
        case pick(Int)
        /// Everything else: stop, settings, new sessions, earlier chats, commits (see `MacCommand`).
        case mac(MacCommand)

        /// An answer to the prompt the session waits on.
        public var answersPrompt: Bool {
            switch self {
            case .allow, .alwaysAllow, .deny, .answer, .pick: true
            case .reply, .continueAfterLimit, .mac: false
            }
        }
    }

    public var id: UUID
    public var sessionId: String
    public var kind: Kind
    public var created: Date
    /// When the prompt it answers came (`PromptSnapshot.asked`): the phone may still show one that has since been
    /// answered and replaced, and an answer must never reach the next prompt. Nil: whichever prompt waits.
    public var prompt: Date?

    public init(sessionId: String, kind: Kind, created: Date = Date(), prompt: Date? = nil) {
        self.id = UUID()
        self.sessionId = sessionId
        self.kind = kind
        self.created = created
        self.prompt = prompt
    }

    /// It answers a prompt other than `current` (the one waiting now, if any).
    public func answersAnotherPrompt(than current: Date?) -> Bool {
        guard kind.answersPrompt, let prompt else { return false }
        guard let current else { return true }
        // Dates go through JSON and ActivityKit: equal within a moment is the same prompt
        return abs(current.timeIntervalSince(prompt)) > 0.5
    }

    /// Commands older than this are stale (the prompt has surely moved on) and are dropped unread.
    public static let maxAge: TimeInterval = 10 * 60

    public func isStale(now: Date = Date()) -> Bool { now.timeIntervalSince(created) > Self.maxAge }
}

/// The last messages of a session's chat, for its page on the phone.
public struct ChatSnapshot: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public enum Role: String, Codable, Sendable { case you, claude, steps }
        public var role: Role
        public var text: String
        public var at: Date
        /// Claude's questions, their answers or how they ended (optional: older Macs don't send them, and older
        /// phones read `text`, which says the same in markdown).
        public var questions: [AskedQuestion]?
        public var answers: [String: String]?
        public var answerNote: String?
    }

    public var sessionId: String
    public var items: [Item]
    /// How many items the whole chat has, so the phone knows there are earlier ones to ask for.
    public var total: Int?

    public static let maxItems = 40
    /// The most the phone can ask for ("Load earlier messages").
    public static let largestLimit = 400
    /// Each message is cut to this many characters, so a chat stays well inside an iCloud record (1 MB).
    public static let maxCharacters = 4000
    /// Characters in all, for the same reason when the phone asks for a long chat.
    public static let maxTotalCharacters = 600_000

    /// From the transcript's chat: messages as they are, each run of steps as one line per step. `limit`: the
    /// newest that many items, fewer if they'd pass the size budget.
    public init(sessionId: String, chat: [TranscriptState.ChatItem], limit: Int = ChatSnapshot.maxItems) {
        self.sessionId = sessionId
        total = chat.count
        var budget = Self.maxTotalCharacters
        let newest = chat.suffix(max(1, min(limit, Self.largestLimit))).reversed().prefix { item in
            let size: Int
            switch item {
            case .message(let message): size = min(message.text.count, Self.maxCharacters)
            case .steps(let steps): size = steps.suffix(8).reduce(0) { $0 + $1.text.count }
            }
            budget -= size
            return budget >= 0
        }
        items = newest.reversed().map { item in
            switch item {
            case .message(let message):
                let text = message.text.count > Self.maxCharacters ? String(message.text.prefix(Self.maxCharacters)) + "…" : message.text
                guard !message.questions.isEmpty else {
                    return Item(role: message.fromYou ? .you : .claude, text: text, at: message.at)
                }
                return Item(role: .claude, text: text, at: message.at, questions: message.questions,
                            answers: message.answers.isEmpty ? nil : message.answers, answerNote: message.answerNote)
            case .steps(let steps):
                return Item(role: .steps, text: steps.suffix(8).map(\.text).joined(separator: "\n"), at: steps.last?.at ?? Date())
            }
        }
    }
}
