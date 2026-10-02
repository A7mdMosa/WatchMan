import Foundation
import WatchManCore

/// Finds every running Claude Code session from Claude's own registry (~/.claude/sessions/<pid>.json),
/// so sessions started before WatchMan show up without waiting for their next event.
enum SessionDiscovery {
    struct Found: Sendable {
        var entry: RegistryEntry
        var host: HostKind
        var tty: String?
        var transcriptPath: String?
    }

    static func scan() async -> [Found] {
        await Task.detached(priority: .utility) { scanBlocking() }.value
    }

    private static func scanBlocking() -> [Found] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let registry = home.appendingPathComponent(".claude/sessions")
        let entries = ((try? fm.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap(RegistryEntry.parse) }
            .filter { ProcessAncestry.isAlive($0.pid) && !($0.entrypoint ?? "").hasPrefix("sdk") }
        guard !entries.isEmpty else { return [] }

        // Which terminal each CLI session runs in, from its environment
        var environments: [Int32: [String: String]] = [:]
        let cliPids = entries.filter { $0.entrypoint != "claude-vscode" }.map { String($0.pid) }
        if !cliPids.isEmpty {
            let listing = Script.runBlocking("/bin/ps", ["eww", "-o", "pid=,command=", "-p", cliPids.joined(separator: ",")])
            for line in listing.output.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard let pid = text.split(separator: " ").first.flatMap({ Int32($0) }) else { continue }
                environments[pid] = HostKind.environment(fromProcessListing: text)
            }
        }

        let projectDirs = (try? fm.contentsOfDirectory(at: WatchManPaths.claudeProjectsDirectory, includingPropertiesForKeys: nil)) ?? []
        return entries.map { entry in
            let host = environments[entry.pid].map { HostKind.detect(environment: $0) } ?? .other
            let transcript = projectDirs
                .map { $0.appendingPathComponent("\(entry.sessionId).jsonl").path }
                .first { fm.fileExists(atPath: $0) }
            return Found(entry: entry, host: host, tty: ProcessAncestry.info(pid: entry.pid)?.tty, transcriptPath: transcript)
        }
    }
}

extension SessionStore {
    /// Adds sessions found in Claude's registry and refreshes ones hooks haven't reported on lately.
    func discover() {
        Task {
            let found = await SessionDiscovery.scan()
            merge(found)
        }
    }

    func merge(_ found: [SessionDiscovery.Found]) {
        let now = Date()
        for item in found {
            let id = item.entry.sessionId
            let isNew = sessions[id] == nil
            var session = sessions[id] ?? Session(id: id, cwd: item.entry.cwd, host: .other, now: item.entry.updatedAt ?? now)
            session.apply(item.entry, host: item.host, tty: item.tty, transcriptPath: item.transcriptPath, now: now)
            if sessions[id] != session { setSession(session) }
            if isNew { refreshTranscript(id) }
        }
    }
}
