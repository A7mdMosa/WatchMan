import Foundation
import WatchManCore

/// The app group the app shares with its widgets and its alert extension.
enum AppGroup {
    static let id = "group.com.moussa.WatchMan"
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
}

/// The last Glance, saved by the app for the widgets, the Live Activity and the alert extension's badge.
enum GlanceStore {
    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)?
            .appendingPathComponent("glance.json")
    }

    static func load() -> Glance? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Glance.self, from: data)
    }

    /// Saves it; false when it's the same as what's there already.
    @discardableResult
    static func save(_ glance: Glance) -> Bool {
        guard let url, let data = try? JSONEncoder().encode(glance) else { return false }
        if let old = try? Data(contentsOf: url), old == data { return false }
        try? data.write(to: url, options: .atomic)
        return true
    }
}

/// This iPhone's own settings, not the Mac's.
enum PhoneSettings {
    /// The Live Activity on the lock screen and in the Dynamic Island while sessions work or wait.
    static var liveActivity: Bool {
        get { AppGroup.defaults.object(forKey: "liveActivity") as? Bool ?? true }
        set { AppGroup.defaults.set(newValue, forKey: "liveActivity") }
    }
}

/// Where a widget or the Live Activity takes you: a session's page, or the app.
enum PhoneLinks {
    static let app = URL(string: "watchman://")!

    static func session(_ id: String) -> URL {
        URL(string: "watchman://session/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id))!
    }

    /// The session a link opens, if it opens one.
    static func sessionId(in url: URL) -> String? {
        guard url.scheme == "watchman", url.host == "session" else { return nil }
        let id = url.lastPathComponent
        return id.isEmpty || id == "/" ? nil : id
    }
}
