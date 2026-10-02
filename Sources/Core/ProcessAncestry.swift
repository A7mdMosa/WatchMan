import Foundation

#if os(macOS)

/// Process facts read with sysctl, without spawning `ps`.
public enum ProcessAncestry {
    public struct Info: Sendable {
        public var pid: Int32
        public var parent: Int32
        public var name: String
        public var tty: String?     // "/dev/ttys014"
    }

    public static func info(pid: Int32) -> Info? {
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &process, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let device = process.kp_eproc.e_tdev
        var tty: String?
        if device != -1, let raw = devname(device, S_IFCHR) {
            let name = String(cString: raw)
            if name.hasPrefix("tty") { tty = "/dev/" + name }
        }
        return Info(pid: pid, parent: process.kp_eproc.e_ppid, name: name, tty: tty)
    }

    /// The Claude Code process running this hook, and its terminal.
    /// Claude Code sets CLAUDE_PID for its children; otherwise walk up to the first `claude` ancestor.
    public static func claudeProcess(environment: [String: String]) -> Info? {
        if let raw = environment["CLAUDE_PID"], let pid = Int32(raw), let info = info(pid: pid) {
            return info
        }
        var pid = getppid()
        for _ in 0..<8 where pid > 1 {
            guard let info = info(pid: pid) else { return nil }
            if info.name.hasPrefix("claude") { return info }
            pid = info.parent
        }
        return nil
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
#endif
