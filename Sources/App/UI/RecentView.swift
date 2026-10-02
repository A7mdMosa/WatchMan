import SwiftUI
import WatchManCore

/// A closed session that can be resumed.
struct RecentSession: Identifiable, Sendable {
    let id: String          // session id (transcript file name)
    let title: String
    let cwd: String
    let modified: Date
}

enum RecentSessions {
    /// Transcripts touched in the last week, newest first. Reads only the tail of each file.
    static func load(excluding live: Set<String>, limit: Int = 40) async -> [RecentSession] {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let root = WatchManPaths.claudeProjectsDirectory
            let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
            var files: [(URL, Date)] = []
            for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                where file.pathExtension == "jsonl" {
                    let id = file.deletingPathExtension().lastPathComponent
                    guard !live.contains(id),
                          let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                          modified > weekAgo else { continue }
                    files.append((file, modified))
                }
            }
            files.sort { $0.1 > $1.1 }
            return files.prefix(limit).compactMap { file, modified in
                guard let info = tailInfo(file) else { return nil }
                return RecentSession(id: file.deletingPathExtension().lastPathComponent, title: info.title,
                                     cwd: info.cwd, modified: modified)
            }
        }.value
    }

    /// Title and folder from the last 64 KB of a transcript.
    static func tailInfo(_ url: URL) -> (title: String, cwd: String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        var state = TranscriptState()
        for line in data.split(separator: 0x0A) { state.consume(line: Data(line)) }
        guard let cwd = state.cwd else { return nil }
        let title = state.title ?? state.lastPrompt.map { String($0.prefix(60)) } ?? (cwd as NSString).lastPathComponent
        return (title, cwd)
    }
}

struct RecentView: View {
    let store: SessionStore
    @State private var sessions: [RecentSession] = []
    @State private var loading = true
    @State private var query = ""
    /// Nil until you search; then what every past chat on this Mac matched.
    @State private var hits: [ChatHit]?
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.faint)
                TextField("Search every past chat", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if searching { ProgressView().controlSize(.mini) }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.faint).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            // Three letters or more, a moment after you stop typing
            .task(id: query) {
                let text = query.trimmingCharacters(in: .whitespaces)
                guard text.count >= 3 else { hits = nil; searching = false; return }
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                searching = true
                let found = await ChatSearch.run(text)
                guard !Task.isCancelled else { return }
                hits = found
                searching = false
            }
            if let hits {
                searchResults(hits)
            } else {
                recent
            }
        }
        .task {
            sessions = await RecentSessions.load(excluding: Set(store.sessions.keys))
            loading = false
        }
    }

    @ViewBuilder
    private func searchResults(_ hits: [ChatHit]) -> some View {
        Text(hits.isEmpty ? "No past chat mentions that." : "\(hits.count == ChatSearch.limit ? "The \(hits.count) newest" : "\(hits.count)") chats mention it · click to resume")
            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 3) {
                ForEach(hits) { hit in ChatHitRow(hit: hit, query: query) }
            }
        }
        .frame(maxHeight: 420)
    }

    @ViewBuilder
    private var recent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Closed in the last 7 days · click to resume in Ghostty")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            if loading {
                ProgressView().controlSize(.small)
            } else if sessions.isEmpty {
                Text("Nothing to resume.").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(sessions) { RecentRow(session: $0) }
                    }
                }
                .frame(height: min(CGFloat(sessions.count) * 40, 360))
            }
        }
    }
}

/// A past chat that mentions what you searched: its title, folder and when, and the words around the match.
private struct ChatHitRow: View {
    let hit: ChatHit
    let query: String
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(hit.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                Text((hit.cwd as NSString).lastPathComponent).font(.system(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
                Spacer()
                Text(hit.modified.formatted(.relative(presentation: .named))).font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            if let snippet = hit.snippet {
                Text(highlighted(snippet)).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hovering ? Theme.cardHover : Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            Task { _ = await Hosts.startSession(in: hit.cwd, command: "claude --resume \(hit.id)") }
            NotificationCenter.default.post(name: .watchManCollapse, object: nil)
        }
        .help("Resume this conversation in a new Ghostty tab")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// The match in the primary colour and bold.
    private func highlighted(_ text: String) -> AttributedString {
        var styled = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespaces)
        if let range = styled.range(of: needle, options: .caseInsensitive) {
            styled[range].foregroundColor = Theme.primary
            styled[range].font = .system(size: 12, weight: .semibold)
        }
        return styled
    }
}

private struct RecentRow: View {
    let session: RecentSession
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
            }
            Spacer()
            Text(session.modified, style: .relative)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(hovering ? Theme.cardHover : Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            Task { _ = await Hosts.startSession(in: session.cwd, command: "claude --resume \(session.id)") }
            NotificationCenter.default.post(name: .watchManCollapse, object: nil)
        }
        .help("Resume this conversation in a new Ghostty tab")
    }
}

/// "+ New": start Claude in a project, optionally with a skill.
struct NewSessionButton: View {
    let store: SessionStore
    /// Where "From a To-do" and "Resume" go (the notch panel's pages unless told otherwise).
    var onPage: ((SessionStore.OtherPage) -> Void)? = nil

    var body: some View {
        Menu {
            NewSessionMenuItems(store: store, onPage: onPage)
        } label: {
            Label("New", systemImage: "plus")
                .font(.system(size: 11.5, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(Theme.primary)
        .onAppear { ObsidianIndex.shared.refreshIfNeeded() }
    }

    /// Projects linked in Obsidian, grouped by their parent folder (e.g. "Feb_2026", "VSCode").
    static var groups: [(name: String, folders: [String])] {
        let folders = Set(ObsidianIndex.shared.notes.keys)
        let grouped = Dictionary(grouping: folders) { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent }
        return grouped.keys.sorted().map { key in
            (key, grouped[key, default: []].sorted { ($0 as NSString).lastPathComponent.lowercased() < ($1 as NSString).lastPathComponent.lowercased() })
        }
    }

    static func start(in folder: String, with starter: String) {
        let command = starter.isEmpty ? "claude" : "claude \(Script.shellQuote(starter))"
        Task { _ = await Hosts.startSession(in: folder, command: command) }
        NotificationCenter.default.post(name: .watchManCollapse, object: nil)
    }
}

/// The New menu's items: a project to start Claude in, a To-do, an earlier session, or the home folder.
struct NewSessionMenuItems: View {
    let store: SessionStore
    var onPage: ((SessionStore.OtherPage) -> Void)? = nil

    var body: some View {
        ForEach(NewSessionButton.groups, id: \.name) { group in
            Menu(group.name) {
                ForEach(group.folders, id: \.self) { folder in
                    Menu((folder as NSString).lastPathComponent) {
                        ForEach([""] + ProjectSettings.shared.starters(for: folder), id: \.self) { starter in
                            Button(starter.isEmpty ? "Start Claude" : "Start with \(starter)") {
                                NewSessionButton.start(in: folder, with: starter)
                            }
                        }
                    }
                }
            }
        }
        Divider()
        Button("From a To-do…") { if let onPage { onPage(.todos) } else { store.otherPage = .todos } }
        Button("Resume an Earlier Session…") { if let onPage { onPage(.recent) } else { store.otherPage = .recent } }
        Divider()
        Button("Start Claude in Home Folder") {
            NewSessionButton.start(in: FileManager.default.homeDirectoryForCurrentUser.path, with: "")
        }
    }
}
