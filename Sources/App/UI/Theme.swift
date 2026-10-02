import AppKit
import SwiftUI
import WatchManCore

enum Theme {
    static let background = Color(red: 0.04, green: 0.04, blue: 0.05)
    static let card = Color.white.opacity(0.055)
    static let cardHover = Color.white.opacity(0.095)
    static let cardSelected = Color.white.opacity(0.13)
    static let primary = Palette.primary
    static let secondary = Palette.secondary
    /// The quietest readable text: 4.5:1 or better on cards, hover and black (WCAG AA at small sizes).
    /// Brighter with Increase Contrast, like the system's own label colours.
    static let faint = Palette.faint

    static let needsYou = Palette.needsYou
    static let working = Palette.working
    static let unseen = Palette.unseen
    static let idle = Color(red: 0.40, green: 0.42, blue: 0.46)
    static let failed = Palette.failed
    static let obsidian = Palette.obsidian
    /// Claude Code's own colours in the terminal: its orange, and the lavender of inline code.
    static let claude = Palette.claude
    static let code = Palette.code
    static let web = Palette.web
    /// Claude's usage limit: orange, between waiting and an error.
    static let limit = Palette.limit

    static func color(for session: Session) -> Color {
        switch session.status {
        case .needsYou: needsYou
        case .working: working
        case .finished: session.seen ? idle : unseen
        case .idle, .closed: idle
        }
    }

    static func color(for status: SessionStatus, unseen: Bool = false) -> Color {
        switch status {
        case .needsYou: needsYou
        case .working: working
        case .finished: unseen ? Theme.unseen : idle
        case .idle, .closed: idle
        }
    }

    /// The project's colour: your choice in Settings, else a stable colour from its name.
    @MainActor
    static func projectColor(_ key: String) -> Color {
        if let chosen = ProjectSettings.shared.color(for: key) { return chosen }
        return hashedColor(key)
    }

    static func hashedColor(_ key: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.99, green: 0.45, blue: 0.40), Color(red: 0.98, green: 0.72, blue: 0.30),
            Color(red: 0.55, green: 0.85, blue: 0.40), Color(red: 0.30, green: 0.80, blue: 0.75),
            Color(red: 0.38, green: 0.65, blue: 1.00), Color(red: 0.62, green: 0.50, blue: 1.00),
            Color(red: 0.95, green: 0.50, blue: 0.80), Color(red: 0.80, green: 0.66, blue: 0.50),
        ]
        // djb2: Swift's hashValue changes between launches
        let hash = key.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// App icons for the terminals, cached.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for host: HostKind) -> NSImage? {
        guard let bundleId = host.bundleIdentifier else { return nil }
        if let cached = cache[bundleId] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleId] = icon
        return icon
    }
}

struct HostIcon: View {
    let host: HostKind
    var size: CGFloat = 14

    var body: some View {
        if let icon = AppIcons.icon(for: host) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .help(host.label)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: size * 0.7))
                .foregroundStyle(Theme.faint)
                .frame(width: size, height: size)
        }
    }
}

extension Session {
    /// The project first ("Trailmap"); the session's own title when it isn't in a project folder.
    var label: String {
        let home = NSHomeDirectory()
        guard let root = projectRoot ?? (cwd != home && cwd != "/" ? cwd : nil) else { return displayName }
        let folder = (root as NSString).lastPathComponent
        guard !folder.isEmpty else { return displayName }
        // The title often spells the project better ("Trailmap" for trail_map)
        if let title, Self.plain(title) == Self.plain(folder) { return title }
        return Self.tidy(folder)
    }

    /// What the session is about, when its title says more than the project's name.
    var task: String? {
        guard let title, !title.isEmpty else { return nil }
        return Self.plain(title) == Self.plain(label) ? nil : title
    }

    private static func plain(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// "trail_map" → "Trail Map"; names that already use capitals ("PhotoBooth") stay as they are.
    static func tidy(_ folder: String) -> String {
        guard folder == folder.lowercased() else { return folder }
        return folder.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Colour key: the project folder if known, else the title.
    var colorKey: String { projectRoot ?? displayName }

    /// One line under the title: what it's doing or why it waits.
    var statusText: String {
        switch status {
        case .needsYou(let reason): reason
        case .working: lastStep ?? "Working…"
        case .finished: "Finished"
        case .idle: "Idle"
        case .closed: "Closed"
        }
    }

    /// Claude's last reply without blank lines, for previews.
    var replyPreview: String? {
        guard let lastReply else { return nil }
        let lines = lastReply.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// One line for rows: the first sentence of the result, why it waits, or what it's doing.
    var rowPreview: String {
        guard status == .finished, let preview = replyPreview else { return statusText }
        return Self.firstSentence(preview)
    }

    /// The first sentence of the first line, without Markdown's heading, list and quote marks, and with any
    /// **bold** or `code` it cuts through closed again.
    static func firstSentence(_ text: String) -> String {
        var line = text.components(separatedBy: "\n").first ?? text
        line = line.replacingOccurrences(of: #"^(#{1,6}\s+|[-*+]\s+|\d+[.)]\s+|>\s*)"#, with: "", options: .regularExpression)
        guard let end = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression) else { return line }
        var sentence = String(line[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
        if sentence.components(separatedBy: "**").count % 2 == 0 { sentence += "**" }
        if sentence.filter({ $0 == "`" }).count % 2 == 1 { sentence += "`" }
        return sentence
    }

    /// A row's bold name and its quieter companion: the project, then the task. When several listed sessions
    /// share the project ("WatchMan" three times), the task leads so each row says which one it is.
    func rowTitles(shared: Bool) -> (title: String, subtitle: String?) {
        if shared, let task { return (task, label) }
        return (label, task)
    }

    /// "now", "6m", "2h": how long it has waited or worked, or how long since it last did something.
    func timeText(now: Date) -> String {
        let reference = (status.isNeedsYou || status == .working) ? statusSince : lastActivity
        let seconds = max(0, Int(now.timeIntervalSince(reference)))
        let text: String
        switch seconds {
        case ..<60: text = "\(seconds)s"
        case ..<3600: text = "\(seconds / 60)m"
        case ..<86400: text = "\(seconds / 3600)h"
        default: text = "\(seconds / 86400)d"
        }
        return seconds < 60 ? "now" : text
    }
}
