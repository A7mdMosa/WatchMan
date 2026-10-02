import AppKit
import SwiftUI
import WatchManCore

extension SessionStore {
    /// Status line data from a session: the plan's usage for everyone, the context for that session.
    func applyStatusLine(_ info: StatusLineInfo) {
        if let usage = info.usage, usage != planUsage {
            planUsage = usage
            warnIfHigh(usage)
        }
        if let id = info.sessionId, let percent = info.contextPercent, var session = sessions[id],
           session.contextPercent.map({ Int($0) }) != Int(percent) {
            session.contextPercent = percent
            setSession(session)
        }
    }

    /// One message when the session or the week passes 80%, once per window.
    private func warnIfHigh(_ usage: PlanUsage) {
        for (name, window) in [("Session", usage.session), ("Weekly", usage.week)] {
            guard let window, window.percent >= 80, let resets = window.resetsAt, !usageWarned.contains(resets) else { continue }
            usageWarned.insert(resets)
            guard AppSettings.shared.notchPopEnabled, !Quiet.isOn else { continue }
            onNews?(.usage(window: name, percent: Int(window.percent), resets: window.resetText))
        }
    }

    /// What the last status line wrote (your script saves it), so the numbers show before the next refresh.
    func seedPlanUsage() {
        let url = URL(fileURLWithPath: "/tmp/statusline_debug.json")
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 6 * 3600,
              let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var info = StatusLineInfo.parse(object)
        // Old enough that a window may have reset: only the plan's numbers whose window is still running
        if let session = info.usage?.session, let resets = session.resetsAt, resets < Date() { info.usage?.session = nil }
        if let week = info.usage?.week, let resets = week.resetsAt, resets < Date() { info.usage?.week = nil }
        if info.usage?.session == nil, info.usage?.week == nil { info.usage = nil }
        // Seeding must not warn: the message is for a change you'd miss, not for old news
        if let usage = info.usage {
            for window in [usage.session, usage.week].compactMap({ $0 }) where window.percent >= 80 {
                if let resets = window.resetsAt { usageWarned.insert(resets) }
            }
        }
        applyStatusLine(info)
    }
}

extension UsageWindow {
    /// "3:00 PM" today, "Sun 9:00 AM" later in the week.
    var resetText: String? {
        guard let resetsAt else { return nil }
        if Calendar.current.isDateInToday(resetsAt) { return resetsAt.formatted(date: .omitted, time: .shortened) }
        return resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// Green, then orange from 70%, red from 90%.
    var color: Color { percent >= 90 ? Theme.failed : percent >= 70 ? Theme.limit : Theme.working }
}

/// The status line wrapper in ~/.claude/settings.json that sends WatchMan the plan's usage.
enum StatusLineRelay {
    static var connected: Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = (settings["statusLine"] as? [String: Any])?["command"] as? String else { return false }
        return command.contains("watchman-hook") && command.contains("--statusline")
    }

    /// Wraps (or restores) your status line command; it keeps printing exactly what it printed.
    static func set(_ on: Bool) async -> Script.Result {
        guard let script = Bundle.main.path(forResource: "install-hooks", ofType: "py") else {
            return Script.Result(status: -1, output: "install-hooks.py missing from the app")
        }
        return await Script.run("/usr/bin/python3", [script, "--hook", WatchManPaths.hookBinaryPath, "--statusline", on ? "on" : "off"])
    }
}
