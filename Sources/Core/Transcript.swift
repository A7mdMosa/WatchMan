import Foundation

/// What WatchMan reads out of a session transcript (~/.claude/projects/*/<session>.jsonl).
/// Lines are fed in order with `consume`; the state is a plain value, so it's easy to test.
public struct TranscriptState: Sendable, Equatable {
    public struct UsageEntry: Sendable, Equatable {
        public var at: Date
        public var tokens: Int
    }

    /// The name you gave the session (/rename) wins over Claude Code's automatic title,
    /// which it keeps rewriting after a rename.
    public var title: String? { customTitle ?? aiTitle }
    public var aiTitle: String?
    public var customTitle: String?
    public var cwd: String?
    public var entrypoint: String?
    public var lastReply: String?
    public var lastReplyAt: Date?
    public var recentReplies: [String] = []           // last few assistant messages, oldest first
    public var lastPrompt: String?
    /// Set when Claude Code moved this conversation into another session (e.g. a background job).
    public var continuedIn: String?
    public var verification = Verification()
    public var lastEditAt: Date?
    public var lastProjectSyncAt: Date?
    public var editedFiles: [String] = []          // most recent last, no duplicates
    public var usage: [UsageEntry] = []
    /// What happened, in order: prompts, tool steps, replies, test results (last 200).
    public var timeline: [TimelineEntry] = []
    /// The conversation in full: your prompts and Claude's messages, oldest first (the last 20).
    public var conversation: [Message] = []
    /// Claude's own to-do list for the work (TaskCreate / TaskUpdate, or TodoWrite in older versions).
    public var tasks: [ClaudeTask] = []
    /// TaskCreate calls waiting for their result, which gives the task its number.
    private var pendingTaskCreates: [String: String] = [:]
    /// Questions (AskUserQuestion) waiting for their answer: the tool call's id and the chat message showing them.
    private var pendingQuestions: [String: Int] = [:]

    public struct Message: Sendable, Equatable, Identifiable {
        public var id: Int
        public var at: Date
        public var fromYou: Bool
        /// The message as markdown. For Claude's questions, the questions, their choices and the answer as text.
        public var text: String
        /// Claude's questions (AskUserQuestion), when this message is one.
        public var questions: [AskedQuestion] = []
        /// The picked choices by question, once answered.
        public var answers: [String: String] = [:]
        /// How the questions ended when not by picking: skipped, or your own words.
        public var answerNote: String?

        public init(id: Int, at: Date, fromYou: Bool, text: String) {
            self.id = id
            self.at = at
            self.fromYou = fromYou
            self.text = text
        }

        /// The questions as plain markdown, for places that only show text.
        public static func questionsText(_ questions: [AskedQuestion], answers: [String: String], note: String?) -> String {
            var lines: [String] = []
            for question in questions {
                lines.append("**Claude asks:** " + question.question)
                let picked = Set((answers[question.question] ?? "").components(separatedBy: ", "))
                for option in question.options {
                    lines.append("- " + option.label + (picked.contains(option.label) ? " ✓" : ""))
                }
                if let answer = answers[question.question] { lines.append("**You answered:** " + answer) }
                lines.append("")
            }
            if let note { lines.append("**You answered:** " + note) }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Adds the message and returns its id (nil for empty text).
    @discardableResult
    private mutating func addMessage(fromYou: Bool, _ text: String, at: Date) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = (conversation.last?.id ?? 0) + 1
        conversation.append(Message(id: id, at: at, fromYou: fromYou, text: trimmed))
        if conversation.count > 20 { conversation.removeFirst(conversation.count - 20) }
        return id
    }

    /// One thing in the chat: a message, or the steps Claude took between two messages.
    public enum ChatItem: Sendable, Equatable, Identifiable {
        case message(Message)
        /// Tool steps and check results, in order.
        case steps([TimelineEntry])

        public var id: String {
            switch self {
            case .message(let message): "m\(message.id)"
            case .steps(let entries): "s\(entries.first?.id ?? 0)"
            }
        }
    }

    /// The conversation with Claude's steps between the messages, the way the terminal shows it: from the
    /// oldest message still kept, consecutive steps grouped. Messages older than the timeline come first, alone.
    public var chat: [ChatItem] {
        let linked = Set(timeline.compactMap(\.messageId))
        let oldestLinked = linked.min() ?? Int.max
        var items: [ChatItem] = conversation.filter { $0.id < oldestLinked }.map { .message($0) }
        let messages = Dictionary(uniqueKeysWithValues: conversation.map { ($0.id, $0) })
        var steps: [TimelineEntry] = []
        var started = !items.isEmpty
        func flush() {
            if !steps.isEmpty { items.append(.steps(steps)) }
            steps = []
        }
        for entry in timeline {
            if let id = entry.messageId {
                guard let message = messages[id] else { continue }
                started = true
                flush()
                items.append(.message(message))
            } else if started, entry.kind != .prompt, entry.kind != .reply {
                steps.append(entry)
            }
        }
        flush()
        return items
    }
    /// What the turn since your last prompt did.
    public var lastTurn = TurnSummary()

    public struct TimelineEntry: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable { case prompt, tool, reply, passed, failed }
        public var id: Int
        public var at: Date
        public var kind: Kind
        public var text: String
        /// The conversation message this prompt or reply is (`conversation` keeps the full text).
        public var messageId: Int?

        public init(id: Int, at: Date, kind: Kind, text: String, messageId: Int? = nil) {
            self.id = id
            self.at = at
            self.kind = kind
            self.text = text
            self.messageId = messageId
        }
    }

    private mutating func addTimeline(_ kind: TimelineEntry.Kind, _ text: String, at: Date, messageId: Int? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        let short = firstLine.count > 160 ? String(firstLine.prefix(160)) + "…" : firstLine
        timeline.append(TimelineEntry(id: (timeline.last?.id ?? 0) + 1, at: at, kind: kind, text: short, messageId: messageId))
        if timeline.count > 200 { timeline.removeFirst(timeline.count - 200) }
    }

    /// A typed prompt, or "/command" for slash commands; nil for system text.
    static func promptText(_ text: String) -> String? {
        if let range = text.range(of: #"<command-name>([^<]+)</command-name>"#, options: .regularExpression) {
            return String(text[range]).replacingOccurrences(of: "<command-name>", with: "")
                .replacingOccurrences(of: "</command-name>", with: "")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("Caveat:") else { return nil }
        return trimmed
    }

    private var pendingChecks: [String: Check] = [:]  // tool_use id → check kind
    private var countedMessageIds: Set<String> = []

    enum Check: Sendable { case analyze, test }

    public init() {}

    public var editedAfterSync: Bool {
        guard let lastEditAt else { return false }
        guard let lastProjectSyncAt else { return true }
        return lastEditAt > lastProjectSyncAt
    }

    public mutating func consume(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        consume(object)
    }

    public mutating func consume(_ object: [String: Any]) {
        let type = object["type"] as? String
        let at = (object["timestamp"] as? String).flatMap(TranscriptState.parseDate) ?? Date.distantPast

        if let cwd = object["cwd"] as? String { self.cwd = cwd }
        if let entrypoint = object["entrypoint"] as? String { self.entrypoint = entrypoint }

        switch type {
        case "ai-title":
            if let title = object["aiTitle"] as? String, !title.isEmpty { aiTitle = title }
        case "custom-title":
            let title = (object["customTitle"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            customTitle = title.isEmpty ? nil : title
        case "last-prompt":
            lastPrompt = object["lastPrompt"] as? String
        case "continued-in":
            continuedIn = object["continuedInSessionId"] as? String
        case "assistant":
            if object["isSidechain"] as? Bool == true { return }
            guard let message = object["message"] as? [String: Any] else { return }
            countUsage(message, at: at)
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lastReply = text
                        lastReplyAt = at
                        addTimeline(.reply, text, at: at, messageId: addMessage(fromYou: false, text, at: at))
                        recentReplies.append(text)
                        if recentReplies.count > 6 { recentReplies.removeFirst() }
                    }
                case "tool_use":
                    toolUse(block, at: at)
                default:
                    break
                }
            }
        case "user":
            if object["isSidechain"] as? Bool == true { return }
            guard let message = object["message"] as? [String: Any] else { return }
            if let text = message["content"] as? String, text.hasPrefix("/project-sync") {
                lastProjectSyncAt = at
            }
            if object["isMeta"] as? Bool != true {
                let texts = (message["content"] as? String).map { [$0] }
                    ?? (message["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                for text in texts {
                    guard let prompt = TranscriptState.promptText(text) else { continue }
                    addTimeline(.prompt, prompt, at: at, messageId: addMessage(fromYou: true, prompt, at: at))
                    lastTurn = TurnSummary()
                    lastTurn.prompt = prompt
                    lastTurn.startedAt = at
                }
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                if block["type"] as? String == "tool_result" { toolResult(block, at: at, result: object["toolUseResult"]) }
                if block["type"] as? String == "text", let text = block["text"] as? String,
                   text.contains("<command-name>/project-sync</command-name>") {
                    lastProjectSyncAt = at
                }
            }
        default:
            break
        }
    }

    private mutating func countUsage(_ message: [String: Any], at: Date) {
        guard let usage = message["usage"] as? [String: Any] else { return }
        if let id = message["id"] as? String {
            guard !countedMessageIds.contains(id) else { return }
            countedMessageIds.insert(id)
        }
        // Cache reads re-count the same context every turn and would dwarf real work, so they're left out
        let keys = ["input_tokens", "output_tokens", "cache_creation_input_tokens"]
        let tokens = keys.reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
        if tokens > 0 {
            self.usage.append(UsageEntry(at: at, tokens: tokens))
            lastTurn.tokens += tokens
        }
    }

    private mutating func toolUse(_ block: [String: Any], at: Date) {
        let name = block["name"] as? String ?? ""
        let input = block["input"] as? [String: Any] ?? [:]
        let stringInput = input.compactMapValues { $0 as? String }
        // Claude's questions are part of the chat: the questions, their choices, then your answer
        if name == "AskUserQuestion" {
            let questions = AskedQuestion.list(from: input)
            if !questions.isEmpty, let id = addMessage(fromYou: false, Message.questionsText(questions, answers: [:], note: nil), at: at) {
                conversation[conversation.count - 1].questions = questions
                if let toolId = block["id"] as? String { pendingQuestions[toolId] = id }
                let topic = questions.first.map { $0.header ?? $0.question } ?? ""
                addTimeline(.tool, "Ask · " + topic, at: at, messageId: id)
                return
            }
        }
        addTimeline(.tool, Session.stepLabel(tool: name, input: stringInput), at: at)
        switch name {
        case "Bash":
            let command = input["command"] as? String ?? ""
            if let id = block["id"] as? String, let check = TranscriptState.check(for: command) {
                pendingChecks[id] = check
            }
            let head = command.components(separatedBy: "<<").first ?? command
            if head.range(of: #"(^|[;&|]\s*|\n\s*)git( -C \S+)? commit\b"#, options: .regularExpression) != nil {
                lastTurn.commits += 1
            }
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            if let path = (input["file_path"] ?? input["notebook_path"]) as? String {
                editedFiles.removeAll { $0 == path }
                editedFiles.append(path)
                lastTurn.filesEdited.insert(path)
                if editedFiles.count > 50 { editedFiles.removeFirst() }
                lastEditAt = at
            }
        case "Skill":
            if (input["skill"] as? String) == "project-sync" { lastProjectSyncAt = at }
        case "TaskCreate":
            if let id = block["id"] as? String, let subject = input["subject"] as? String { pendingTaskCreates[id] = subject }
        case "TaskUpdate":
            guard let taskId = (input["taskId"] as? String) ?? (input["taskId"] as? NSNumber)?.stringValue,
                  let index = tasks.firstIndex(where: { $0.id == taskId }) else { break }
            if let subject = input["subject"] as? String, !subject.isEmpty { tasks[index].text = subject }
            switch input["status"] as? String {
            case "deleted": tasks.remove(at: index)
            case let status?: tasks[index].status = ClaudeTask.Status(raw: status)
            case nil: break
            }
        case "TodoWrite":
            let todos = input["todos"] as? [[String: Any]] ?? []
            tasks = todos.enumerated().compactMap { index, todo in
                guard let text = (todo["content"] as? String) ?? (todo["subject"] as? String) else { return nil }
                return ClaudeTask(id: "\(index + 1)", text: text, status: ClaudeTask.Status(raw: todo["status"] as? String ?? ""))
            }
        default:
            break
        }
    }

    private mutating func toolResult(_ block: [String: Any], at: Date, result: Any? = nil) {
        guard let id = block["tool_use_id"] as? String else { return }
        if let messageId = pendingQuestions.removeValue(forKey: id) {
            answer(messageId, block: block, result: result)
            return
        }
        // "Task #3 created successfully: …" gives a new task its number
        if let subject = pendingTaskCreates.removeValue(forKey: id) {
            let text = TranscriptState.text(of: block["content"])
            if let range = text.range(of: #"#\d+"#, options: .regularExpression) {
                let number = String(text[range].dropFirst())
                tasks.removeAll { $0.id == number }
                tasks.append(ClaudeTask(id: number, text: subject, status: .pending))
            }
            return
        }
        guard let check = pendingChecks.removeValue(forKey: id) else { return }
        let text = TranscriptState.text(of: block["content"])
        let isError = block["is_error"] as? Bool ?? false
        guard let result = TranscriptState.result(of: check, output: text, isError: isError) else { return }
        switch check {
        case .analyze: verification.analyze = .init(result: result, at: at)
        case .test:
            verification.test = .init(result: result, at: at)
            lastTurn.testsPassed = result == .passed
        }
        let what = check == .analyze ? "analyze" : "tests"
        addTimeline(result == .passed ? .passed : .failed, result == .passed ? "\(what) passed" : "\(what) failed", at: at)
    }

    /// Fills in how Claude's questions were answered: the picked choices (Claude Code's `toolUseResult.answers`,
    /// or the `"question"="answer"` pairs of its result text), or why there's no pick.
    private mutating func answer(_ messageId: Int, block: [String: Any], result: Any?) {
        guard let index = conversation.firstIndex(where: { $0.id == messageId }) else { return }
        let text = TranscriptState.text(of: block["content"])
        var answers = (result as? [String: Any])?["answers"] as? [String: String] ?? [:]
        if answers.isEmpty {
            let pairs = text.matches(of: #/"([^"]+)"="([^"]*)"/#)
            for pair in pairs { answers[String(pair.output.1)] = String(pair.output.2) }
        }
        var message = conversation[index]
        message.answers = answers
        if answers.isEmpty {
            if text.contains("wants to clarify") {
                message.answerNote = "You wanted to clarify"
            } else if let range = text.range(of: "the user said:\n") {
                let said = text[range.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
                message.answerNote = said.isEmpty ? "Skipped" : said
            } else {
                message.answerNote = "Skipped"
            }
        }
        message.text = Message.questionsText(message.questions, answers: message.answers, note: message.answerNote)
        conversation[index] = message
    }

    /// Only commands that actually run analyze or test count, not ones that merely mention them
    /// (e.g. text written into a file through a heredoc or echo).
    static func check(for command: String) -> Check? {
        // Ignore heredoc bodies: everything after the first "<<"
        let head = command.components(separatedBy: "<<").first ?? command
        func runs(_ tool: String) -> Bool {
            let pattern = #"(^|[;&|(]\s*|\n\s*)(fvm\s+)?(flutter|dart)\s+"# + tool + #"\b"#
            return head.range(of: pattern, options: .regularExpression) != nil
        }
        if runs("analyze") { return .analyze }
        if runs("test") { return .test }
        return nil
    }

    static func result(of check: Check, output: String, isError: Bool) -> Verification.Result? {
        switch check {
        case .analyze:
            if output.contains("No issues found") { return .passed }
            if isError || output.contains("issue") || output.contains("error •") { return .failed }
            return nil
        case .test:
            if output.contains("All tests passed") { return .passed }
            if isError || output.contains("Some tests failed") || output.contains("tests failed") { return .failed }
            return nil
        }
    }

    static func text(of content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parseDate(_ text: String) -> Date? {
        dateFormatter.date(from: text)
    }
}

/// The project a session works on: the git root of the files it edited most recently.
public enum ProjectLocator {
    public static func projectRoot(editedFiles: [String], cwd: String?, isGitRoot: (String) -> Bool) -> String? {
        let home = NSHomeDirectory()
        for path in editedFiles.reversed() + [cwd].compactMap({ $0 }) {
            var dir = (path as NSString).deletingLastPathComponent
            if path == cwd { dir = path }
            while dir.count > 1 && dir != home {
                if isGitRoot(dir) { return dir }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        return nil
    }
}

/// One item of Claude's to-do list for its work.
public struct ClaudeTask: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case pending, inProgress, done

        init(raw: String) {
            switch raw {
            case "in_progress": self = .inProgress
            case "completed": self = .done
            default: self = .pending
            }
        }
    }

    public var id: String
    public var text: String
    public var status: Status

    public init(id: String, text: String, status: Status) {
        self.id = id
        self.text = text
        self.status = status
    }
}

extension Array where Element == ClaudeTask {
    /// The last one done, the one in progress, and the next one waiting: the list at a glance.
    public var glance: (done: ClaudeTask?, current: ClaudeTask?, next: ClaudeTask?) {
        let current = first { $0.status == .inProgress }
        let done = last { $0.status == .done }
        let next = first { $0.status == .pending }
        return (done, current, next)
    }

    public var doneCount: Int { filter { $0.status == .done }.count }
}

/// What a subagent is doing, read from its own transcript (`<session>/subagents/agent-<id>.jsonl`).
public struct SubagentState: Sendable, Equatable {
    public var lastStep: String?
    /// Its last message ended its turn with no tool call after it.
    public var finished = false
    public var lastAt: Date?

    public init() {}

    public mutating func consume(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any] else { return }
        if let stamp = object["timestamp"] as? String { lastAt = TranscriptState.parseDate(stamp) ?? lastAt }
        var usedTool = false
        for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
            let input = (block["input"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            lastStep = Session.stepLabel(tool: block["name"] as? String ?? "Tool", input: input)
            usedTool = true
        }
        if usedTool { finished = false }
        if message["stop_reason"] as? String == "end_turn" { finished = true }
    }
}

/// A subagent at work in a session.
public struct Subagent: Sendable, Equatable, Identifiable {
    public var id: String
    /// "Explore", "general-purpose", …
    public var type: String
    public var description: String
    public var step: String?

    public init(id: String, type: String, description: String, step: String?) {
        self.id = id
        self.type = type
        self.description = description
        self.step = step
    }
}

