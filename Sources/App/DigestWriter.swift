import AppKit
import WatchManCore

/// Writes the day's Dev Log note (<Dev Log folder>/YYYY-MM-DD.md in the Obsidian vault) from every transcript
/// touched today.
@MainActor
enum DigestWriter {
    struct NoVault: LocalizedError {
        var errorDescription: String? { "No Obsidian vault: choose one in Settings → Obsidian." }
    }

    /// The Dev Log folder inside the vault, as set in Settings.
    static var folderPath: String {
        let path = AppSettings.shared.devLogFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return path.isEmpty ? AppSettings.defaultDevLogFolder : path
    }
    static var folder: URL? { ObsidianIndex.vault?.appendingPathComponent(folderPath, isDirectory: true) }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Writes (or rewrites) today's note. Returns its path inside the vault.
    @discardableResult
    static func writeToday() async throws -> String {
        // Never makes a vault: without one there's nowhere to write
        guard let vault = ObsidianIndex.vault, FileManager.default.fileExists(atPath: vault.path), let folder else { throw NoVault() }
        let (day, markdown) = await buildToday(summarize: AppSettings.shared.digestUsesHaiku)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try markdown.write(to: folder.appendingPathComponent("\(day).md"), atomically: true, encoding: .utf8)
        UserDefaults.standard.set(day, forKey: "lastDigestDay")
        return "\(folderPath)/\(day).md"
    }

    /// Today's Dev Log text, without writing it.
    static func buildToday(summarize: Bool) async -> (day: String, markdown: String) {
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let day = dayString(now)
        var sessions = await Task.detached(priority: .utility) { gatherSessions(since: start) }.value

        if summarize {
            for index in sessions.indices.prefix(15) {
                sessions[index].digest.summary = await Summarizer.summarizeDay(
                    title: sessions[index].digest.title, prompts: sessions[index].digest.prompts,
                    replies: sessions[index].replies) ?? sessions[index].digest.summary
            }
        }

        // Group by project, with today's commits
        var projects: [DigestProject] = []
        let grouped = Dictionary(grouping: sessions) { $0.root ?? "" }
        for (root, items) in grouped.sorted(by: { projectName($0.key) < projectName($1.key) }) {
            let commits = root.isEmpty ? [] : await todaysCommits(root: root, since: start)
            projects.append(DigestProject(name: projectName(root), sessions: items.map(\.digest), commits: commits))
        }

        return (day, DigestBuilder.markdown(day: day, projects: projects))
    }

    private static func projectName(_ root: String) -> String {
        root.isEmpty ? "Other" : (root as NSString).lastPathComponent
    }

    private struct Gathered: Sendable {
        var digest: DigestSession
        var root: String?
        var replies: [String]
    }

    /// Blocking: reads every transcript modified today.
    nonisolated private static func gatherSessions(since start: Date) -> [Gathered] {
        let fm = FileManager.default
        var result: [Gathered] = []
        for dir in (try? fm.contentsOfDirectory(at: WatchManPaths.claudeProjectsDirectory, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= start, let data = try? Data(contentsOf: file) else { continue }
                var state = TranscriptState()
                for line in data.split(separator: 0x0A) { state.consume(line: Data(line)) }
                // A conversation moved into another session is reported there
                if state.continuedIn != nil { continue }
                let today = state.timeline.filter { $0.at >= start }
                let prompts = today.filter { $0.kind == .prompt }.map(\.text)
                let tokens = state.usage.filter { $0.at >= start }.reduce(0) { $0 + $1.tokens }
                guard !prompts.isEmpty || tokens > 0 else { continue }
                let edited = Set(today.filter { $0.kind == .tool && ($0.text.hasPrefix("Edit ·") || $0.text.hasPrefix("Write ·")) }.map(\.text))
                // Sessions that only ran slash commands (like /resume) and changed nothing aren't work
                let realPrompts = prompts.filter { !$0.hasPrefix("/") && $0.count > 6 }
                if edited.isEmpty && realPrompts.isEmpty { continue }
                let replies = today.filter { $0.kind == .reply }.map(\.text)
                let root = ProjectLocator.projectRoot(editedFiles: state.editedFiles, cwd: state.cwd) {
                    fm.fileExists(atPath: ($0 as NSString).appendingPathComponent(".git"))
                }
                let title = state.title ?? (state.cwd.map { ($0 as NSString).lastPathComponent } ?? "Session")
                result.append(Gathered(
                    digest: DigestSession(title: title, prompts: prompts, summary: replies.last, filesEdited: edited.count,
                                          tokens: tokens),
                    root: root, replies: Array(state.recentReplies.suffix(4))))
            }
        }
        return result
    }

    private static func todaysCommits(root: String, since start: Date) async -> [String] {
        let iso = ISO8601DateFormatter().string(from: start)
        let log = await Script.run("/usr/bin/git", ["-C", root, "log", "--since=\(iso)", "--pretty=format:%s"])
        return log.output.split(separator: "\n").map(String.init)
    }

    // MARK: - Schedule

    private static var timer: Task<Void, Never>?

    /// Writes the digest every evening at the set time, and catches up after the Mac wakes.
    static func startSchedule() {
        timer?.cancel()
        guard AppSettings.shared.digestEnabled else { return }
        catchUpIfMissed()
        timer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(30, nextRun().timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                catchUpIfMissed()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { catchUpIfMissed() }
        }
    }

    private static func scheduledTime(on day: Date) -> Date {
        let minutes = AppSettings.shared.digestMinutes
        return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }

    private static func nextRun() -> Date {
        let today = scheduledTime(on: Date())
        return today > Date() ? today : scheduledTime(on: Date().addingTimeInterval(24 * 3600))
    }

    /// Past today's time and today's note not written yet: write it now.
    private static func catchUpIfMissed() {
        let now = Date()
        guard AppSettings.shared.digestEnabled, now >= scheduledTime(on: now),
              UserDefaults.standard.string(forKey: "lastDigestDay") != dayString(now) else { return }
        Task { _ = try? await writeToday() }
    }
}
