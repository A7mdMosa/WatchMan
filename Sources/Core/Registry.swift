import Foundation

/// One entry of Claude Code's own session registry (~/.claude/sessions/<pid>.json):
/// every running Claude process, including ones started before WatchMan.
public struct RegistryEntry: Sendable, Equatable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String
    public var name: String?
    public var status: String?        // "busy", "idle", "waiting"
    public var entrypoint: String?    // "cli", "claude-vscode"
    public var updatedAt: Date?
    /// Set while Remote Control is on: the session's id in the Claude app (claude.ai/code).
    public var bridgeSessionId: String?

    public static func parse(_ data: Data) -> RegistryEntry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = object["sessionId"] as? String, !sessionId.isEmpty,
              let pid = (object["pid"] as? NSNumber)?.int32Value else { return nil }
        let millis = (object["statusUpdatedAt"] as? NSNumber) ?? (object["updatedAt"] as? NSNumber)
        return RegistryEntry(
            pid: pid,
            sessionId: sessionId,
            cwd: object["cwd"] as? String ?? "",
            name: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            status: object["status"] as? String,
            entrypoint: object["entrypoint"] as? String,
            updatedAt: millis.map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
            bridgeSessionId: (object["bridgeSessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    public var sessionStatus: SessionStatus {
        switch status {
        case "busy": .working
        case "waiting": .needsYou("Waiting for you")
        default: .idle
        }
    }
}

extension HostKind {
    /// Picks the variables host detection needs out of `ps eww` output (command line + environment).
    public static func environment(fromProcessListing line: String) -> [String: String] {
        let keys = ["TERM_PROGRAM", "__CFBundleIdentifier", "GHOSTTY_RESOURCES_DIR", "ITERM_SESSION_ID",
                    "CLAUDE_CODE_ENTRYPOINT"]
        var result: [String: String] = [:]
        for key in keys {
            guard let range = line.range(of: #"(^|\s)"# + key + #"=(\S*)"#, options: .regularExpression) else { continue }
            let match = String(line[range]).trimmingCharacters(in: .whitespaces)
            result[key] = String(match.dropFirst(key.count + 1))
        }
        return result
    }
}

extension Session {
    /// Idle for over an hour with nothing new to read: folded away in the list.
    public func isDormant(now: Date) -> Bool {
        let quiet = status == .idle || (status == .finished && seen)
        return quiet && now.timeIntervalSince(lastActivity) > 3600
    }

    /// Fills in a session found in the registry (no hook event seen yet, or registry is newer).
    public mutating func apply(_ entry: RegistryEntry, host: HostKind, tty: String?, transcriptPath: String?, now: Date) {
        pid = entry.pid
        remoteSessionId = entry.bridgeSessionId
        if cwd.isEmpty { cwd = entry.cwd }
        if title == nil { title = entry.name }
        if self.host == .other { self.host = entry.entrypoint == "claude-vscode" ? .vscodeExtension : host }
        if self.tty == nil { self.tty = tty }
        if self.transcriptPath == nil { self.transcriptPath = transcriptPath }
        let updated = entry.updatedAt ?? now
        guard updated > lastActivity || (status == .idle && entry.sessionStatus != .idle) else { return }
        // The registry says "idle" as soon as a reply ends: that's still a finished result, not idle
        if status == .finished && entry.sessionStatus == .idle { return }
        setStatus(entry.sessionStatus, at: updated)
        lastActivity = updated
    }
}
