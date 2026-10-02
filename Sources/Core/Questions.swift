import Foundation

/// One question Claude asks with its AskUserQuestion tool: the choices it offers, and whether several can be picked.
public struct AskedQuestion: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public var label: String
        public var description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public var question: String
    /// The short tag Claude Code shows above it ("Back link").
    public var header: String?
    public var options: [Option]
    public var multiSelect: Bool

    public init(question: String, header: String? = nil, options: [Option], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    /// The questions in a tool input (`tool_input.questions`).
    public static func list(from toolInput: Any?) -> [AskedQuestion] {
        guard let raw = (toolInput as? [String: Any])?["questions"] as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            guard let question = item["question"] as? String, !question.isEmpty else { return nil }
            let options = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> Option? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                return Option(label: label, description: (option["description"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
            return AskedQuestion(question: question, header: (item["header"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                 options: options, multiSelect: item["multiSelect"] as? Bool ?? false)
        }
    }
}

/// Answers to Claude's questions, sent back through the PermissionRequest hook: the picked labels by question
/// (several picks joined with ", ", the way Claude Code writes them), or your own words instead.
public struct QuestionAnswers: Codable, Equatable, Sendable {
    public var answers: [String: String]
    public var response: String?

    public init(answers: [String: String] = [:], response: String? = nil) {
        self.answers = answers
        self.response = response
    }

    /// The question tool's input with the answers added, for the hook's `updatedInput`.
    public func updatedInput(from toolInput: [String: Any]) -> [String: Any] {
        var input = toolInput
        input["answers"] = answers
        if let response, !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { input["response"] = response }
        return input
    }
}
