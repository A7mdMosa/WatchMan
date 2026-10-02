import AppKit
import Observation
import SwiftUI
import WatchManCore

/// What a project overrides. Nil means "use the default" (by project kind, then the global setting).
struct ProjectPrefs: Codable, Equatable {
    var quickReplies: [String]?
    var starters: [String]?
    var colorHex: String?
    var sound: String?
    /// No sounds, messages or phone alerts for this project.
    var muted: Bool?
}

/// Per-project quick replies, starter skills, colour and finish sound, saved in UserDefaults.
@MainActor @Observable
final class ProjectSettings {
    static let shared = ProjectSettings()

    static let sounds = ["Glass", "Hero", "Ping", "Pop", "Purr", "Submarine", "Tink", "Funk", "Basso", "Blow",
                         "Bottle", "Frog", "Morse", "Sosumi"]

    private(set) var prefs: [String: ProjectPrefs] = [:]
    /// Project folders seen in sessions, so they can be configured.
    private(set) var seenRoots: Set<String> = []
    @ObservationIgnored private var kinds: [String: ProjectKind] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        if let data = defaults.data(forKey: "projectPrefs"),
           let decoded = try? JSONDecoder().decode([String: ProjectPrefs].self, from: data) {
            prefs = decoded
        }
        seenRoots = Set(defaults.stringArray(forKey: "seenProjectRoots") ?? [])
    }

    func prefs(for root: String) -> ProjectPrefs { prefs[root] ?? ProjectPrefs() }

    func isMuted(_ root: String?) -> Bool {
        guard let root else { return false }
        return prefs[root]?.muted == true
    }

    func update(_ root: String, _ change: (inout ProjectPrefs) -> Void) {
        var value = prefs(for: root)
        change(&value)
        prefs[root] = value
        if let data = try? JSONEncoder().encode(prefs) { defaults.set(data, forKey: "projectPrefs") }
    }

    func noteSeen(_ root: String?) {
        guard let root, !seenRoots.contains(root) else { return }
        seenRoots.insert(root)
        defaults.set(Array(seenRoots), forKey: "seenProjectRoots")
    }

    /// Every project worth listing in Settings: linked in Obsidian or seen in a session.
    var knownProjects: [String] {
        Array(Set(ObsidianIndex.shared.notes.keys).union(seenRoots))
            .sorted { ($0 as NSString).lastPathComponent.lowercased() < ($1 as NSString).lastPathComponent.lowercased() }
    }

    func kind(of root: String) -> ProjectKind {
        if let known = kinds[root] { return known }
        let kind = ProjectKind.detect(root: root) { FileManager.default.fileExists(atPath: $0) }
        kinds[root] = kind
        return kind
    }

    func quickReplies(for root: String?) -> [String] {
        guard let root else { return AppSettings.shared.quickReplies }
        return prefs(for: root).quickReplies ?? kind(of: root).defaultQuickReplies ?? AppSettings.shared.quickReplies
    }

    func starters(for root: String) -> [String] {
        prefs(for: root).starters ?? kind(of: root).defaultStarters ?? ["/app-audit", "/project-sync", "/code-review"]
    }

    func color(for root: String?) -> Color? {
        guard let root, let hex = prefs(for: root).colorHex else { return nil }
        return Color(hex: hex)
    }

    func sound(for root: String?) -> String? {
        guard let root else { return nil }
        return prefs(for: root).sound
    }
}

extension Color {
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    var hexString: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }
}
