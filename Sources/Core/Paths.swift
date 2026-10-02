import Foundation

/// Where WatchMan keeps its socket and hook binary.
public enum WatchManPaths {
    public static var supportDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/WatchMan", isDirectory: true)
    }

    public static var socketPath: String {
        supportDirectory.appendingPathComponent("wm.sock").path
    }

    public static var hookBinaryPath: String {
        supportDirectory.appendingPathComponent("watchman-hook").path
    }

    public static var claudeSettingsPath: String {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json").path
    }

    public static var claudeProjectsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)
    }
}
