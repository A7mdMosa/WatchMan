import Foundation

/// The question Claude ended its reply with, and one-click answers for it.
public struct ClosingQuestion: Equatable, Sendable {
    public struct Answer: Equatable, Sendable {
        public var label: String   // on the button
        public var text: String    // typed into the session
    }

    public var question: String
    public var answers: [Answer]

    /// Finds a closing question in the last lines of a reply, with numbered options if Claude listed them,
    /// otherwise Yes / No for a yes-or-no question.
    public static func find(in reply: String) -> ClosingQuestion? {
        let lines = reply.split(separator: "\n").map { plain(String($0)) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let tail = Array(lines.suffix(14))
        guard let questionIndex = tail.lastIndex(where: { $0.hasSuffix("?") }) else { return nil }
        // Only a question near the end counts (Claude asks last)
        guard tail.count - questionIndex <= 8 else { return nil }
        let question = sentence(ending: tail[questionIndex])

        // Numbered options right before or after the question: "1. Fix all", "2) Only security"
        var options: [Answer] = []
        for line in tail {
            guard let match = line.range(of: #"^\(?(\d{1,2})[.)]\s+"#, options: .regularExpression) else { continue }
            let number = line[match].filter(\.isNumber)
            var label = String(line[match.upperBound...])
            if let cut = label.range(of: #"\s+[—–:-]\s+"#, options: .regularExpression) { label = String(label[..<cut.lowerBound]) }
            label = label.trimmingCharacters(in: CharacterSet(charactersIn: " .:"))
            guard !label.isEmpty else { continue }
            options.append(Answer(label: "\(number) · \(label.count > 32 ? String(label.prefix(31)) + "…" : label)",
                                  text: label))
        }
        if (2...6).contains(options.count) { return ClosingQuestion(question: question, answers: options) }

        let choices = choices(in: tail[questionIndex])
        if !choices.isEmpty {
            return ClosingQuestion(question: question, answers: choices.map { Answer(label: $0, text: $0) })
        }

        if isYesNo(question) {
            return ClosingQuestion(question: question,
                                   answers: [Answer(label: "Yes", text: "yes, go ahead"), Answer(label: "No", text: "no")])
        }
        return ClosingQuestion(question: question, answers: [])
    }

    static func isYesNo(_ question: String) -> Bool {
        let lower = question.lowercased()
        let openers = ["want me to", "should i", "shall i", "do you want", "would you like", "can i", "ok to",
                       "okay to", "is that", "are you", "do you", "ready to", "go ahead", "should we", "is it"]
        return openers.contains { lower.hasPrefix($0) || lower.contains(" \($0) ") }
            && !lower.contains(" or ")
    }

    /// Short choices after a colon: "Which icon set should I use: Lucide or Heroicons?" → Lucide, Heroicons.
    /// Two to four, each at most four words; anything longer is a sentence, not a choice.
    static func choices(in line: String) -> [String] {
        guard let colon = line.range(of: ":", options: .backwards) else { return [] }
        var tail = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard tail.hasSuffix("?") else { return [] }
        tail.removeLast()
        let parts = tail.replacingOccurrences(of: ", or ", with: ", ")
            .replacingOccurrences(of: " or ", with: ", ")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard (2...4).contains(parts.count), parts.allSatisfy({ $0.split(separator: " ").count <= 4 }) else { return [] }
        return parts
    }

    /// The sentence that ends with the question mark (drops what came before on the same line).
    static func sentence(ending line: String) -> String {
        let parts = line.split(whereSeparator: { ".!:".contains($0) })
        return (parts.last.map(String.init) ?? line).trimmingCharacters(in: .whitespaces)
    }

    /// Strips markdown emphasis, code ticks and list bullets.
    static func plain(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        for token in ["**", "__", "`"] { text = text.replacingOccurrences(of: token, with: "") }
        if text.hasPrefix("- ") || text.hasPrefix("* ") { text.removeFirst(2) }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// What the last turn (since your last prompt) did.
public struct TurnSummary: Equatable, Sendable {
    public var prompt: String?
    public var startedAt: Date?
    public var filesEdited: Set<String> = []
    public var commits = 0
    public var testsPassed: Bool?
    public var tokens = 0

    public init() {}

    public var isEmpty: Bool { filesEdited.isEmpty && commits == 0 && testsPassed == nil && tokens == 0 }
}
