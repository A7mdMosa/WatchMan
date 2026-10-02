import AppKit
import Observation
import WatchManCore

/// All Claude Code sessions WatchMan knows about, fed by hook events and transcripts.
@MainActor @Observable
final class SessionStore {
    private(set) var sessions: [String: Session] = [:]
    /// The session whose page is open (nil: the list).
    var pageId: String? {
        didSet { if pageId != nil { otherPage = nil } }
    }
    /// One of the pages that used to be tabs: To-dos, earlier sessions, the system.
    var otherPage: OtherPage? {
        didSet { if otherPage != nil { pageId = nil } }
    }
    enum OtherPage: Equatable { case todos, recent, system }
    /// Files dropped on the notch, waiting for you to pick the session they go to.
    var pendingDrop: [String] = []
    /// A short line on the open page ("Copied", "Summarizing…"), from its ⋯ menu.
    var pageNote: String?
    /// The panel has the keyboard, so key hints (⌘↩ Allow) are true.
    var panelHasKeyboard = false
    /// A session's page is showing (the island widens and gives it all the height it can).
    var pageOpen: Bool { pageId.map { sessions[$0] != nil } ?? false }
    /// Going through what's waiting, one session after another (⌥Space).
    var inbox = false
    /// Just finished going through what was waiting: "All clear" for a moment.
    var allClear = false
    /// Idle sessions you cleared from the list, with their last activity then: they come back when they do something.
    var hiddenIdle: [String: Date] = [:]
    /// True while the user types a reply, so the notch doesn't close under them.
    var isEditing = false
    /// Row highlighted by the keyboard.
    var selectedId: String?
    /// Session whose reply field should take the keyboard (the R shortcut).
    var focusReplyId: String?
    /// The same for the WatchMan window's reply field (⌘R), kept apart so the panel and the window never pull
    /// the keyboard from each other.
    var focusWindowReplyId: String?
    /// Sessions stopped by the usage limit that WatchMan will continue when it resets (saved across restarts).
    var scheduledContinues: [String: Date] = (UserDefaults.standard.dictionary(forKey: "scheduledContinues") as? [String: Double] ?? [:])
        .mapValues { Date(timeIntervalSince1970: $0) } {
        didSet { UserDefaults.standard.set(scheduledContinues.mapValues(\.timeIntervalSince1970), forKey: "scheduledContinues") }
    }
    @ObservationIgnored var continueTasks: [String: Task<Void, Never>] = [:]
    /// Your plan's usage (the 5-hour session and the week), from Claude Code's status line.
    var planUsage: PlanUsage?
    /// The windows already warned about at 80%, by when they reset, so each warns once.
    @ObservationIgnored var usageWarned: Set<Date> = []
    /// The last two days of what sessions did, for the window's timeline (saved across restarts).
    var activity = ActivityFile.load()
    @ObservationIgnored var activitySave: Task<Void, Never>?
    /// Latest event, shown for a few seconds in the notch's right wing.
    private(set) var ticker: Ticker?
    /// Something just finished or started needing you: the notch glows in this colour for a while.
    private(set) var attention: Attention?
    /// What you just did from WatchMan ("Sent", "Allowed"), confirmed on the notch for 2 seconds; also a news line
    /// ("Trailmap started") for a few seconds.
    private(set) var feedback: NotchActivity?
    /// The ball's latest one-off reaction (started, stuck, an error…), for the notch to play once.
    private(set) var reaction: OrbReactionEvent?
    /// Messages below the notch: what just happened, with buttons when you can answer right there.
    private(set) var toasts: [Toast] = []
    /// The mouse is over the messages: they stay until it leaves.
    /// The pointer is on a message: messages wait (their countdown freezes) and carry on after.
    var holdToasts = false {
        didSet {
            guard oldValue != holdToasts else { return }
            if holdToasts {
                holdStartedAt = Date()
            } else if let start = holdStartedAt {
                let held = Date().timeIntervalSince(start)
                for index in toasts.indices { toasts[index].expires.addTimeInterval(held) }
                holdStartedAt = nil
            }
            scheduleToastExpiry()
        }
    }
    private(set) var holdStartedAt: Date?

    /// Seconds before a message leaves (frozen while the pointer is on it).
    func timeLeft(_ toast: Toast, now: Date = Date()) -> TimeInterval {
        toast.expires.timeIntervalSince(holdStartedAt ?? now)
    }

    struct Toast: Identifiable, Equatable {
        enum Kind: Equatable {
            case started(prompt: String?)
            case permission(approval: PendingApproval)
            case question(text: String, answers: [ClosingQuestion.Answer])
            case finished(text: String)
            /// A moment as one short line (the "A short line" setting): "Trailmap started", "Trailmap finished".
            case brief(text: String, tone: NotchActivity.Tone)
            /// Several finished close together: one message instead of many.
            case finishedMany(names: [String])
            case stuck(text: String)
            /// Stopped with an error: Retry types "continue".
            case failed(text: String)
            /// Stopped by Claude's usage limit, with when it resets.
            case limit(resets: String?)
            /// Back at the Mac after a while: what happened meanwhile.
            case away(finished: Int, waiting: Int, stuck: Int)
            /// The plan's session or weekly usage passed 80%.
            case usage(window: String, percent: Int, resets: String?)
        }
        let id = UUID()
        var sessionId: String
        var name: String
        var kind: Kind
        var expires: Date

        /// A permission prompt shows its command on two lines; everything else fits on one.
        var height: CGFloat {
            if case .permission = kind { return 62 }
            if case .brief = kind { return 32 }
            return 46
        }
    }
    /// The list shows only sessions that need you or have a new result (opened from the notch's right side).
    var attentionOnly = false

    enum Attention: Equatable { case needsYou, finished }

    /// Half-typed replies, kept when the panel closes.
    var drafts: [String: String] = [:]
    /// Messages to type into a session as soon as it finishes ("Send when done"), saved across restarts.
    var followUps: [String: [String]] = (UserDefaults.standard.dictionary(forKey: "followUps") as? [String: [String]]) ?? [:] {
        didSet { UserDefaults.standard.set(followUps, forKey: "followUps") }
    }
    @ObservationIgnored var stuckTask: Task<Void, Never>?
    /// Stuck warnings you dismissed, until the session's status changes.
    @ObservationIgnored var dismissedStuck: [String: StuckReason] = [:]
    /// Called when a session starts looking stuck.
    @ObservationIgnored var onStuck: ((Session) -> Void)?
    /// While the panel is open, rows keep their order so they don't jump under the mouse.
    private var frozenOrder: [String]?

    struct Ticker: Equatable {
        var name: String
        var text: String
        var status: SessionStatus
        var unseen: Bool
    }

    @ObservationIgnored private var responders: [String: PermissionResponder] = [:]
    /// A fresh id for each permission prompt WatchMan holds, so phone buttons can only answer that prompt.
    @ObservationIgnored private var promptTokens: [String: String] = [:]
    @ObservationIgnored private var approvalTimeouts: [String: Task<Void, Never>] = [:]
    /// Prompts Claude Code shows only after WatchMan lets go (a subagent's): the terminal waits on these.
    @ObservationIgnored private var blockingPrompts: Set<String> = []
    @ObservationIgnored private var transcriptRefreshes: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let transcripts = TranscriptTracker()
    @ObservationIgnored private let subagentTracker = SubagentTracker()
    @ObservationIgnored private var gitRootCache: [String: Bool] = [:]
    @ObservationIgnored private var tickerClear: Task<Void, Never>?
    @ObservationIgnored private var attentionClear: Task<Void, Never>?
    @ObservationIgnored private var feedbackClear: Task<Void, Never>?
    @ObservationIgnored private var toastTimer: Task<Void, Never>?
    /// Called when a session starts needing you or finishes: (session, previous status).
    @ObservationIgnored var onTransition: ((Session, SessionStatus) -> Void)?
    /// A moment that needs nothing from you (a session started, usage passed 80%), for the notch to tell.
    @ObservationIgnored var onNews: ((NewsMoment) -> Void)?

    var ordered: [Session] {
        let sorted = Session.sortedForDisplay(Array(sessions.values))
        guard let frozenOrder else { return sorted }
        let position = Dictionary(uniqueKeysWithValues: frozenOrder.enumerated().map { ($1, $0) })
        // Known rows keep their place; sessions that appeared while open go at the end
        return sorted.enumerated().sorted { a, b in
            (position[a.element.id] ?? frozenOrder.count + a.offset) < (position[b.element.id] ?? frozenOrder.count + b.offset)
        }.map(\.element)
    }

    /// Show sessions that have been idle for over an hour.
    var showDormant = false

    /// Rows as the list shows them: active first, then (if unfolded) the long-idle ones.
    func split(now: Date = Date()) -> (active: [Session], dormant: [Session]) {
        let shown = ordered.filter { hiddenIdle[$0.id] != $0.lastActivity }
        let all = attentionOnly ? shown.filter { $0.status.isNeedsYou || $0.isUnseenResult } : shown
        return (all.filter { !$0.isDormant(now: now) }, all.filter { $0.isDormant(now: now) })
    }

    var visibleOrdered: [Session] {
        let parts = split()
        return parts.active + (showDormant ? parts.dormant : [])
    }

    func setSession(_ session: Session) { sessions[session.id] = session }

    /// Freezes the row order while the panel is open; unfreezing re-sorts.
    func freezeOrder(_ freeze: Bool) {
        frozenOrder = freeze ? Session.sortedForDisplay(Array(sessions.values)).map(\.id) : nil
    }
    var waitingCount: Int { ordered.filter { $0.status.isNeedsYou }.count }
    /// What's waiting for you, longest waiting first.
    var waitingQueue: [Session] {
        sessions.values.filter { $0.status.isNeedsYou && $0.continuedIn == nil }.sorted { $0.statusSince < $1.statusSince }
    }

    /// Hides the sessions idle for over an hour until they do something again.
    func clearIdle() {
        for session in split().dormant { hiddenIdle[session.id] = session.lastActivity }
        showDormant = false
    }

    /// Asks the notch to open and start going through what's waiting (from a message or the menu bar).
    func startInboxRequest() {
        NotificationCenter.default.post(name: .watchManStartInbox, object: nil)
    }

    /// Opens the session waiting longest; false when nothing waits.
    @discardableResult
    func startInbox() -> Bool {
        guard let first = waitingQueue.first else { return false }
        inbox = true
        allClear = false
        openPage(first.id)
        return true
    }

    /// After answering one: the next that waits, or "All clear".
    func advanceInbox(from id: String) {
        guard inbox, pageId == id else { return }
        if let next = waitingQueue.first(where: { $0.id != id }) {
            openPage(next.id)
        } else {
            inbox = false
            pageId = nil
            allClear = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard let self, self.allClear else { return }
                self.allClear = false
                NotificationCenter.default.post(name: .watchManCollapse, object: nil)
            }
        }
    }
    var workingCount: Int { ordered.filter { $0.status == .working }.count }
    var unseenCount: Int { ordered.filter(\.isUnseenResult).count }

    // MARK: - Hook events

    func handle(_ event: HookEvent, responder: PermissionResponder?) {
        let now = Date()
        var session = sessions[event.sessionId] ?? Session(id: event.sessionId, cwd: event.cwd, host: event.host, now: now)
        let previous = session.status
        let wasLimited = session.rateLimited
        session.apply(event, now: now)

        if event.name == "SessionEnd" {
            sessions[event.sessionId] = nil
            followUps[event.sessionId] = nil
            if pageId == event.sessionId { pageId = nil }
            answerPending(event.sessionId, .ask)
            if let path = session.transcriptPath { Task { await transcripts.forget(path: path) } }
            return
        }
        sessions[event.sessionId] = session
        if session.rateLimited, !wasLimited, AppSettings.shared.autoContinue { scheduleContinue(session.id) }
        if !session.rateLimited, wasLimited, scheduledContinues[session.id] != nil, event.name == "UserPromptSubmit" {
            cancelContinue(session.id)   // you carried on yourself
        }
        updateTicker(for: event, session: session)
        ProjectSettings.shared.noteSeen(session.projectRoot)
        if !previous.sameKind(as: session.status) { dismissedStuck[session.id] = nil }
        if FollowUpRule.shouldSend(afterEvent: event.name, status: session.status,
                                   hasPendingPrompt: session.pendingApproval != nil, canSend: session.host.canSend),
           !(followUps[session.id] ?? []).isEmpty {
            sendNextFollowUp(session.id)
        }
        if session.status == .working { startStuckChecks() }
        if !session.status.isNeedsYou {
            toasts.removeAll { toast in
                guard toast.sessionId == session.id else { return false }
                switch toast.kind {
                case .permission, .question: return true
                default: return false
                }
            }
        }
        if event.name == "UserPromptSubmit" {
            record(.started, event.prompt.map(ChatMessageView.cleanPrompt) ?? "Started", for: session)
        }
        if !previous.sameKind(as: session.status), session.status.isNeedsYou {
            if case .needsYou(let reason) = session.status { record(.asked, session.pendingApproval?.title ?? reason, for: session) }
        }
        if event.name == "UserPromptSubmit", !previous.sameKind(as: .working), AppSettings.shared.notchPopEnabled,
           !Quiet.isOn, !ProjectSettings.shared.isMuted(session.projectRoot),
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier != session.host.bundleIdentifier {
            onNews?(.started(session, prompt: event.prompt))
        }

        if let responder {
            holdPermission(for: session, event: event, responder: responder)
        } else if session.pendingApproval == nil {
            // Anything else from the session means its prompt was resolved
            answerPending(session.id, .ask)
        }

        if !previous.sameKind(as: session.status),
           session.status.isNeedsYou || session.status == .finished {
            raiseAttention(session.status.isNeedsYou ? .needsYou : .finished)
            if session.status == .finished {
                // Show Claude's final message in the alert
                refreshTranscript(session.id, delay: .zero) { [weak self] in
                    guard let self, let updated = self.sessions[session.id] else { return }
                    self.recordFinish(updated)
                    self.onTransition?(updated, previous)
                }
            } else {
                onTransition?(session, previous)
            }
        }
        refreshTranscript(session.id)
    }

    private func updateTicker(for event: HookEvent, session: Session) {
        let text: String
        switch event.name {
        case "UserPromptSubmit": text = "started"
        case "PreToolUse": text = session.lastStep ?? "working"
        case "Stop": text = "finished"
        case "StopFailure": text = "stopped with an error"
        case "PermissionRequest", "Notification":
            guard session.status.isNeedsYou else { return }
            text = "needs you"
        default: return
        }
        ticker = Ticker(name: session.displayName, text: text, status: session.status, unseen: session.isUnseenResult)
        tickerClear?.cancel()
        tickerClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.ticker = nil
        }
    }

    /// A moment told the WatchMan way: the ball reacts and the line beside the notch says it for a few seconds.
    /// `text` nil: the line already says it (an error, the usage limit stay on the line by themselves).
    func announce(_ text: String?, short: String = "", tone: NotchActivity.Tone = .info, seconds: Double = 4,
                  reaction kind: OrbReaction, sessionId: String = "") {
        reaction = OrbReactionEvent(kind: kind)
        guard let text else { return }
        feedback = .news(text, short: short.isEmpty ? text : short, tone: tone, sessionId: sessionId)
        feedbackClear?.cancel()
        feedbackClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.feedback = nil
        }
    }

    /// Confirms an action on the notch for a moment.
    func showFeedback(_ verb: String, for id: String) {
        guard let session = sessions[id] else { return }
        feedback = NotchActivity.feedback(id, name: session.label, verb: verb)
        feedbackClear?.cancel()
        feedbackClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.feedback = nil
        }
    }

    /// After an error: types "continue" so Claude picks up where it stopped.
    func retry(_ id: String) {
        Task { _ = await reply("continue", to: id) }
    }

    /// The total of subagents at work across sessions.
    var subagentCount: Int { ordered.reduce(0) { $0 + $1.subagents.count } }

    /// Shows a message below the notch (one per session: a newer one replaces it), at most three at a time.
    /// Results that finish close together share one message.
    func showToast(_ kind: Toast.Kind, for session: Session, seconds: Double) {
        var expires = Date().addingTimeInterval(seconds)
        // A permission message stays until WatchMan hands the prompt back to the terminal
        if case .permission = kind, let handBack = sessions[session.id]?.pendingApproval?.handBackAt { expires = handBack }
        toasts.removeAll { $0.sessionId == session.id }
        if case .finished = kind {
            var names: [String] = []
            toasts.removeAll { toast in
                switch toast.kind {
                case .finished: names.append(toast.name); return true
                case .finishedMany(let earlier): names += earlier; return true
                default: return false
                }
            }
            if !names.isEmpty {
                toasts.append(Toast(sessionId: Self.manyFinishedId, name: "", kind: .finishedMany(names: names + [session.label]),
                                    expires: expires))
                trimToasts()
                return
            }
        }
        toasts.append(Toast(sessionId: session.id, name: session.label, kind: kind, expires: expires))
        trimToasts()
    }

    /// A message that isn't about one session (the away summary).
    func showToast(_ kind: Toast.Kind, id: String, seconds: Double) {
        toasts.removeAll { $0.sessionId == id }
        toasts.append(Toast(sessionId: id, name: "", kind: kind, expires: Date().addingTimeInterval(seconds)))
        trimToasts()
    }

    static let manyFinishedId = "finished-many"
    static let awayId = "away"

    private func trimToasts() {
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        scheduleToastExpiry()
    }

    func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
        scheduleToastExpiry()
    }

    /// The first line of what a session finished with, without markdown.
    static func resultLine(_ session: Session) -> String {
        let line = session.replyPreview?.split(separator: "\n").first.map(String.init) ?? "Finished"
        let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return plain.count > 140 ? String(plain.prefix(139)) + "…" : plain
    }

    private func scheduleToastExpiry() {
        toastTimer?.cancel()
        guard !holdToasts, let next = toasts.map(\.expires).min() else { return }
        toastTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled, !self.holdToasts else { return }
            let now = Date()
            self.toasts.removeAll { $0.expires <= now }
            self.scheduleToastExpiry()
        }
    }

    private func raiseAttention(_ kind: Attention) {
        // Needing you outranks a finished result
        if attention == .needsYou, kind == .finished { return }
        attention = kind
        attentionClear?.cancel()
        attentionClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.attention = nil
        }
    }

    // MARK: - Seen, selection

    /// You looked at the session: its result is no longer "new".
    func markSeen(_ id: String) {
        guard let session = sessions[id], !session.seen else { return }
        sessions[id]?.seen = true
    }

    /// Moves the keyboard selection through the ordered list.
    func moveSelection(by offset: Int) {
        let ids = visibleOrdered.map(\.id)
        guard !ids.isEmpty else { selectedId = nil; return }
        let current = selectedId.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        selectedId = ids[max(0, min(ids.count - 1, current + offset))]
    }

    // MARK: - Previews (UI snapshots only)

    @ObservationIgnored var previewPrompts: Set<String> = []

    func replaceAll(_ list: [Session]) {
        sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    func previewTicker(_ value: Ticker?) { ticker = value }
    func previewAttention(_ value: Attention?) { attention = value }
    func previewFeedback(_ value: NotchActivity?) { feedback = value }

    // MARK: - Permission requests

    private func holdPermission(for session: Session, event: HookEvent, responder: PermissionResponder) {
        answerPending(session.id, .ask)
        let settings = AppSettings.shared
        // The session's own prompts show in the terminal at once, while WatchMan holds them, so holding never
        // keeps you waiting there. A subagent's prompt shows only after WatchMan lets go.
        let blocks = event.agentId != nil
        let atThatApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == session.host.bundleIdentifier
        // A subagent's prompt at that terminal, or quiet or muted (no message would tell you): straight to the terminal
        let toTerminal = blocks && (atThatApp || Quiet.isOn || ProjectSettings.shared.isMuted(session.projectRoot))
        guard settings.approvalsEnabled, !toTerminal else {
            responder.answer(.ask)
            clearApproval(session.id)
            return
        }
        responders[session.id] = responder
        if blocks { blockingPrompts.insert(session.id) }
        let id = session.id
        promptTokens[session.id] = UUID().uuidString
        // Away from the Mac with phone buttons on: wait longer so you can answer from the phone,
        // but never longer than Claude Code waits for the hook (its timeout in settings.json).
        // A question of the session's own waits that long too: the terminal shows it anyway, and here you can answer it
        let away = PhoneBridge.shared.enabled && PhoneAlerts.isAway(minutes: settings.ntfyIdleMinutes)
        let longest = HookInstaller.installedPermissionTimeout - 15
        let wanted = !blocks && session.pendingApproval?.isQuestion == true ? longest
            : away ? settings.awayHoldMinutes * 60 : settings.approvalTimeout
        let hold = max(5, min(wanted, longest))
        // The page and the message count down to this moment
        let handBack = Date().addingTimeInterval(hold)
        sessions[id]?.pendingApproval?.handBackAt = handBack
        for index in toasts.indices where toasts[index].sessionId == id {
            if case .permission = toasts[index].kind { toasts[index].expires = handBack }
        }
        scheduleToastExpiry()
        approvalTimeouts[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled else { return }
            self?.answerPending(id, .ask)
            self?.clearApproval(id)
        }
    }

    /// Answers a session's waiting permission prompt from WatchMan.
    /// `message`: what Claude hears with a deny (your reason to keep planning).
    func respond(to sessionId: String, with decision: PermissionDecision, message: String? = nil) {
        let approval = sessions[sessionId]?.pendingApproval
        // Claude Code turns a bare allow for a question into a deny: questions are answered with a choice
        if decision == .allow || decision == .always, approval?.isQuestion == true { return }
        let plan = approval?.isPlan == true
        // A plan: Approve hands the plan back and leaves plan mode (Always: also accept edits from now on);
        // Deny keeps planning, with your words when you gave some
        var sent = decision
        var extras: ReplyExtras?
        if plan, decision == .allow || decision == .always {
            sent = .allow
            extras = ReplyExtras(keepInput: true, mode: decision == .always ? "acceptEdits" : "default")
        } else if decision == .deny, let message, !message.isEmpty {
            extras = ReplyExtras(message: message)
        } else if plan, decision == .deny, let draft = drafts[sessionId]?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty {
            // What you typed under the plan is the change you want
            extras = ReplyExtras(message: draft)
            drafts[sessionId] = nil
        } else if plan, decision == .deny {
            extras = ReplyExtras(message: "Keep planning: the user wants to change the plan before you start.")
        }
        answerPending(sessionId, sent, extras: extras)
        clearApproval(sessionId)
        if decision != .ask, var session = sessions[sessionId] {
            session.status = .working
            session.statusSince = Date()
            let verb = plan ? (decision == .deny ? "Kept planning" : decision == .always ? "Approved, accepting edits" : "Plan approved")
                : decision == .deny ? "Denied" : decision == .always ? "Always allowed" : "Allowed"
            session.lastStep = "\(verb) from WatchMan"
            sessions[sessionId] = session
            showFeedback(verb, for: sessionId)
            advanceInbox(from: sessionId)
        }
    }

    /// Back at the terminal while WatchMan holds a prompt the terminal waits on: hand it over right away.
    func releasePrompts(forApp bundleIdentifier: String?) {
        for (id, session) in sessions where blockingPrompts.contains(id) && responders[id] != nil
            && session.host.bundleIdentifier == bundleIdentifier {
            answerPending(id, .ask)
            clearApproval(id)
        }
    }

    func hasPendingPrompt(_ sessionId: String) -> Bool { responders[sessionId] != nil || previewPrompts.contains(sessionId) }

    /// What a phone button for this session may act on right now (nil: nothing).
    /// Allow/Deny: the prompt WatchMan holds. Continue: the finished or stuck state the alert was about.
    func phoneScope(for sessionId: String, kind: PhoneAction.Kind) -> String? {
        guard let session = sessions[sessionId] else { return nil }
        switch kind {
        case .allow, .deny:
            return promptTokens[sessionId]
        case .proceed:
            guard session.host.canSend, session.status == .finished || session.stuck != nil else { return nil }
            return "\(session.status == .finished ? "finished" : "stuck"):\(session.statusSince.timeIntervalSince1970)"
        }
    }

    private func answerPending(_ sessionId: String, _ decision: PermissionDecision, extras: ReplyExtras? = nil) {
        promptTokens[sessionId] = nil
        blockingPrompts.remove(sessionId)
        approvalTimeouts.removeValue(forKey: sessionId)?.cancel()
        responders.removeValue(forKey: sessionId)?.answer(decision, extras: extras)
    }

    /// Answers Claude's question (AskUserQuestion) with the picked choices, or your own words.
    func answerQuestion(_ sessionId: String, with answers: QuestionAnswers) {
        guard hasPendingPrompt(sessionId), sessions[sessionId]?.pendingApproval?.isQuestion == true else { return }
        answerPending(sessionId, .allow, extras: ReplyExtras(answers: answers))
        clearApproval(sessionId)
        if var session = sessions[sessionId] {
            session.status = .working
            session.statusSince = Date()
            let picked = answers.response ?? answers.answers.values.sorted().joined(separator: ", ")
            session.lastStep = "Answered: \(picked)"
            sessions[sessionId] = session
            showFeedback("Answered", for: sessionId)
            advanceInbox(from: sessionId)
        }
    }

    /// Picks choice `index` of a question that has one question with single choices; false when it doesn't apply.
    func pickOption(_ index: Int, for sessionId: String) -> Bool {
        guard hasPendingPrompt(sessionId), let approval = sessions[sessionId]?.pendingApproval,
              let question = approval.simpleQuestion, question.options.indices.contains(index) else { return false }
        answerQuestion(sessionId, with: QuestionAnswers(answers: [question.question: question.options[index].label]))
        return true
    }

    private func clearApproval(_ sessionId: String) {
        guard var session = sessions[sessionId], session.pendingApproval != nil else { return }
        session.pendingApproval = nil
        sessions[sessionId] = session
    }

    // MARK: - Transcripts

    /// Reads new transcript lines shortly after an event (bursts of events share one read).
    func refreshTranscript(_ id: String, delay: Duration = .milliseconds(400), then completion: (() -> Void)? = nil) {
        if completion == nil, transcriptRefreshes[id] != nil { return }
        transcriptRefreshes[id]?.cancel()
        transcriptRefreshes[id] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled else { return }
            await self.loadTranscript(id)
            self.transcriptRefreshes[id] = nil
            completion?()
        }
    }

    private func loadTranscript(_ id: String) async {
        guard let path = sessions[id]?.transcriptPath, let state = await transcripts.read(path: path),
              var session = sessions[id] else { return }
        session.title = state.title ?? session.title
        session.lastReply = state.lastReply ?? session.lastReply
        session.continuedIn = state.continuedIn
        session.lastTurn = state.lastTurn
        session.tasks = state.tasks
        session.subagents = await subagentTracker.running(transcriptPath: path)
        session.verification = state.verification
        session.editedAfterSync = state.editedAfterSync
        if state.entrypoint == "claude-vscode" { session.host = .vscodeExtension }
        session.projectRoot = ProjectLocator.projectRoot(editedFiles: state.editedFiles, cwd: state.cwd ?? session.cwd,
                                                         isGitRoot: isGitRoot)
        if sessions[id] != session { sessions[id] = session }
    }

    func transcriptState(path: String) async -> TranscriptState? {
        await transcripts.read(path: path)
    }

    private func isGitRoot(_ dir: String) -> Bool {
        if let cached = gitRootCache[dir] { return cached }
        let result = FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git"))
        gitRootCache[dir] = result
        return result
    }

    // MARK: - Housekeeping

    /// Drops sessions whose Claude process has gone (terminal closed without SessionEnd).
    func pruneDeadSessions() {
        let now = Date()
        for (id, session) in sessions {
            let dead = session.pid.map { !ProcessAncestry.isAlive($0) }
                ?? (now.timeIntervalSince(session.lastActivity) > 12 * 3600)
            if dead {
                sessions[id] = nil
                answerPending(id, .ask)
            }
        }
    }

    func setSummary(_ summary: String?, for id: String) {
        sessions[id]?.summary = summary
    }

    /// Opens a session's page.
    func openPage(_ id: String) {
        pageId = id
        selectedId = id
        markSeen(id)
        toasts.removeAll { $0.sessionId == id }
    }
}

extension Notification.Name {
    static let watchManStartInbox = Notification.Name("watchManStartInbox")
}

/// A moment that needs nothing from you, told the way Settings → Notifications says.
enum NewsMoment {
    case started(Session, prompt: String?)
    case finished(Session)
    case stuck(Session)
    case error(Session)
    case limit(Session)
    case usage(window: String, percent: Int, resets: String?)
    case back(finished: Int, waiting: Int, stuck: Int)
}
