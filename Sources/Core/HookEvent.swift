import Foundation

/// One replacement in a file: Edit has one, MultiEdit several.
public struct TextEdit: Equatable, Sendable {
    public var oldString: String
    public var newString: String
    public init(oldString: String, newString: String) {
        self.oldString = oldString
        self.newString = newString
    }
}

/// One Claude Code hook event, as relayed by watchman-hook.
public struct HookEvent: Sendable, Equatable {
    public var name: String
    public var sessionId: String
    public var cwd: String
    public var transcriptPath: String?
    public var host: HostKind
    public var tty: String?
    public var claudePid: Int32?
    public var toolName: String?
    public var toolInput: [String: String]
    public var message: String?
    public var prompt: String?
    /// What went wrong, for StopFailure (when Claude Code says).
    public var error: String?
    public var permissionMode: String?
    /// MultiEdit's replacements (`tool_input.edits`, which isn't a string and so isn't in `toolInput`).
    public var edits: [TextEdit]
    /// What "Always" would allow, from PermissionRequest's `permission_suggestions`, e.g. "Bash(flutter build:*)".
    public var permissionRules: [String]
    /// AskUserQuestion's questions and their choices (`tool_input.questions`).
    public var questions: [AskedQuestion]
    /// Set when the event comes from inside a subagent (`agent_id`).
    public var agentId: String?

    public init(name: String, sessionId: String, cwd: String = "", transcriptPath: String? = nil,
                host: HostKind = .other, tty: String? = nil, claudePid: Int32? = nil,
                toolName: String? = nil, toolInput: [String: String] = [:], message: String? = nil,
                prompt: String? = nil, error: String? = nil, permissionMode: String? = nil,
                edits: [TextEdit] = [], permissionRules: [String] = [], questions: [AskedQuestion] = [],
                agentId: String? = nil) {
        self.name = name
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.host = host
        self.tty = tty
        self.claudePid = claudePid
        self.toolName = toolName
        self.toolInput = toolInput
        self.message = message
        self.prompt = prompt
        self.error = error
        self.permissionMode = permissionMode
        self.edits = edits
        self.permissionRules = permissionRules
        self.questions = questions
        self.agentId = agentId
    }

    /// Keys watchman-hook adds to Claude Code's payload.
    public enum RelayKey {
        public static let host = "wm_host"
        public static let tty = "wm_tty"
        public static let pid = "wm_pid"
    }

    public static func parse(_ data: Data) -> HookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(object)
    }

    public static func parse(_ payload: [String: Any]) -> HookEvent? {
        guard let name = payload["hook_event_name"] as? String,
              let sessionId = payload["session_id"] as? String, !sessionId.isEmpty else { return nil }
        var input: [String: String] = [:]
        var edits: [TextEdit] = []
        if let raw = payload["tool_input"] as? [String: Any] {
            for (key, value) in raw {
                if let text = value as? String { input[key] = text }
            }
            for item in raw["edits"] as? [[String: Any]] ?? [] {
                guard let old = item["old_string"] as? String, let new = item["new_string"] as? String else { continue }
                edits.append(TextEdit(oldString: old, newString: new))
            }
        }
        let tty = (payload[RelayKey.tty] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let pid = (payload[RelayKey.pid] as? NSNumber)?.int32Value
        return HookEvent(
            name: name,
            sessionId: sessionId,
            cwd: payload["cwd"] as? String ?? "",
            transcriptPath: payload["transcript_path"] as? String,
            host: HostKind(rawValue: payload[RelayKey.host] as? String ?? "") ?? .other,
            tty: tty,
            claudePid: pid,
            toolName: payload["tool_name"] as? String,
            toolInput: input,
            message: payload["message"] as? String,
            prompt: payload["prompt"] as? String,
            error: (payload["error"] as? String) ?? (payload["error_message"] as? String),
            permissionMode: payload["permission_mode"] as? String,
            edits: edits,
            permissionRules: rules(from: payload["permission_suggestions"]),
            questions: AskedQuestion.list(from: payload["tool_input"]),
            agentId: (payload["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// The rules Claude Code suggests saving with "Always": "Bash(flutter build:*)", "Edit", or a mode change.
    public static func rules(from suggestions: Any?) -> [String] {
        guard let list = suggestions as? [[String: Any]] else { return [] }
        var rules: [String] = []
        for suggestion in list {
            switch suggestion["type"] as? String {
            case "addRules", "replaceRules":
                for rule in suggestion["rules"] as? [[String: Any]] ?? [] {
                    guard let tool = rule["toolName"] as? String else { continue }
                    let content = (rule["ruleContent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    rules.append(content.map { "\(tool)(\($0))" } ?? tool)
                }
            case "setMode":
                if let mode = suggestion["mode"] as? String { rules.append("mode \(mode)") }
            case "addDirectories":
                for directory in suggestion["directories"] as? [String] ?? [] { rules.append("access to \(directory)") }
            default:
                break
            }
        }
        return rules
    }
}
