import Foundation

/// A snapshot of `ps -axo pid=,ppid=,rss=,tty=,stat=,args=`.
public struct ProcessTable: Sendable {
    public struct Entry: Sendable, Equatable {
        public var pid: Int32
        public var ppid: Int32
        public var rssKB: Int
        public var tty: String      // "ttys014", or "??"
        public var stat: String
        public var args: String

        public var name: String {
            let first = args.split(separator: " ").first.map(String.init) ?? args
            return (first as NSString).lastPathComponent
        }

        public var isForeground: Bool { stat.contains("+") }
    }

    public struct Stray: Sendable, Equatable, Identifiable {
        public var id: Int32 { pid }
        public var pid: Int32
        public var kind: String
        public var rssKB: Int
    }

    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    public static func parse(_ output: String) -> ProcessTable {
        var entries: [Entry] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, let pid = Int32(fields[0]), let ppid = Int32(fields[1]),
                  let rss = Int(fields[2]) else { continue }
            entries.append(Entry(pid: pid, ppid: ppid, rssKB: rss, tty: String(fields[3]),
                                 stat: String(fields[4]), args: String(fields[5])))
        }
        return ProcessTable(entries: entries)
    }

    /// Memory of a process and everything it started (dart, gradle, MCP servers…).
    public func treeRSSKB(of pid: Int32) -> Int {
        var children: [Int32: [Entry]] = [:]
        for entry in entries { children[entry.ppid, default: []].append(entry) }
        var total = 0
        var stack = [pid]
        var seen = Set<Int32>()
        while let current = stack.popLast(), seen.insert(current).inserted {
            if let entry = entries.first(where: { $0.pid == current }) { total += entry.rssKB }
            stack.append(contentsOf: children[current, default: []].map(\.pid))
        }
        return total
    }

    /// Whether `claude` is in the foreground of a tty (so typing there reaches Claude, not a shell).
    public func claudeIsForeground(onTTY tty: String) -> Bool {
        let short = tty.replacingOccurrences(of: "/dev/", with: "")
        return entries.contains { $0.tty == short && $0.isForeground && $0.name == "claude" }
    }

    /// Heavy leftovers worth closing: Gradle and Kotlin daemons, Android emulators, orphaned Dart analyzers.
    public func strays() -> [Stray] {
        entries.compactMap { entry in
            let kind: String?
            if entry.args.contains("org.gradle.launcher.daemon") { kind = "Gradle daemon" }
            else if entry.args.contains("KotlinCompileDaemon") { kind = "Kotlin daemon" }
            else if entry.name.hasPrefix("qemu-system") { kind = "Android emulator" }
            else if entry.args.contains("analysis_server") && entry.ppid == 1 { kind = "Dart analyzer (orphan)" }
            else { kind = nil }
            return kind.map { Stray(pid: entry.pid, kind: $0, rssKB: entry.rssKB) }
        }
    }
}
