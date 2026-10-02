import AppKit
import SwiftUI
import WatchManCore

/// A file changed in the project's working tree.
struct FileChange: Identifiable, Equatable, Sendable {
    var id: String { path }
    var path: String          // relative to the repo root
    var status: String        // "M", "A", "D", "??"…
    var added: Int?
    var removed: Int?
}

enum GitChanges {
    static func list(root: String) async -> [FileChange] {
        let status = await Script.run("/usr/bin/git", ["-C", root, "status", "--porcelain=v1", "--untracked-files=all"])
        let numstat = await Script.run("/usr/bin/git", ["-C", root, "diff", "--numstat", "HEAD"])
        var counts: [String: (Int?, Int?)] = [:]
        for line in numstat.raw.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            counts[parts[2]] = (Int(parts[0]), Int(parts[1]))
        }
        return status.raw.split(separator: "\n").compactMap { line -> FileChange? in
            guard line.count > 3 else { return nil }
            let code = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            let count = counts[path]
            return FileChange(path: path, status: code.isEmpty ? "M" : code, added: count?.0, removed: count?.1)
        }
    }

    static func diff(root: String, file: FileChange) async -> String {
        if file.status == "??" {
            return await Script.run("/usr/bin/git", ["-C", root, "diff", "--no-index", "--", "/dev/null", file.path]).output
        }
        return await Script.run("/usr/bin/git", ["-C", root, "diff", "HEAD", "--", file.path]).output
    }
}

/// The session project's uncommitted changes, with an in-notch diff.
struct ChangesView: View {
    let session: Session
    @State private var files: [FileChange] = []
    @State private var loading = true
    @State private var selected: FileChange?
    @State private var diff = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let root = session.projectRoot {
                HStack {
                    Text((root as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                    Spacer()
                    PillButton(title: "Open in VS Code", symbol: "chevron.left.forwardslash.chevron.right") {
                        openInVSCode(root)
                    }
                }
                if loading {
                    ProgressView().controlSize(.small)
                } else if files.isEmpty {
                    Text("No uncommitted changes.").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                } else if let selected {
                    DiffView(file: selected, diff: diff) { self.selected = nil }
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(files) { file in fileRow(file, root: root) }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            } else {
                Text("WatchMan doesn't know this session's project yet (it appears once Claude edits a file in a git repo).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: session.lastActivity) {
            guard let root = session.projectRoot else { loading = false; return }
            files = await GitChanges.list(root: root)
            loading = false
        }
    }

    private func fileRow(_ file: FileChange, root: String) -> some View {
        HStack(spacing: 8) {
            Text(file.status)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(file.status == "D" ? Theme.failed : file.status == "??" || file.status == "A" ? Theme.working : Theme.needsYou)
                .frame(width: 18)
            Text(file.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            if let added = file.added { Text("+\(added)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.working) }
            if let removed = file.removed { Text("−\(removed)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.failed) }
            IconButton(symbol: "arrow.up.right", help: "Open in VS Code") {
                openInVSCode((root as NSString).appendingPathComponent(file.path))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                diff = await GitChanges.diff(root: root, file: file)
                selected = file
            }
        }
        .help("Show the diff")
    }

    private func openInVSCode(_ path: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

/// A unified diff, coloured line by line.
struct DiffView: View {
    let file: FileChange
    let diff: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(action: close) {
                    Label("All files", systemImage: "chevron.left").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                Text(file.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.primary).lineLimit(1)
                Spacer()
            }
            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(color(for: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(for: line))
                    }
                }
                .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Skips git's header lines (diff --git, index, ---/+++), keeps hunks.
    private var lines: [String] {
        let all = diff.components(separatedBy: "\n")
        let start = all.firstIndex { $0.hasPrefix("@@") } ?? 0
        return Array(all[start...].prefix(1500))
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("@@") { return Theme.unseen }
        if line.hasPrefix("+") { return Theme.working }
        if line.hasPrefix("-") { return Theme.failed }
        return Theme.secondary
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Theme.working.opacity(0.08) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Theme.failed.opacity(0.08) }
        return .clear
    }
}

/// What the session did, step by step, from its transcript.
struct TimelineListView: View {
    let session: Session
    let store: SessionStore
    @State private var entries: [TranscriptState.TimelineEntry] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 3) {
                    if entries.isEmpty {
                        Text("Nothing yet.").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    }
                    ForEach(entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(entry.at, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.faint)
                                .fixedSize()
                                .frame(width: 34, alignment: .leading)
                            Image(systemName: symbol(entry.kind))
                                .font(.system(size: 9))
                                .foregroundStyle(color(entry.kind))
                                .frame(width: 12)
                            Text(entry.text)
                                .font(.system(size: 11, weight: entry.kind == .prompt ? .semibold : .regular))
                                .foregroundStyle(entry.kind == .prompt ? Theme.primary : Theme.secondary)
                                .lineLimit(2)
                        }
                        .id(entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .task(id: session.lastActivity) {
                guard let path = session.transcriptPath, let state = await store.transcriptState(path: path) else { return }
                entries = state.timeline
                if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func symbol(_ kind: TranscriptState.TimelineEntry.Kind) -> String {
        switch kind {
        case .prompt: "person.fill"
        case .tool: "wrench.and.screwdriver"
        case .reply: "text.bubble"
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func color(_ kind: TranscriptState.TimelineEntry.Kind) -> Color {
        switch kind {
        case .prompt: Theme.primary
        case .tool: Theme.faint
        case .reply: Theme.unseen
        case .passed: Theme.working
        case .failed: Theme.failed
        }
    }
}
