import Foundation

/// The answer WatchMan gives a waiting PermissionRequest hook.
public enum PermissionDecision: String, Sendable {
    case allow
    case always     // allow and let Claude Code save the suggested rule
    case deny
    case ask        // no answer: Claude Code shows its own prompt

    /// Line the app sends back over the socket.
    public var socketLine: String { Self.socketLine(self, extras: nil) }

    /// The socket line, with what goes along with the decision (answers, a plan approval's mode, a message).
    public static func socketLine(_ decision: PermissionDecision, extras: ReplyExtras?) -> String {
        var object: [String: Any] = ["decision": decision.rawValue]
        if let extras {
            if let answers = extras.answers {
                object["answers"] = answers.answers
                if let response = answers.response { object["response"] = response }
            }
            if extras.keepInput { object["keepInput"] = true }
            if let mode = extras.mode { object["mode"] = mode }
            if let message = extras.message { object["message"] = message }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{\"decision\":\"\(decision.rawValue)\"}\n"
        }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    public static func parse(socketLine data: Data) -> PermissionDecision {
        parseReply(socketLine: data).decision
    }

    /// The decision and what goes along with it.
    public static func parseReply(socketLine data: Data) -> (decision: PermissionDecision, extras: ReplyExtras?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["decision"] as? String else { return (.ask, nil) }
        let decision = PermissionDecision(rawValue: raw) ?? .ask
        var extras = ReplyExtras()
        if let answers = object["answers"] as? [String: String] {
            extras.answers = QuestionAnswers(answers: answers, response: object["response"] as? String)
        }
        extras.keepInput = object["keepInput"] as? Bool ?? false
        extras.mode = object["mode"] as? String
        extras.message = object["message"] as? String
        return (decision, extras.isEmpty ? nil : extras)
    }

    /// What watchman-hook prints for Claude Code, or nil to print nothing. Claude Code turns a bare allow into a
    /// deny for tools that need you (questions, plans), so their allow carries `updatedInput`.
    public func hookOutput(permissionSuggestions: Any?, extras: ReplyExtras? = nil, toolInput: [String: Any]? = nil) -> String? {
        var decision: [String: Any]
        switch self {
        case .allow:
            decision = ["behavior": "allow"]
            if let answers = extras?.answers {
                decision["updatedInput"] = answers.updatedInput(from: toolInput ?? [:])
            } else if extras?.keepInput == true {
                decision["updatedInput"] = toolInput ?? [:]
            }
            if let mode = extras?.mode {
                decision["updatedPermissions"] = [["type": "setMode", "mode": mode, "destination": "session"]]
            }
        case .always:
            decision = ["behavior": "allow"]
            if let suggestions = permissionSuggestions as? [Any], !suggestions.isEmpty {
                decision["updatedPermissions"] = suggestions
            }
        case .deny:
            decision = ["behavior": "deny", "message": extras?.message ?? "Denied from WatchMan"]
        case .ask:
            return nil
        }
        let output: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.withoutEscapingSlashes, .sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// What goes along with a decision: answers to Claude's questions, the tool's own input handed back (a plan
/// approval), the permission mode to switch to ("acceptEdits", "default"), or a message for Claude with a deny.
public struct ReplyExtras: Equatable, Sendable {
    public var answers: QuestionAnswers?
    public var keepInput = false
    public var mode: String?
    public var message: String?

    public init(answers: QuestionAnswers? = nil, keepInput: Bool = false, mode: String? = nil, message: String? = nil) {
        self.answers = answers
        self.keepInput = keepInput
        self.mode = mode
        self.message = message
    }

    public var isEmpty: Bool { answers == nil && !keepInput && mode == nil && message == nil }
}
