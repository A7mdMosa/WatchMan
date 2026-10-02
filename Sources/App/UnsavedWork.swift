import SwiftUI
import WatchManCore

/// A project with work that isn't saved anywhere else yet: changed files, or commits not pushed.
struct UnsavedProject: Identifiable, Equatable {
    var id: String { root }
    let root: String
    let name: String
    let colorKey: String
    let state: GitState
}

enum UnsavedWork {
    /// Checks every project WatchMan knows a session in (git, off the main thread, once per call).
    static func check(_ sessions: [Session]) async -> [UnsavedProject] {
        var seen = Set<String>()
        let projects = sessions.compactMap { session -> (String, String, String)? in
            guard let root = session.projectRoot, seen.insert(root).inserted else { return nil }
            return (root, session.label, session.colorKey)
        }
        return await withTaskGroup(of: UnsavedProject?.self) { group in
            for (root, name, colorKey) in projects {
                group.addTask {
                    let result = await Script.run("/usr/bin/git", ["-C", root, "status", "--porcelain=v1", "--branch"])
                    guard result.status == 0 else { return nil }
                    let state = GitState.parse(result.output)
                    return state.unsaved ? UnsavedProject(root: root, name: name, colorKey: colorKey, state: state) : nil
                }
            }
            var found: [UnsavedProject] = []
            for await project in group { if let project { found.append(project) } }
            return found.sorted { $0.state.changed + $0.state.ahead > $1.state.changed + $1.state.ahead }
        }
    }
}

extension SessionStore {
    /// The session to ask about a project's git work: one that can take a message, not working if possible.
    func session(forProject root: String) -> Session? {
        let candidates = ordered.filter { $0.projectRoot == root && $0.host.canSend }
        return candidates.first { $0.status != .working && !hasPendingPrompt($0.id) } ?? candidates.first
    }

    /// Asks Claude in that project to commit or push (queued if it's working).
    func askProject(_ root: String, _ text: String) {
        guard let session = session(forProject: root) else { return }
        if session.status == .working {
            enqueueFollowUp(text, for: session.id)
            pageNote = "Queued for \(session.label)"
        } else {
            Task { pageNote = await reply(text, to: session.id) ?? "Sent to \(session.label): \(text)" }
        }
    }
}

/// The Overview's "Not saved yet": each project with changed files or unpushed commits, and buttons to ask
/// Claude to commit or push.
struct UnsavedWorkSection: View {
    let store: SessionStore
    @State private var projects: [UnsavedProject] = []
    @State private var checking = false

    var body: some View {
        Group {
            if !projects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("NOT SAVED YET").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.faint)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button { Task { await refresh() } } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.secondary)
                        .help("Check again")
                        .accessibilityLabel("Check again")
                        .disabled(checking)
                    }
                    VStack(spacing: 0) {
                        ForEach(projects) { project in row(project) }
                    }
                    .padding(6)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .task { await refresh() }
        // A session finishing may have committed (or changed more)
        .onChange(of: store.activity.entries.count) { _, _ in Task { await refresh() } }
    }

    private func refresh() async {
        checking = true
        projects = await UnsavedWork.check(store.ordered)
        checking = false
    }

    private func row(_ project: UnsavedProject) -> some View {
        let state = project.state
        let parts = [state.changed > 0 ? "\(state.changed) changed file\(state.changed == 1 ? "" : "s")" : nil,
                     state.ahead > 0 ? "\(state.ahead) not pushed" : nil].compactMap { $0 }
        let canAsk = store.session(forProject: project.root) != nil
        return HStack(spacing: 10) {
            ProjectTile(label: project.name, colorKey: project.colorKey, size: 20)
            Text(project.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1).fixedSize()
            if let branch = state.branch {
                Text(branch).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            Text(parts.joined(separator: " · ")).font(.system(size: 12.5)).foregroundStyle(Theme.needsYou).lineLimit(1)
            Spacer(minLength: 8)
            if canAsk, state.changed > 0 {
                PillButton(title: "Commit", symbol: "checkmark.seal", tint: Theme.primary) { store.askProject(project.root, "commit the changes") }
                    .help("Ask Claude in \(project.name) to commit")
            }
            if canAsk, state.ahead > 0 || (state.changed > 0 && state.hasUpstream) {
                PillButton(title: "Push", symbol: "arrow.up.circle", tint: Theme.primary) {
                    store.askProject(project.root, state.changed > 0 ? "commit the changes and push" : "push the commits")
                }
                .help("Ask Claude in \(project.name) to push")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
    }
}
