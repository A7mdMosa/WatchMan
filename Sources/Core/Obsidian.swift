import Foundation

/// An open `- [ ]` item in a project note.
public struct TodoItem: Sendable, Equatable, Identifiable {
    public var id: String { text }
    public var text: String
    public var due: Date?

    public init(text: String, due: Date?) {
        self.text = text
        self.due = due
    }
}

public enum ObsidianTodos {
    /// Open To-dos with their due date, from Dataview `[due:: 2026-10-02]` or Tasks `📅 2026-10-02`.
    public static func parse(_ text: String) -> [TodoItem] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- [ ]") else { return nil }
            var body = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            var due: Date?
            for pattern in [#"\[due::\s*(\d{4}-\d{2}-\d{2})\]"#, #"📅\s*(\d{4}-\d{2}-\d{2})"#] {
                guard let range = body.range(of: pattern, options: .regularExpression) else { continue }
                let match = String(body[range])
                if let dateRange = match.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
                    due = day(String(match[dateRange]))
                }
                body.removeSubrange(range)
            }
            // Drop any other Dataview fields like [priority:: high]
            while let field = body.range(of: #"\s*\[[a-zA-Z]+::[^\]]*\]"#, options: .regularExpression) {
                body.removeSubrange(field)
            }
            body = body.trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : TodoItem(text: body, due: due)
        }
    }

    /// The project-sync data file a note's Dev card reads, e.g. `05 Assets/Project Sync/CareerPath.json`.
    public static func projectSyncDataPath(inNote text: String) -> String? {
        guard let range = text.range(of: #"data:\s*"([^"]+\.json)""#, options: .regularExpression) else { return nil }
        let match = String(text[range])
        guard let open = match.firstIndex(of: "\""), let close = match.lastIndex(of: "\""), open < close else { return nil }
        return String(match[match.index(after: open)..<close])
    }

    /// Open To-dos kept by project-sync in its data file: `"todos": [{"text": …, "done": false}]`.
    public static func parseProjectSync(_ data: Data) -> [TodoItem] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let todos = object["todos"] as? [[String: Any]] else { return [] }
        return todos.compactMap { todo in
            guard todo["done"] as? Bool != true,
                  let text = (todo["text"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            return TodoItem(text: text, due: (todo["due"] as? String).flatMap(day))
        }
    }

    /// Note checkboxes first, then project-sync's list, without repeating the same To-do.
    public static func merged(_ lists: [TodoItem]...) -> [TodoItem] {
        var seen = Set<String>()
        return lists.flatMap { $0 }.filter { seen.insert($0.text.lowercased()).inserted }
    }

    /// Soonest due first; undated ones keep their note order at the end.
    public static func sorted(_ items: [TodoItem]) -> [TodoItem] {
        items.enumerated().sorted { a, b in
            switch (a.element.due, b.element.due) {
            case let (x?, y?): x != y ? x < y : a.offset < b.offset
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
    }

    static func day(_ text: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

// MARK: - Daily digest

public struct DigestSession: Sendable, Equatable {
    public var title: String
    public var prompts: [String]
    public var summary: String?
    public var filesEdited: Int
    public var tokens: Int

    public init(title: String, prompts: [String], summary: String?, filesEdited: Int, tokens: Int) {
        self.title = title
        self.prompts = prompts
        self.summary = summary
        self.filesEdited = filesEdited
        self.tokens = tokens
    }
}

public struct DigestProject: Sendable, Equatable {
    public var name: String
    public var sessions: [DigestSession]
    public var commits: [String]

    public init(name: String, sessions: [DigestSession], commits: [String]) {
        self.name = name
        self.sessions = sessions
        self.commits = commits
    }
}

/// The Dev Log note for one day, in plain English.
public enum DigestBuilder {
    public static func markdown(day: String, projects: [DigestProject]) -> String {
        let tokens = projects.flatMap(\.sessions).reduce(0) { $0 + $1.tokens }
        let sessionCount = projects.reduce(0) { $0 + $1.sessions.count }
        let names = projects.map { "\"\($0.name.replacingOccurrences(of: "\"", with: "'"))\"" }.joined(separator: ", ")
        var lines = [
            "---",
            "type: devlog",
            "date: \(day)",
            "journal: \"[[\(day)]]\"",
            "projects: [\(names)]",
            "sessions: \(sessionCount)",
            "tokens: \(tokens)",
            "---",
            "",
            "# Dev Log · \(day)",
            "",
        ]
        if projects.isEmpty {
            lines.append("No Claude Code sessions today.")
            return lines.joined(separator: "\n") + "\n"
        }
        lines.append("\(sessionCount) Claude session\(sessionCount == 1 ? "" : "s") across \(projects.count) project\(projects.count == 1 ? "" : "s"), \(UsageSummary.format(tokens)) tokens.")
        for project in projects {
            lines += ["", "## \(project.name)", ""]
            for session in project.sessions {
                var heading = "- **\(session.title)**"
                if session.filesEdited > 0 { heading += " · \(session.filesEdited) file\(session.filesEdited == 1 ? "" : "s") edited" }
                lines.append(heading)
                if let summary = session.summary, !summary.isEmpty {
                    lines.append("  - \(summary.replacingOccurrences(of: "\n", with: " "))")
                }
                let asked = session.prompts.prefix(3).map { "\"\(String($0.prefix(120)))\"" }.joined(separator: ", ")
                if !asked.isEmpty { lines.append("  - Asked: \(asked)") }
            }
            if !project.commits.isEmpty {
                lines += ["", "Commits:"]
                lines += project.commits.prefix(10).map { "- \($0)" }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
