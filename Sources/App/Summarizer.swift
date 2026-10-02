import Foundation
import WatchManCore

/// Short caveman-style summaries of a session, made by Haiku through the claude CLI.
enum Summarizer {
    static func summarize(title: String, lastPrompt: String?, replies: [String]) async -> String? {
        let messages = replies.suffix(6).map { String($0.prefix(1500)) }.joined(separator: "\n---\n")
        return await run(prompt: """
            Summarize this Claude Code session so it can be read at a glance in a small panel.
            Say what was asked, what got done, and what it is waiting for, if anything.
            Caveman style: terse fragments, no filler, no markdown headings. At most 4 short lines.

            Session: \(title)
            Last request: \(lastPrompt ?? "unknown")

            Claude's recent messages:
            \(messages)
            """)
    }

    /// Runs Haiku through the claude CLI on `prompt`.
    static func run(prompt: String) async -> String? {
        guard let claude = claudeExecutable else { return nil }
        // Run from a scratch folder with only local settings, so no hooks or project files load
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("watchman-summary").path
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        let result = await Script.run("/bin/sh", ["-c", "cd \(Script.shellQuote(scratch)) && exec \(Script.shellQuote(claude)) -p --model haiku --no-session-persistence --setting-sources local --disable-slash-commands"],
                                      input: prompt, environment: environment)
        guard result.ok, !result.output.isEmpty else { return nil }
        return result.output
    }

    /// One or two plain-English sentences for the Dev Log (vault notes are never caveman style).
    static func summarizeDay(title: String, prompts: [String], replies: [String]) async -> String? {
        let prompt = """
            In one or two plain English sentences, say what was done today in this Claude Code session.
            Focus on outcomes, not file names. No markdown, no preamble.

            Session: \(title)
            What was asked: \(prompts.prefix(5).joined(separator: " | "))

            Claude's last messages:
            \(replies.map { String($0.prefix(1200)) }.joined(separator: "\n---\n"))
            """
        return await run(prompt: prompt)
    }

    static var claudeExecutable: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

extension SessionStore {
    /// Summarizes a session and shows the result in place of its last message.
    func summarize(_ id: String) async -> String? {
        guard let session = sessions[id], let path = session.transcriptPath,
              let state = await transcriptState(path: path) else { return nil }
        let summary = await Summarizer.summarize(title: session.displayName, lastPrompt: state.lastPrompt,
                                                 replies: state.recentReplies)
        if let summary { setSummary(summary, for: id) }
        return summary
    }
}
