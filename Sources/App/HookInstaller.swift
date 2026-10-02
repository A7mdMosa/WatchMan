import Foundation
import WatchManCore

/// Keeps the hook binary in Application Support and edits ~/.claude/settings.json through install-hooks.py.
enum HookInstaller {
    /// Copies the bundled watchman-hook next to the socket if it changed (atomic, so running hooks aren't hit).
    static func installBinary() {
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "watchman-hook"),
              let data = try? Data(contentsOf: bundled) else { return }
        let target = URL(fileURLWithPath: WatchManPaths.hookBinaryPath)
        if (try? Data(contentsOf: target)) == data { return }
        try? FileManager.default.createDirectory(at: WatchManPaths.supportDirectory, withIntermediateDirectories: true)
        let temp = target.appendingPathExtension("new")
        do {
            try data.write(to: temp)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            if !FileManager.default.fileExists(atPath: target.path) {
                try? data.write(to: target)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            }
        }
    }

    /// How long Claude Code waits for WatchMan's PermissionRequest hook (seconds), read from settings.json.
    /// Holds must stay below it, or Claude Code kills the hook while WatchMan still holds the prompt.
    @MainActor static var installedPermissionTimeout: Double = readPermissionTimeout()

    static func readPermissionTimeout() -> Double {
        guard let data = FileManager.default.contents(atPath: WatchManPaths.claudeSettingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any],
              let permission = hooks["PermissionRequest"] as? [[String: Any]] else { return 60 }
        let timeouts = permission.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .filter { ($0["command"] as? String)?.contains("watchman-hook") == true }
            .compactMap { ($0["timeout"] as? NSNumber)?.doubleValue }
        // Claude Code's default hook timeout is 60 s when none is set
        return timeouts.min() ?? 60
    }

    /// Installed by an older WatchMan with a shorter permission timeout: reinstall (with a backup).
    @MainActor static func updateIfOutdated() async {
        installedPermissionTimeout = readPermissionTimeout()
        guard hooksInstalled, installedPermissionTimeout < 600 else { return }
        let result = await run(remove: false)
        installedPermissionTimeout = readPermissionTimeout()
        Log.info("updated hooks for longer permission holds: \(result.output)")
    }

    static var hooksInstalled: Bool {
        guard let text = try? String(contentsOfFile: WatchManPaths.claudeSettingsPath, encoding: .utf8) else { return false }
        return text.contains(WatchManPaths.hookBinaryPath)
    }

    /// Adds or removes WatchMan's hooks. Returns the script's output (includes the backup path).
    static func run(remove: Bool) async -> Script.Result {
        guard let script = Bundle.main.path(forResource: "install-hooks", ofType: "py") else {
            return Script.Result(status: -1, output: "install-hooks.py missing from the app")
        }
        var arguments = [script, "--hook", WatchManPaths.hookBinaryPath]
        if remove { arguments.append("--remove") }
        return await Script.run("/usr/bin/python3", arguments)
    }
}
