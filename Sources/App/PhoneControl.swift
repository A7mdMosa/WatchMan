import AppKit
import CloudKit
import Observation
import WatchManCore

/// The Mac's side of the phone's Settings, New session, Resume, System and Not saved yet: what it shares
/// (`MacExtras`, in the status record) and how it carries out `MacCommand`s. The lists are filled in only when the
/// phone asks (a tab on screen there), so nothing here runs on its own.
@MainActor @Observable
final class PhoneControl {
    static let shared = PhoneControl()

    private(set) var projects: [ProjectSnapshot]?
    private(set) var recent: [PastChat]?
    private(set) var search: ChatSearchResult?
    private(set) var unsaved: [UnsavedSnapshot]?
    private(set) var system: SystemSnapshot?
    private(set) var note: MacNote?
    private(set) var answeredAt: Date?
    private(set) var changes: ProjectChanges?
    /// Chats the phone asked for, by session, waiting for the next publish.
    private(set) var chatRequests: Set<String> = []
    /// How many items each session's chat carries, once the phone asked for more.
    @ObservationIgnored private var chatLimits: [String: Int] = [:]

    private init() {}

    /// What the status record carries. Reading it here is what makes the publisher follow settings changes.
    func extras() -> MacExtras {
        MacExtras(settings: Self.settings(), projects: projects, recent: recent, search: search, unsaved: unsaved,
                  system: system, note: note, answeredAt: answeredAt, changes: changes)
    }

    func answerPing() { answeredAt = Date() }

    // MARK: Chats and changes

    func requestChat(_ id: String, limit: Int) {
        chatLimits[id] = max(ChatSnapshot.maxItems, min(limit, ChatSnapshot.largestLimit))
        chatRequests.insert(id)
    }

    func chatLimit(for id: String) -> Int { chatLimits[id] ?? ChatSnapshot.maxItems }

    /// The chats to send now, once.
    func takeChatRequests() -> Set<String> {
        defer { chatRequests = [] }
        return chatRequests
    }

    /// The session's project's uncommitted changes with their diffs, within the record's size budget.
    func refreshChanges(for session: Session) {
        guard let root = session.projectRoot else {
            changes = ProjectChanges(sessionId: session.id, root: "", files: [])
            return
        }
        Task {
            var budget = ProjectChanges.totalLines
            var files: [ProjectChanges.File] = []
            for file in await GitChanges.list(root: root).prefix(40) {
                let hunks = budget > 0 ? ProjectChanges.hunks(await GitChanges.diff(root: root, file: file), budget: budget)
                    : (lines: [], cut: true)
                budget -= hunks.lines.count
                files.append(.init(path: file.path, status: file.status, added: file.added, removed: file.removed,
                                   diff: hunks.lines, cut: hunks.cut))
            }
            changes = ProjectChanges(sessionId: session.id, root: root, files: files)
        }
    }

    // MARK: Photos from the phone

    /// A reply that came with photos: they're saved where the Mac keeps dropped files, and their paths go after
    /// the words, so Claude can open them.
    static func withPhotos(_ command: PhoneCommand, from record: CKRecord) -> PhoneCommand {
        guard case .reply(let text) = command.kind, let assets = record["photos"] as? [CKAsset], !assets.isEmpty else { return command }
        var paths: [String] = []
        for (index, asset) in assets.prefix(6).enumerated() {
            guard let source = asset.fileURL else { continue }
            let file = Attachments.folder.appendingPathComponent("phone-\(Int(Date().timeIntervalSince1970))-\(index).jpg")
            if (try? FileManager.default.copyItem(at: source, to: file)) != nil { paths.append(file.path) }
        }
        guard !paths.isEmpty else { return command }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = paths.map(Attachments.quoted).joined(separator: " ")
        var updated = command
        updated.kind = .reply(words.isEmpty ? added : words + " " + added)
        return updated
    }

    func say(_ text: String) { note = MacNote(text: text) }

    // MARK: Settings

    static func settings() -> MacSettings {
        let s = AppSettings.shared
        return MacSettings(approvalsEnabled: s.approvalsEnabled, handBackSeconds: s.approvalTimeout,
                           awayHoldMinutes: s.awayHoldMinutes, awayAfterMinutes: s.ntfyIdleMinutes,
                           iphoneAlerts: s.iphoneAlerts, iphoneAlertsWhenAway: s.iphoneAlertsWhenAway,
                           autoContinue: s.autoContinue, notchMessages: s.notchPopEnabled, sounds: s.soundEnabled,
                           volume: s.soundVolume,
                           quietUntil: s.quietUntil > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: s.quietUntil) : nil,
                           quietWhilePresenting: s.quietWhilePresenting, stuckAlerts: s.stuckAlertsEnabled,
                           stuckIdleMinutes: s.stuckIdleMinutes, stuckRepeatCount: s.stuckRepeatCount,
                           stuckLongRunMinutes: s.stuckLongRunMinutes, devLog: s.digestEnabled, devLogMinutes: s.digestMinutes,
                           devLogHaiku: s.digestUsesHaiku, quickReplies: s.quickReplies,
                           iphoneFinishedAlerts: s.iphoneFinishedAlerts)
    }

    /// Makes a change from the phone, kept inside the ranges the Mac's Settings allow.
    func apply(_ change: MacSettingChange) {
        if case .muted(let root, let on) = change {
            guard ProjectSettings.shared.knownProjects.contains(root) else { return }
            ProjectSettings.shared.update(root) { $0.muted = on ? true : nil }
            if projects != nil { refreshProjects() }
            return
        }
        let new = Self.settings().applying(change)
        let s = AppSettings.shared
        switch change {
        case .approvals: s.approvalsEnabled = new.approvalsEnabled
        case .handBackSeconds: s.approvalTimeout = new.handBackSeconds
        case .awayHoldMinutes: s.awayHoldMinutes = new.awayHoldMinutes
        case .awayAfterMinutes: s.ntfyIdleMinutes = new.awayAfterMinutes
        case .iphoneAlerts: s.iphoneAlerts = new.iphoneAlerts
        case .iphoneAlertsWhenAway: s.iphoneAlertsWhenAway = new.iphoneAlertsWhenAway
        case .iphoneFinishedAlerts: s.iphoneFinishedAlerts = new.iphoneFinishedAlerts ?? false
        case .autoContinue: s.autoContinue = new.autoContinue
        case .notchMessages: s.notchPopEnabled = new.notchMessages
        case .sounds: s.soundEnabled = new.sounds
        case .volume: s.soundVolume = new.volume
        case .quietUntil: s.quietUntil = new.quietUntil?.timeIntervalSince1970 ?? 0
        case .quietWhilePresenting: s.quietWhilePresenting = new.quietWhilePresenting
        case .stuckAlerts: s.stuckAlertsEnabled = new.stuckAlerts
        case .stuckIdleMinutes: s.stuckIdleMinutes = new.stuckIdleMinutes
        case .stuckRepeatCount: s.stuckRepeatCount = new.stuckRepeatCount
        case .stuckLongRunMinutes: s.stuckLongRunMinutes = new.stuckLongRunMinutes
        case .devLog: s.digestEnabled = new.devLog
        case .devLogMinutes: s.digestMinutes = new.devLogMinutes
        case .devLogHaiku: s.digestUsesHaiku = new.devLogHaiku
        case .quickReplies: s.quickReplies = new.quickReplies.isEmpty ? AppSettings.defaultQuickReplies : new.quickReplies
        case .muted: break
        }
    }

    // MARK: Lists, when the phone asks

    func refresh(_ part: MacExtras.Part, store: SessionStore) {
        switch part {
        case .projects: refreshProjects()
        case .recent:
            Task { recent = await RecentSessions.load(excluding: Set(store.sessions.keys)).map(Self.pastChat) }
        case .unsaved:
            Task {
                unsaved = await UnsavedWork.check(store.ordered).map { project in
                    UnsavedSnapshot(root: project.root, name: project.name, colorKey: project.colorKey,
                                    branch: project.state.branch, changed: project.state.changed, ahead: project.state.ahead,
                                    hasUpstream: project.state.hasUpstream, canAsk: store.session(forProject: project.root) != nil)
                }
            }
        case .system:
            Task { system = await Self.systemSnapshot(store: store) }
        }
    }

    /// Projects linked in Obsidian or seen in a session, with their To-dos.
    private func refreshProjects() {
        let index = ObsidianIndex.shared
        index.refreshIfNeeded()
        let settings = ProjectSettings.shared
        projects = settings.knownProjects.map { root in
            ProjectSnapshot(root: root, name: (root as NSString).lastPathComponent,
                            group: ((root as NSString).deletingLastPathComponent as NSString).lastPathComponent,
                            muted: settings.isMuted(root), starters: settings.starters(for: root),
                            quickReplies: settings.quickReplies(for: root),
                            todos: index.notes[root].map { index.todos(notePath: $0) }?.prefix(30)
                                .map { ProjectTodo(text: $0.text, due: $0.due) } ?? [])
        }
    }

    func runSearch(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { search = nil; return }
        Task {
            let hits = await ChatSearch.run(text)
            search = ChatSearchResult(query: text, hits: hits.map {
                PastChat(id: $0.id, title: $0.title, folder: $0.cwd, modified: $0.modified, snippet: $0.snippet)
            }, limited: hits.count == ChatSearch.limit)
        }
    }

    private static func pastChat(_ session: RecentSession) -> PastChat {
        PastChat(id: session.id, title: session.title, folder: session.cwd, modified: session.modified)
    }

    private static func systemSnapshot(store: SessionStore) async -> SystemSnapshot {
        let memory = MemoryStatus.current()
        let table = await ProcessSnapshot.current()
        let usage = await UsageTracker.shared.summary()
        let sessions = store.ordered.compactMap { session -> SystemSnapshot.SessionMemory? in
            guard let pid = session.pid else { return nil }
            let kb = table.treeRSSKB(of: pid)
            return kb > 0 ? SystemSnapshot.SessionMemory(name: session.label, megabytes: kb / 1024) : nil
        }.sorted { $0.megabytes > $1.megabytes }
        return SystemSnapshot(memoryUsed: memory.usedBytes, memoryTotal: memory.totalBytes, pressure: memory.pressureLevel,
                              sessions: Array(sessions.prefix(8)),
                              leftovers: table.strays().map { .init(pid: $0.pid, kind: $0.kind, megabytes: $0.rssKB / 1024) },
                              blockTokens: usage.currentBlockTokens, blockEnds: usage.currentBlockEnd,
                              weekTokens: usage.lastSevenDaysTokens, budget: AppSettings.shared.blockBudget)
    }

    // MARK: Starting and resuming

    func start(in folder: String, prompt: String) {
        guard Self.isFolder(folder) else { say("Couldn't start: that folder isn't on the Mac"); return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = text.isEmpty ? "claude" : "claude \(Script.shellQuote(text))"
        Task {
            let ok = await Hosts.startSession(in: folder, command: command)
            say(ok ? "Started Claude in \((folder as NSString).lastPathComponent)"
                : "Couldn't start: " + (Hosts.lastStartProblem ?? "the terminal didn't open a tab."))
        }
    }

    func resume(_ chatId: String, in folder: String) {
        guard MacCommand.isChatId(chatId), Self.isFolder(folder) else { say("Couldn't resume that chat"); return }
        Task {
            let ok = await Hosts.startSession(in: folder, command: "claude --resume \(chatId)")
            say(ok ? "Resumed in \((folder as NSString).lastPathComponent)"
                : "Couldn't resume: " + (Hosts.lastStartProblem ?? "the terminal didn't open a tab."))
        }
    }

    private static func isFolder(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    // MARK: System

    /// Quits a leftover only if the Mac still lists that process as one (never any process the phone names).
    func quitLeftover(_ pid: Int32, store: SessionStore) {
        Task {
            let table = await ProcessSnapshot.current()
            guard let stray = table.strays().first(where: { $0.pid == pid }) else { say("That process is gone"); return }
            kill(stray.pid, SIGTERM)
            say("Quit \(stray.kind)")
            try? await Task.sleep(for: .seconds(1))
            system = await Self.systemSnapshot(store: store)
        }
    }

    func writeDevLog() {
        say(AppSettings.shared.digestUsesHaiku ? "Writing the Dev Log (summarizing sessions)…" : "Writing the Dev Log…")
        Task {
            do {
                _ = try await DigestWriter.writeToday()
                say("Dev Log written to Obsidian")
            } catch {
                say("Couldn't write the Dev Log: \(error.localizedDescription)")
            }
        }
    }
}

extension SessionStore {
    /// A session's extras for its page on the phone.
    func phoneExtras(for session: Session) -> SessionExtras {
        SessionExtras(followUps: followUps[session.id] ?? [], stuck: session.stuck?.text,
                      error: session.failed ? (session.errorText ?? "Claude Code stopped with an error") : nil,
                      canStop: Hosts.canInterrupt(session.host) && session.tty != nil,
                      continuesAt: scheduledContinues[session.id],
                      subagents: session.subagents.map { .init(type: $0.type, description: $0.description, step: $0.step) },
                      quickReplies: ProjectSettings.shared.quickReplies(for: session.projectRoot),
                      projectRoot: session.projectRoot, remoteURL: session.remoteURL?.absoluteString)
    }

    /// Carries out a `MacCommand` from the phone. `id` is the session it's about ("" for the Mac's own).
    func performMac(_ command: MacCommand, for id: String) {
        let control = PhoneControl.shared
        switch command {
        case .stop:
            // Esc only where Claude is in front, and never on a prompt (it would answer it)
            guard let session = sessions[id], let tty = session.tty else { return }
            guard session.pendingApproval == nil else { control.say("Answer its prompt first"); return }
            Task {
                guard await ProcessSnapshot.current().claudeIsForeground(onTTY: tty) else {
                    control.say("Claude isn't running in that tab anymore")
                    return
                }
                control.say(await Hosts.interrupt(session) ?? "Stopped \(session.label)")
            }
        case .retry:
            guard sessions[id] != nil else { return }
            retry(id)
        case .removeFollowUp(let index): removeFollowUp(at: index, for: id)
        case .dismissStuck: dismissStuck(id)
        case .seen: markSeen(id)
        case .chat(let limit):
            guard sessions[id] != nil else { return }
            control.requestChat(id, limit: limit)
        case .changes:
            guard let session = sessions[id] else { return }
            control.refreshChanges(for: session)
        case .ping: control.answerPing()
        case .setting(let change): control.apply(change)
        case .start(let folder, let prompt): control.start(in: folder, prompt: prompt)
        case .resume(let chatId, let folder): control.resume(chatId, in: folder)
        case .refresh(let part): control.refresh(part, store: self)
        case .search(let query): control.runSearch(query)
        case .askProject(let root, let ask):
            guard session(forProject: root) != nil else { control.say("No session in that project can take a message"); return }
            let changed = control.extras().unsaved?.first { $0.root == root }?.changed ?? 0
            askProject(root, ask == .commit ? "commit the changes" : changed > 0 ? "commit the changes and push" : "push the commits")
            control.say("Asked Claude to \(ask.rawValue) in \((root as NSString).lastPathComponent)")
        case .quitLeftover(let pid): control.quitLeftover(pid, store: self)
        case .writeDevLog: control.writeDevLog()
        case .testAlert: CloudPublisher.current?.sendTestAlert()
        }
    }
}
