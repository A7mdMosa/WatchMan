import Foundation
import WatchManCore

/// A past chat that mentions what you searched for.
struct ChatHit: Identifiable, Sendable {
    let id: String          // the session id (transcript file name), for claude --resume
    let title: String
    let cwd: String
    let modified: Date
    /// The words around the match in your prompt or Claude's message (nil when it matched only in a tool's output).
    let snippet: String?
}

/// Searches every transcript on this Mac (~/.claude/projects) for some words, newest chats first.
enum ChatSearch {
    static let limit = 30

    static func run(_ query: String) async -> [ChatHit] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let root = WatchManPaths.claudeProjectsDirectory
            // Chats only, not the subagents' transcripts kept in folders beside them
            var files: [URL] = []
            for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "jsonl" {
                    files.append(file)
                }
            }
            let needle = Array(query.lowercased().utf8)
            let lock = NSLock()
            var found: [(URL, Date)] = []
            // Every file at once, each memory-mapped and scanned for the bytes: a couple of GB in about a second
            DispatchQueue.concurrentPerform(iterations: files.count) { index in
                let url = files[index]
                guard contains(url, needle),
                      let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return }
                lock.lock()
                found.append((url, modified))
                lock.unlock()
            }
            return found.sorted { $0.1 > $1.1 }.prefix(limit).compactMap { url, modified in
                guard let info = RecentSessions.tailInfo(url) else { return nil }
                return ChatHit(id: url.deletingPathExtension().lastPathComponent, title: info.title, cwd: info.cwd,
                               modified: modified, snippet: snippet(in: url, query: query))
            }
        }.value
    }

    /// Whether a file holds the bytes, ignoring the case of ASCII letters (`needle` is lowercased).
    static func contains(_ url: URL, _ needle: [UInt8]) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let count = raw.count, length = needle.count
            guard length > 0, count >= length else { return false }
            let first = needle[0]
            let upper: UInt8 = (97...122).contains(first) ? first - 32 : first
            func next(_ byte: UInt8, from: Int) -> Int {
                guard from < count, let hit = memchr(base + from, Int32(byte), count - from) else { return -1 }
                return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            }
            // The next place each case of the first letter starts, moved on only when used
            var lower = next(first, from: 0)
            var capital = upper == first ? -1 : next(upper, from: 0)
            while lower >= 0 || capital >= 0 {
                let at = capital < 0 || (lower >= 0 && lower < capital) ? lower : capital
                if at > count - length { return false }
                var index = 1
                while index < length {
                    var byte = base[at + index]
                    if byte >= 65 && byte <= 90 { byte += 32 }
                    if byte != needle[index] { break }
                    index += 1
                }
                if index == length { return true }
                if at == lower { lower = next(first, from: at + 1) } else { capital = next(upper, from: at + 1) }
            }
            return false
        }
    }

    /// The latest prompt or message containing the words, cut to about 140 characters around them.
    static func snippet(in url: URL, query: String) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let needle = query.lowercased()
        for line in data.split(separator: 0x0A).reversed() {
            guard let text = String(data: line, encoding: .utf8), text.lowercased().contains(needle),
                  let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  ["user", "assistant"].contains(object["type"] as? String ?? ""),
                  let message = object["message"] as? [String: Any] else { continue }
            let words: String
            if let content = message["content"] as? String {
                words = content
            } else if let blocks = message["content"] as? [[String: Any]] {
                words = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
            } else {
                continue
            }
            let flat = words.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard let range = flat.range(of: query, options: .caseInsensitive) else { continue }
            let start = flat.index(range.lowerBound, offsetBy: -60, limitedBy: flat.startIndex) ?? flat.startIndex
            let end = flat.index(range.upperBound, offsetBy: 80, limitedBy: flat.endIndex) ?? flat.endIndex
            return (start > flat.startIndex ? "…" : "") + flat[start..<end].trimmingCharacters(in: .whitespaces) + (end < flat.endIndex ? "…" : "")
        }
        return nil
    }
}
