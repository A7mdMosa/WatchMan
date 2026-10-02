import AppKit
import SwiftUI
import WatchManCore

/// Maps project folders to their Obsidian notes using project-sync's link list.
@MainActor @Observable
final class ObsidianIndex {
    static let shared = ObsidianIndex()

    /// The vault chosen in Settings, else the first Obsidian vault in iCloud Drive; nil when there's none.
    static var vault: URL? {
        let chosen = AppSettings.shared.obsidianVault
        if !chosen.isEmpty { return URL(fileURLWithPath: chosen, isDirectory: true) }
        return foundVault
    }
    static var vaultName: String? { vault?.lastPathComponent }

    /// The first folder with an `.obsidian` folder in Obsidian's iCloud Drive folder (looked up once).
    static let foundVault: URL? = {
        let documents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
        return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".obsidian").path) }
    }()

    private(set) var notes: [String: String] = [:]   // project folder → note path inside the vault
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var noteCache: [String: (at: Date, note: Note)] = [:]
    @ObservationIgnored private var todoCache: [String: (at: Date, todos: [TodoItem])] = [:]

    struct Note {
        var path: String         // inside the vault
        var title: String
        var nextTodo: String?
    }

    /// Reloads the link list at most every 10 minutes.
    func refreshIfNeeded() {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 600 { return }
        loadedAt = Date()
        let script = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/project-sync/scripts/cli.py").path
        guard FileManager.default.fileExists(atPath: script) else { return }
        Task { await reload() }
    }

    func reload() async {
        let script = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/project-sync/scripts/cli.py").path
        guard FileManager.default.fileExists(atPath: script) else { return }
        let result = await Script.run("/usr/bin/python3", [script, "links"])
        notes = ObsidianIndex.parseLinks(result.output)
        loadedAt = Date()
    }

    /// Lines look like: `~/Developer/VSCode/lumen  →  01 Projects/Lumen.md  [code_path]`
    nonisolated static func parseLinks(_ output: String) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var links: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "  →  ")
            guard parts.count == 2 else { continue }
            let folder = parts[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "~", with: home)
            var note = parts[1].trimmingCharacters(in: .whitespaces)
            if let bracket = note.range(of: "  [") { note = String(note[..<bracket.lowerBound]) }
            links[folder] = note
        }
        return links
    }

    func note(for projectRoot: String?) -> Note? {
        guard let projectRoot, let path = notes[projectRoot] else { return nil }
        if let cached = noteCache[path], Date().timeIntervalSince(cached.at) < 60 { return cached.note }
        let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let text = ObsidianIndex.vault.flatMap { try? String(contentsOf: $0.appendingPathComponent(path), encoding: .utf8) } ?? ""
        let note = Note(path: path, title: title, nextTodo: ObsidianIndex.firstOpenTodo(in: text))
        noteCache[path] = (Date(), note)
        return note
    }

    /// Every open To-do of a note (vault-relative path), soonest due first.
    func todos(notePath: String) -> [TodoItem] {
        if let cached = todoCache[notePath], Date().timeIntervalSince(cached.at) < 60 { return cached.todos }
        let text = ObsidianIndex.vault.flatMap { try? String(contentsOf: $0.appendingPathComponent(notePath), encoding: .utf8) } ?? ""
        // Checkboxes written in the note, plus the To do list project-sync keeps for its Dev card
        var fromSync: [TodoItem] = []
        if let dataPath = ObsidianTodos.projectSyncDataPath(inNote: text),
           let data = ObsidianIndex.vault.flatMap({ try? Data(contentsOf: $0.appendingPathComponent(dataPath)) }) {
            fromSync = ObsidianTodos.parseProjectSync(data)
        }
        let todos = ObsidianTodos.sorted(ObsidianTodos.merged(ObsidianTodos.parse(text), fromSync))
        todoCache[notePath] = (Date(), todos)
        return todos
    }

    /// Linked notes with their first project folder (several folders can share one note).
    var linkedNotes: [(note: String, folder: String)] {
        var firstFolder: [String: String] = [:]
        for (folder, note) in notes.sorted(by: { $0.key < $1.key }) where firstFolder[note] == nil {
            firstFolder[note] = folder
        }
        return firstFolder.map { ($0.key, $0.value) }
    }

    func openNote(path: String) {
        let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        open(Note(path: path, title: title, nextTodo: nil))
    }

    nonisolated static func firstOpenTodo(in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- [ ]") else { continue }
            var todo = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            // Drop Dataview fields like [due:: 2026-10-02]
            if let field = todo.range(of: #"\s*\[[a-z]+::[^\]]*\]"#, options: .regularExpression) {
                todo.removeSubrange(field)
            }
            if !todo.isEmpty { return todo }
        }
        return nil
    }

    func open(_ note: Note) {
        guard let vaultName = ObsidianIndex.vaultName else { return }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "vault", value: vaultName),
                                 URLQueryItem(name: "file", value: note.path)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}

/// "Obsidian · Trailmap · next: Upload on Google Play"
struct ObsidianLink: View {
    let session: Session

    var body: some View {
        if let note = ObsidianIndex.shared.note(for: session.projectRoot) {
            Button {
                ObsidianIndex.shared.open(note)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "book.closed").font(.system(size: 9, weight: .semibold))
                    Text(note.nextTodo.map { "Note · next: \($0)" } ?? "Note")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(Color(red: 0.66, green: 0.55, blue: 0.98))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color(red: 0.66, green: 0.55, blue: 0.98).opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Open \(note.title) in Obsidian")
        }
    }
}
