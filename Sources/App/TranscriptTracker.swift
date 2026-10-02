import Foundation
import WatchManCore

/// Reads each session's transcript incrementally: only the bytes added since the last read.
actor TranscriptTracker {
    private struct Entry {
        var offset: UInt64 = 0
        var state = TranscriptState()
    }

    private var entries: [String: Entry] = [:]   // by transcript path

    func read(path: String) -> TranscriptState? {
        var entry = entries[path] ?? Entry()
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            if size < entry.offset { entry = Entry() }   // file was replaced
            try handle.seek(toOffset: entry.offset)
            let data = try handle.readToEnd() ?? Data()
            // Only consume complete lines; a partial last line is read next time
            guard let lastNewline = data.lastIndex(of: 0x0A) else {
                entries[path] = entry
                return entry.state
            }
            let complete = data[data.startIndex...lastNewline]
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                entry.state.consume(line: Data(line))
            }
            entry.offset += UInt64(complete.count)
        } catch {
            return entries[path]?.state
        }
        entries[path] = entry
        return entry.state
    }

    func forget(path: String) {
        entries[path] = nil
    }
}

/// Reads a session's subagents (`<transcript>/subagents/agent-<id>.jsonl` and its `.meta.json`) incrementally,
/// and says which are still at work.
actor SubagentTracker {
    private struct Agent {
        var offset: UInt64 = 0
        var state = SubagentState()
        var type = "agent"
        var description = ""
        var modified = Date.distantPast
    }

    private var agents: [String: Agent] = [:]   // by agent file path

    /// A subagent counts as running until its last message ends its turn, or it has been quiet for 10 minutes.
    static let quietLimit: TimeInterval = 10 * 60

    func running(transcriptPath: String, now: Date = Date()) -> [Subagent] {
        let folder = (transcriptPath as NSString).deletingPathExtension + "/subagents"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        var result: [Subagent] = []
        for file in files where file.hasPrefix("agent-") && file.hasSuffix(".jsonl") {
            let path = (folder as NSString).appendingPathComponent(file)
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            guard now.timeIntervalSince(modified) < Self.quietLimit else { continue }
            var agent = agents[path] ?? Agent()
            if agent.description.isEmpty {
                let meta = (path as NSString).deletingPathExtension + ".meta.json"
                if let data = FileManager.default.contents(atPath: meta),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    agent.type = object["agentType"] as? String ?? agent.type
                    agent.description = object["description"] as? String ?? ""
                }
            }
            if modified != agent.modified { read(path, into: &agent) }
            agent.modified = modified
            agents[path] = agent
            guard !agent.state.finished else { continue }
            let id = String(file.dropFirst("agent-".count).dropLast(".jsonl".count))
            result.append(Subagent(id: id, type: agent.type, description: agent.description, step: agent.state.lastStep))
        }
        return result.sorted { $0.id < $1.id }
    }

    private func read(_ path: String, into agent: inout Agent) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if size < agent.offset { agent.offset = 0; agent.state = SubagentState() }
        try? handle.seek(toOffset: agent.offset)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNewline]
        for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) { agent.state.consume(line: Data(line)) }
        agent.offset += UInt64(complete.count)
    }
}
