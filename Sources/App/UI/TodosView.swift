import SwiftUI
import WatchManCore

/// Open To-dos from every linked project note; one click starts Claude on one.
struct TodosView: View {
    enum Scope: String, CaseIterable { case mine = "My projects", students = "Students" }

    @State private var scope: Scope

    init(scope: Scope = .mine) {
        _scope = State(initialValue: scope)
    }
    @State private var started: String?
    @State private var expanded: Set<String> = []
    private var index: ObsidianIndex { ObsidianIndex.shared }

    private struct Group: Identifiable {
        var id: String { note }
        var note: String
        var folder: String
        var title: String
        var todos: [TodoItem]

        /// Student notes are named "Student Name (App) {Stack}": show the app first, the student after.
        var heading: (main: String, detail: String?) {
            guard let open = title.firstIndex(of: "("), let close = title.firstIndex(of: ")"), open < close else {
                return (title, nil)
            }
            let app = String(title[title.index(after: open)..<close])
            let person = String(title[..<open]).trimmingCharacters(in: .whitespaces)
            return (app, person.isEmpty ? nil : person)
        }
    }

    private var groups: [Group] {
        let prefix = scope == .mine ? "01 Projects/" : "02 Students/"
        return index.linkedNotes
            .filter { $0.note.hasPrefix(prefix) }
            .compactMap { link -> Group? in
                let todos = index.todos(notePath: link.note)
                guard !todos.isEmpty else { return nil }
                let title = ((link.note as NSString).lastPathComponent as NSString).deletingPathExtension
                return Group(note: link.note, folder: link.folder, title: title, todos: todos)
            }
            .sorted { a, b in
                switch (a.todos.first?.due, b.todos.first?.due) {
                case let (x?, y?): x < y
                case (.some, nil): true
                case (nil, .some): false
                default: a.title.lowercased() < b.title.lowercased()
                }
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Scope.allCases, id: \.self) { item in
                    TabPill(title: item.rawValue, selected: scope == item) { scope = item }
                }
                Spacer()
                Text("Start opens Claude in that project with the To-do as its task")
                    .font(.system(size: 10)).foregroundStyle(Theme.faint)
            }
            let groups = groups
            if groups.isEmpty {
                Text("No open To-dos in linked notes.").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groups) { group in groupView(group) }
                    }
                }
                .frame(maxHeight: CGFloat(AppSettings.shared.listHeight))
            }
        }
        .onAppear { index.refreshIfNeeded() }
    }

    private func groupView(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.projectColor(group.folder)).frame(width: 3, height: 12)
                Text(group.heading.main).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                if let person = group.heading.detail {
                    Text(person).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Text("\(group.todos.count)").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                Spacer()
                Button("Open note") { index.openNote(path: group.note) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.obsidian)
            }
            let showAll = expanded.contains(group.note)
            ForEach(showAll ? group.todos : Array(group.todos.prefix(6))) { todo in
                HStack(spacing: 8) {
                    Image(systemName: "circle").font(.system(size: 9)).foregroundStyle(Theme.faint)
                    Text(todo.text).font(.system(size: 11.5)).foregroundStyle(Theme.primary.opacity(0.9)).lineLimit(1)
                        .help(todo.text)
                    if let due = todo.due { DueBadge(due: due) }
                    Spacer()
                    if started == group.folder + todo.text {
                        Text("Started").font(.system(size: 10.5)).foregroundStyle(Theme.working)
                    } else {
                        PillButton(title: "Start", symbol: "play.fill", tint: Theme.working) { start(todo, in: group.folder) }
                    }
                }
                .padding(.leading, 9)
            }
            if group.todos.count > 6 {
                Button(showAll ? "Show less" : "+\(group.todos.count - 6) more") {
                    withAnimation(.smooth(duration: 0.18)) {
                        if showAll { expanded.remove(group.note) } else { expanded.insert(group.note) }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .padding(.leading, 9)
            }
        }
        .padding(8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
    }

    private func start(_ todo: TodoItem, in folder: String) {
        let prompt = "Work on this To-do from the project's Obsidian note: \(todo.text)"
        started = folder + todo.text
        Task { _ = await Hosts.startSession(in: folder, command: "claude \(Script.shellQuote(prompt))") }
    }
}

/// "today", "in 3 days", "2 days late".
struct DueBadge: View {
    let due: Date

    var body: some View {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: due).day ?? 0
        let (text, color): (String, Color) = switch days {
        case ..<0: ("\(-days)d late", Theme.failed)
        case 0: ("today", Theme.needsYou)
        case 1: ("tomorrow", Theme.needsYou)
        default: ("in \(days)d", Theme.secondary)
        }
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.13), in: Capsule())
    }
}
