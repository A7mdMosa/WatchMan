import SwiftUI
import WatchManCore

// MARK: - Resume and search

/// Earlier chats to pick up again, and a search through every past chat on the Mac.
struct ResumeScreen: View {
    let store: PhoneStore
    @State private var query = ""
    @State private var newSession = false
    @State private var resuming: PastChat?

    private var text: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searching: Bool { text.count >= 3 }
    private var result: ChatSearchResult? {
        guard let search = store.extras?.search, search.query.caseInsensitiveCompare(text) == .orderedSame else { return nil }
        return search
    }

    var body: some View {
        NavigationStack {
            List {
                if searching {
                    Section {
                        if let result {
                            if result.hits.isEmpty { Text("No past chat mentions that.").foregroundStyle(.secondary) }
                            ForEach(result.hits) { chat in PastChatRow(chat: chat) { resuming = chat } }
                        } else {
                            WaitingForMac(text: "Searching your Mac…")
                        }
                    } header: {
                        if let result, !result.hits.isEmpty {
                            Text(result.limited ? "The \(result.hits.count) newest chats" : "\(result.hits.count) chats")
                        }
                    }
                } else {
                    Section {
                        if let recent = store.extras?.recent {
                            if recent.isEmpty { Text("Nothing closed in the last week.").foregroundStyle(.secondary) }
                            ForEach(recent) { chat in PastChatRow(chat: chat) { resuming = chat } }
                        } else {
                            WaitingForMac()
                        }
                    } header: {
                        Text("Closed in the last 7 days")
                    } footer: {
                        MacNoteLine(store: store)
                    }
                }
            }
            .navigationTitle("Resume")
            .searchable(text: $query, prompt: "Search every past chat")
            .toolbar {
                Button { newSession = true } label: { Label("New Session", systemImage: "plus") }
            }
            .sheet(isPresented: $newSession) { NewSessionSheet(store: store) }
            .confirmsResume($resuming, store: store)
            .refreshable { await store.ask(.refresh(.recent)) }
        }
        .task { await store.ask(.refresh(.recent)) }
        // Three letters or more, a moment after you stop typing
        .task(id: query) {
            guard searching else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await store.ask(.search(text))
        }
    }
}

/// A past chat: its title, the matching words when searched, its project and when it was last used.
struct PastChatRow: View {
    let chat: PastChat
    let resume: () -> Void

    var body: some View {
        Button(action: resume) {
            HStack(spacing: 12) {
                ProjectBadge(name: chat.folderName, key: chat.folder)
                VStack(alignment: .leading, spacing: 3) {
                    Text(chat.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                    if let snippet = chat.snippet {
                        Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        Text(chat.folderName)
                        Text("·")
                        Text(chat.modified, format: .relative(presentation: .named))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityHint("Resumes this chat in a new terminal tab on the Mac")
    }
}

extension View {
    /// Asks before picking a past chat up again on the Mac.
    func confirmsResume(_ chat: Binding<PastChat?>, store: PhoneStore) -> some View {
        confirmationDialog("Resume this chat on the Mac?", isPresented: Binding(get: { chat.wrappedValue != nil }, set: { if !$0 { chat.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: chat.wrappedValue) { past in
            Button("Resume in a New Tab") { Task { await store.ask(.resume(chatId: past.id, folder: past.folder)) } }
        } message: { past in
            Text("\(past.title)\nin \(past.folderName)")
        }
    }
}

// MARK: - New session

/// Starts Claude in a project on the Mac: plain, with a first message, a starter skill, or on a To-do.
struct NewSessionSheet: View {
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    private var groups: [(name: String, projects: [ProjectSnapshot])] {
        let projects = (store.extras?.projects ?? []).filter {
            filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)
        }
        return Dictionary(grouping: projects, by: \.group).keys.sorted().map { key in
            (key, projects.filter { $0.group == key })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if store.extras?.projects == nil {
                    WaitingForMac(text: "Reading your projects…")
                }
                ForEach(groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.projects) { project in
                            NavigationLink {
                                StartScreen(store: store, project: project) { dismiss() }
                            } label: {
                                HStack(spacing: 12) {
                                    ProjectBadge(name: project.name, key: project.root)
                                    Text(project.name)
                                    Spacer()
                                    if !project.todos.isEmpty {
                                        Text("\(project.todos.count)").font(.caption).foregroundStyle(.secondary)
                                            .accessibilityLabel("\(project.todos.count) To-dos")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $filter, prompt: "Projects")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task { await store.ask(.refresh(.projects)) }
    }
}

/// One project: start Claude there with a message, a starter, or one of its To-dos.
struct StartScreen: View {
    let store: PhoneStore
    let project: ProjectSnapshot
    let done: () -> Void
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                TextField("First message (optional)", text: $message, axis: .vertical)
                    .lineLimit(2...6)
                Button {
                    start(message)
                } label: {
                    Label("Start Claude", systemImage: "play.fill")
                }
            } footer: {
                Text("Opens a new terminal tab on the Mac in \(project.root).")
            }
            if !project.starters.isEmpty {
                Section("Start with") {
                    ForEach(project.starters, id: \.self) { starter in
                        Button(starter) { start(starter) }
                    }
                }
            }
            if !project.todos.isEmpty {
                Section("From a To-do") {
                    ForEach(project.todos, id: \.text) { todo in
                        Button { start(todo.prompt) } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(todo.text).foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                if let due = todo.due { DueText(due: due) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(project.name)
    }

    private func start(_ prompt: String) {
        Task { await store.ask(.start(folder: project.root, prompt: prompt), followUp: false) }
        done()
        // The new session shows up in Sessions once Claude starts
        Task {
            for wait in [3.0, 6.0] {
                try? await Task.sleep(for: .seconds(wait))
                await store.refresh()
            }
        }
    }
}

// MARK: - System

/// The Mac's memory, what each session uses, leftovers to quit, tokens, and the Dev Log.
struct SystemScreen: View {
    let store: PhoneStore
    @State private var quitting: SystemSnapshot.Leftover?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let system = store.extras?.system {
                    memory(system)
                    if !system.sessions.isEmpty {
                        Section("Memory by session") {
                            ForEach(system.sessions, id: \.name) { item in
                                LabeledContent(item.name, value: "\(item.megabytes) MB")
                            }
                        }
                    }
                    if !system.leftovers.isEmpty {
                        Section {
                            ForEach(system.leftovers) { leftover in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(leftover.kind)
                                        Text("\(leftover.megabytes) MB").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Quit", role: .destructive) { quitting = leftover }
                                        .buttonStyle(.bordered)
                                }
                            }
                        } header: {
                            Text("Leftovers you can close")
                        } footer: {
                            Text("Gradle, emulators and analyzers start again when they're needed.")
                        }
                    }
                    tokens(system)
                } else {
                    WaitingForMac(text: "Reading your Mac…")
                }
                Section {
                    Button { Task { await store.ask(.writeDevLog) } } label: {
                        Label("Write today's Dev Log now", systemImage: "book.pages")
                    }
                } header: {
                    Text("Dev Log")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Today's note in Obsidian: what every session did, with links.")
                        MacNoteLine(store: store)
                    }
                }
            }
            .navigationTitle("System")
            .refreshable { await store.ask(.refresh(.system)) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Quit \(quitting?.kind ?? "")?", isPresented: Binding(get: { quitting != nil }, set: { if !$0 { quitting = nil } }),
                                titleVisibility: .visible, presenting: quitting) { leftover in
                Button("Quit", role: .destructive) { Task { await store.ask(.quitLeftover(pid: leftover.pid)) } }
            } message: { leftover in
                Text("Process \(leftover.pid) uses \(leftover.megabytes) MB.")
            }
        }
        // Fresh numbers while the page is on screen
        .task {
            while !Task.isCancelled {
                await store.ask(.refresh(.system), followUp: false)
                try? await Task.sleep(for: .seconds(2))
                await store.refresh()
                try? await Task.sleep(for: .seconds(13))
            }
        }
    }

    private func memory(_ system: SystemSnapshot) -> some View {
        Section("Memory") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(system.usedGB, format: .number.precision(.fractionLength(1)))
                        .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("of \(Int(system.totalGB.rounded())) GB").foregroundStyle(.secondary)
                    Spacer()
                    Text("pressure \(system.pressureLabel)").font(.caption.weight(.semibold))
                        .foregroundStyle(pressureColor(system))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(pressureColor(system).opacity(0.15), in: Capsule())
                }
                ProgressView(value: system.usedFraction).tint(pressureColor(system))
                Text("Updated \(system.at, format: .relative(presentation: .named))").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func tokens(_ system: SystemSnapshot) -> some View {
        if let block = system.blockTokens {
            Section("Claude usage") {
                LabeledContent("This block", value: Self.format(block) + (system.budget > 0 ? " · \(block * 100 / system.budget)% of budget" : ""))
                if let ends = system.blockEnds {
                    LabeledContent("Resets", value: ends.formatted(date: .omitted, time: .shortened))
                }
                if let week = system.weekTokens {
                    LabeledContent("Last 7 days", value: Self.format(week))
                }
            }
        }
    }

    private func pressureColor(_ system: SystemSnapshot) -> Color {
        system.pressure >= 4 ? PhoneTheme.failed : system.pressure >= 2 ? PhoneTheme.needsYou : PhoneTheme.working
    }

    /// "23K tokens", "1.2M tokens".
    static func format(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM tokens", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return "\(tokens / 1_000)K tokens" }
        return "\(tokens) tokens"
    }
}

// MARK: - Not saved yet

/// The Overview's projects with changed files or commits not pushed, and Commit / Push to ask Claude there.
struct UnsavedSection: View {
    let store: PhoneStore

    var body: some View {
        if let unsaved = store.extras?.unsaved, !unsaved.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Not saved yet").font(.headline)
                ForEach(unsaved) { project in
                    HStack(spacing: 12) {
                        ProjectBadge(name: project.name, key: project.colorKey)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(project.name).font(.subheadline.weight(.semibold))
                                if let branch = project.branch {
                                    Text(branch).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Text(project.summary).font(.caption).foregroundStyle(PhoneTheme.needsYou)
                        }
                        Spacer(minLength: 6)
                        if project.canAsk {
                            Menu {
                                if project.changed > 0 {
                                    Button("Commit") { Task { await store.ask(.askProject(root: project.root, .commit)) } }
                                }
                                if project.ahead > 0 || (project.changed > 0 && project.hasUpstream) {
                                    Button(project.changed > 0 ? "Commit and Push" : "Push") {
                                        Task { await store.ask(.askProject(root: project.root, .push)) }
                                    }
                                }
                            } label: {
                                Text("Save").font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                MacNoteLine(store: store)
            }
        }
    }
}
