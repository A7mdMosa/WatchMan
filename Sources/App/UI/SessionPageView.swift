import AppKit
import SwiftUI
import WatchManCore

/// One session on its own page: what it's doing right now, the conversation, and a box to reply.
/// The page fits its content, up to `height`; a long chat scrolls.
struct SessionPageView: View {
    let session: Session
    let store: SessionStore
    var height: CGFloat = 440
    /// Shown in the WatchMan window (its keys always work there; the notch panel's inbox strip doesn't apply).
    var inWindow = false
    @State private var section: Section
    @State private var transcript: TranscriptState?
    @State private var note: String?
    @State private var busy = false
    /// The chat is scrolled to its end, so new steps and messages keep it there.
    @State private var atEnd = true
    /// Everything on the page but the chat (or the steps), and the chat's own content height.
    @State private var chrome: CGFloat = 0
    @State private var chatHeight: CGFloat = 200

    enum Section: String, CaseIterable { case chat = "Chat", steps = "Steps", changes = "Changes" }

    init(session: Session, store: SessionStore, height: CGFloat = 440, section: Section = .chat, inWindow: Bool = false) {
        self.session = session
        self.store = store
        self.height = height
        self.inWindow = inWindow
        _section = State(initialValue: section)
    }

    private var approval: PendingApproval? { store.hasPendingPrompt(session.id) ? session.pendingApproval : nil }
    /// The page's keys (⌘1–3, ⌘↩) work: always in the window, in the panel while it has the keyboard.
    private var keysWork: Bool { inWindow || store.panelHasKeyboard }

    /// In the panel, a page you open is ready to type into (not while a permission prompt waits: Enter would
    /// answer it, and ⌘↩ / ⌘⌫ are the keys then).
    private func focusReplyIfReady() {
        guard !inWindow, approval == nil || approval?.isQuestion == true || approval?.isPlan == true, session.host.canSend else { return }
        store.focusReplyId = session.id
        NotificationCenter.default.post(name: .watchManNeedsKeyboard, object: nil)
    }

    /// The chat takes what it needs, up to the room the rest of the page leaves; Steps and Changes take the room.
    private var bodyHeight: CGFloat {
        let room = max(120, height - chrome)
        // In the window the chat fills the height, so the reply box sits at the bottom
        return section == .chat && !inWindow ? max(60, min(chatHeight + 8, room)) : room
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.inbox, !inWindow { inboxStrip.arrive(1) }
            header.arrive(1)
            if session.failed || session.rateLimited { ErrorCard(session: session, store: store).arrive(2) }
            // The outcome first: what the last turn changed
            if let turn = session.lastTurn, !turn.isEmpty, session.status != .working {
                TurnStrip(turn: turn).arrive(2)
            }
            if !session.tasks.isEmpty { PlanCard(tasks: session.tasks).arrive(2) }
            if let approval, approval.isPlan {
                PlanApprovalCard(session: session, approval: approval, store: store, hints: keysWork, maxHeight: inWindow ? 520 : 300)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .top))))
                    .arrive(3)
            } else if let approval, approval.isQuestion {
                QuestionCard(session: session, approval: approval, store: store, hints: keysWork)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .top))))
                    .arrive(3)
            } else if let approval {
                PermissionCard(session: session, approval: approval, store: store, hints: keysWork)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .top))))
                    .arrive(3)
            }
            if let stuck = session.stuck {
                StuckBanner(session: session, reason: stuck, store: store)
            }
            if session.status == .working {
                StepTrail(session: session)
                    .transition(.opacity)
            }
            Group {
                switch section {
                case .chat: conversation
                case .steps: TimelineListView(session: session, store: store)
                case .changes: ChangesView(session: session)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: bodyHeight, alignment: .top)
            .arrive(4)
            if let queue = store.followUps[session.id], !queue.isEmpty {
                QueuedChips(sessionId: session.id, queue: queue, store: store)
            }
            composer.arrive(5)
            if let line = note ?? store.pageNote {
                Text(line).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { total in
            let measured = total - bodyHeight
            if abs(measured - chrome) > 0.5 { chrome = measured }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: approval != nil)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: session.status == .working)
        .task(id: session.lastActivity) { await load() }
        .onAppear(perform: focusReplyIfReady)
        .onChange(of: session.id) { _, _ in
            store.pageNote = nil
            focusReplyIfReady()
        }
        // Answered from WatchMan: the reply box takes the keyboard (not when it was answered in the terminal)
        .onChange(of: approval == nil) { _, answered in if answered && store.panelHasKeyboard { focusReplyIfReady() } }
    }

    // MARK: - Header

    /// Going through what's waiting: where you are, and the keys.
    private var inboxStrip: some View {
        let queue = store.waitingQueue
        let position = (queue.firstIndex { $0.id == session.id } ?? 0) + 1
        return HStack(spacing: 8) {
            Image(systemName: "tray.full.fill").font(.system(size: 10)).foregroundStyle(Theme.needsYou)
            Text(queue.count > 1 ? "\(position) of \(queue.count) waiting" : "Last one waiting")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.needsYou)
            Spacer()
            Text(store.hasPendingPrompt(session.id) && session.pendingApproval?.isQuestion == true ? "⌘1–4 Answer · ↩ Your own · ⇥ Next"
                 : store.hasPendingPrompt(session.id) ? "⌘↩ Allow · ⌘⌫ Deny · ⇥ Next"
                 : store.answerChips(for: session).isEmpty ? "↩ Send · ⇥ Next · Esc List" : "⌘1–3 Answer · ↩ Send · ⇥ Next")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.needsYou.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The project's tile and name, its status chip (with "✓ Allowed" for a moment after you answer), and the tabs.
    /// The way back, Open, ⋯ and × live in the notch row (or the panel's header row without a notch).
    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            // The window's toolbar already names the session
            if !inWindow {
                ProjectTile(session: session, size: 22)
                Text(session.label)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let task = session.task {
                    Text(task).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            PageStatusChip(session: session)
            if let context = session.contextPercent, context >= 50 { ContextChip(percent: context) }
            if session.remoteSessionId != nil { RemoteBadge(label: "Remote Control") }
            if let feedback = store.feedback, feedback.kind == .feedback, feedback.sessionId == session.id {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    Text(feedback.short).font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Theme.working)
                .transition(.opacity)
            }
            VerificationBadges(verification: session.verification)
            Spacer(minLength: 6)
            SegmentedTabs(selection: $section)
        }
        .animation(.easeOut(duration: 0.2), value: store.feedback)
    }

    // MARK: - Conversation

    private var messages: [TranscriptState.Message] {
        if let conversation = transcript?.conversation, !conversation.isEmpty { return conversation }
        // Until the transcript is read: what the session already knows
        var list: [TranscriptState.Message] = []
        if let prompt = session.lastTurn?.prompt { list.append(.init(id: 1, at: session.statusSince, fromYou: true, text: prompt)) }
        if let reply = session.lastReply { list.append(.init(id: 2, at: session.lastActivity, fromYou: false, text: reply)) }
        return list
    }

    /// The chat, the way the terminal shows it: your prompts, Claude's messages and the steps between them.
    /// Until the transcript is read, the messages the session already knows.
    private var chat: [TranscriptState.ChatItem] {
        if let chat = transcript?.chat, !chat.isEmpty { return chat }
        return messages.map { .message($0) }
    }

    /// Changes whenever something new arrives at the end of the chat.
    private var chatEnd: String { "\(chat.count)-\(transcript?.timeline.last?.id ?? 0)" }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    if let summary = session.summary {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Summary").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.unseen)
                            MarkdownText(text: summary).font(.system(size: 12.5)).foregroundStyle(Theme.primary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.unseen.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if chat.isEmpty {
                        Text("Nothing said yet.").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    }
                    ForEach(chat) { item in
                        switch item {
                        case .message(let message): ChatMessageView(message: message)
                        case .steps(let steps): ChatStepsView(steps: steps)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.trailing, 10)
                .padding(.bottom, 6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chatHeight = $0 }
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
            } action: { _, isAtEnd in
                atEnd = isAtEnd
            }
            // New steps and messages keep the chat at its end, unless you scrolled up to read
            .onChange(of: chatEnd) { _, _ in
                guard atEnd else { return }
                withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !atEnd {
                    Button {
                        withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.primary)
                            .frame(width: 26, height: 26)
                            .background(Color(white: 0.2), in: Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 14)
                    .padding(.bottom, 6)
                    .help("Jump to the latest")
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.15), value: atEnd)
        }
    }

    // MARK: - Composer

    @ViewBuilder
    private var composer: some View {
        if let approval, approval.isQuestion || approval.isPlan {
            // Your own words answer Claude's question, or say what to change in its plan
            ReplyField(session: session, store: store, large: true)
        } else if approval != nil {
            // Enter would answer Claude Code's prompt, so typing waits until it's answered
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text("Answer the prompt above first").font(.system(size: 12.5))
            }
            .foregroundStyle(Theme.faint)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        } else if session.host.canSend {
            VStack(alignment: .leading, spacing: 6) {
                let chips = store.answerChips(for: session)
                if !chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(chips.enumerated()), id: \.element.text) { index, chip in
                            Button { send(chip.text) } label: {
                                HStack(spacing: 5) {
                                    Text(chip.label)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(chip.isAnswer ? Theme.unseen : Theme.primary.opacity(0.85))
                                        .lineLimit(1)
                                    // The key works wherever the page has the keyboard, even while you type
                                    if keysWork {
                                        Text("⌘\(index + 1)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.faint)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background((chip.isAnswer ? Theme.unseen : Color.white).opacity(chip.isAnswer ? 0.14 : 0.08),
                                            in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
                            .help("Send: \(chip.text) (⌘\(index + 1))")
                        }
                        Spacer(minLength: 0)
                    }
                }
                ReplyField(session: session, store: store, large: true)
            }
        } else {
            Text("\(session.host.label) can't take replies from WatchMan. Open it to answer.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
        }
    }

    private func send(_ text: String) {
        if session.status == .working {
            store.enqueueFollowUp(text, for: session.id)
            note = "Queued: sent when \(session.label) finishes"
            return
        }
        busy = true
        note = "Sending…"
        Task {
            let error = await store.reply(text, to: session.id)
            busy = false
            note = error ?? "Sent: \(text)"
        }
    }

    private func load() async {
        guard let path = session.transcriptPath, let state = await store.transcriptState(path: path) else { return }
        transcript = state
    }
}

/// The page's status chip: ✋ and the wait for a permission, a bubble for a question, ● Working, ✓ Done.
/// The old chip fades out before the new one comes in, so their text never overlaps.
struct PageStatusChip: View {
    let session: Session

    private enum Kind: Equatable { case permission, question, working, done, fresh, idle, failed, limited }

    private var kind: Kind {
        if session.rateLimited { return .limited }
        if session.failed { return .failed }
        switch session.status {
        case .needsYou: return session.asksPermission ? .permission : .question
        case .working: return .working
        case .finished: return session.seen ? .done : .fresh
        case .idle, .closed: return .idle
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            chip.id(kind)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.15).delay(0.14)),
                                        removal: .opacity.animation(.easeOut(duration: 0.12))))
        }
        .animation(.easeOut(duration: 0.15), value: kind)
    }

    @ViewBuilder
    private var chip: some View {
        switch kind {
        case .permission, .question:
            TimelineView(.periodic(from: .now, by: 15)) { context in
                pill(session.pendingApproval?.isPlan == true ? "list.bullet.clipboard.fill"
                     : kind == .permission ? "hand.raised.fill" : "questionmark.bubble.fill", nil,
                     session.timeText(now: context.date), Theme.needsYou)
            }
        case .working: pill(nil, Theme.working, "Working", Theme.working)
        case .fresh: pill("checkmark.circle.fill", nil, "New result", Theme.unseen)
        case .done: pill("checkmark", nil, "Done", Theme.unseen)
        case .idle: pill(nil, nil, "Idle", Theme.secondary)
        case .failed: pill("xmark.octagon.fill", nil, "Stopped", Theme.failed)
        case .limited: pill("hourglass", nil, session.limitReset.map { "Resets \($0)" } ?? "Usage limit", Theme.limit)
        }
    }

    private func pill(_ symbol: String?, _ dot: Color?, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 21)
        .background(color.opacity(0.15), in: Capsule())
        .fixedSize()
    }
}

/// Chat, Steps and Changes as a small segmented control.
struct SegmentedTabs: View {
    @Binding var selection: SessionPageView.Section

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SessionPageView.Section.allCases, id: \.self) { item in
                Button { selection = item } label: {
                    Text(item.rawValue)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(selection == item ? Theme.primary : Theme.faint)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Color.white.opacity(selection == item ? 0.12 : 0), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.05), in: Capsule())
    }
}

/// What Claude is doing, as two lines in the terminal's style: the step before (dimmed, with a ✓) and the current
/// one (a dot in its colour, a shimmer when it arrives). A new step slides in from below and pushes the old one up.
struct StepTrail: View {
    let session: Session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Line: Identifiable, Equatable { var id: Int; var text: String }

    var body: some View {
        let current = Line(id: session.stepNumber, text: session.lastStep ?? "Thinking…")
        let lines = (session.previousStep.map { [Line(id: session.stepNumber - 1, text: $0)] } ?? []) + [current]
        VStack(alignment: .leading, spacing: 5) {
            ForEach(lines) { line in
                row(line, done: line.id != current.id)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                                     removal: .move(edge: .top).combined(with: .opacity)))
            }
            if !session.subagents.isEmpty {
                SubagentPills(agents: session.subagents).padding(.leading, -8).padding(.top, 2)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.8), value: current)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working: \(current.text)")
    }

    private func row(_ line: Line, done: Bool) -> some View {
        let (verb, detail) = ChatStepsView.split(line.text)
        let label = HStack(spacing: 0) {
            Text(verb).fontWeight(.semibold).foregroundStyle(Theme.primary.opacity(0.9))
            if let detail { Text("(\(detail))").foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle) }
        }
        .font(.system(size: 12, design: .monospaced))
        return HStack(spacing: 7) {
            ZStack {
                Text("●").font(.system(size: 8)).foregroundStyle(ChatStepsView.color(for: verb)).opacity(done ? 0 : 1)
                Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.working).opacity(done ? 1 : 0)
            }
            .frame(width: 10)
            label.overlay { if !done && !reduceMotion { Shimmer(key: line.id).mask(label) } }
        }
        .scaleEffect(done ? 0.885 : 1, anchor: .leading)
        .opacity(done ? 0.55 : 1)
    }
}

/// A soft light sweeping across, twice, when it appears; then still.
struct Shimmer: View {
    let key: Int
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 60)
                .offset(x: phase * (geo.size.width + 60) - 60)
        }
        .allowsHitTesting(false)
        .onAppear {
            phase = -0.3
            withAnimation(.easeInOut(duration: 1.2).repeatCount(2, autoreverses: false).delay(0.2)) { phase = 1.3 }
        }
        .id(key)
    }
}

/// Claude's question (its AskUserQuestion tool), the way the terminal asks it: the question, then each choice
/// with its explanation. One click answers a single question; several questions (or several picks) are sent
/// together. Your own words in the reply box answer it too.
struct QuestionCard: View {
    let session: Session
    let approval: PendingApproval
    let store: SessionStore
    var hints = false
    @State private var picks: [String: Set<String>] = [:]

    /// One question with single choices: a click sends it.
    private var oneClick: Bool { approval.simpleQuestion != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").font(.system(size: 11, weight: .semibold))
                Text((approval.questions.count > 1 ? "\(approval.questions.count) questions" : approval.questions.first?.header ?? "Question")
                    .uppercased())
                    .font(.system(size: 10.5, weight: .bold)).tracking(0.8)
                Spacer()
                if let handBack = approval.handBackAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(handBack.timeIntervalSince(context.date)))
                        Text("terminal takes over in \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                            .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Theme.faint)
                    }
                }
            }
            .foregroundStyle(Theme.needsYou)
            ForEach(Array(approval.questions.enumerated()), id: \.offset) { _, question in
                VStack(alignment: .leading, spacing: 6) {
                    if approval.questions.count > 1, let header = question.header {
                        Text(header.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.faint)
                    }
                    Text(question.question)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if question.multiSelect {
                        Text("Pick any").font(.system(size: 11)).foregroundStyle(Theme.faint)
                    }
                    VStack(spacing: 4) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                            choice(question, option, index: index)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                if !oneClick {
                    Button { send() } label: {
                        Text("Send Answers").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 12).frame(height: 26)
                            .background(Theme.primary.opacity(allAnswered ? 1 : 0.35), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!allAnswered)
                }
                Button("Skip") { store.respond(to: session.id, with: .deny) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                    .help("Tell Claude you'd rather not answer")
                Button("Answer in \(session.host.label)") { store.respond(to: session.id, with: .ask); store.open(session) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                    .help("Hand the question back to the terminal")
                Spacer()
                Text("or type your own answer below").font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
        }
        .padding(14)
        .background(Wash(color: Theme.needsYou))
        .accessibilityElement(children: .contain)
    }

    private var allAnswered: Bool {
        approval.questions.allSatisfy { !(picks[$0.question] ?? []).isEmpty }
    }

    private func choice(_ question: AskedQuestion, _ option: AskedQuestion.Option, index: Int) -> some View {
        let picked = picks[question.question]?.contains(option.label) == true
        return Button {
            if oneClick {
                _ = store.pickOption(index, for: session.id)
            } else {
                var set = picks[question.question] ?? []
                if question.multiSelect {
                    if picked { set.remove(option.label) } else { set.insert(option.label) }
                } else {
                    set = [option.label]
                }
                picks[question.question] = set
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Group {
                    if question.multiSelect {
                        Image(systemName: picked ? "checkmark.square.fill" : "square")
                    } else if picked {
                        Image(systemName: "largecircle.fill.circle")
                    } else {
                        Text("\(index + 1)").monospacedDigit()
                    }
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(picked ? Theme.needsYou : Theme.faint)
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                    if let description = option.description {
                        Text(description).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                if oneClick && hints && index < 4 {
                    Text("⌘\(index + 1)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(picked ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func send() {
        var answers: [String: String] = [:]
        for question in approval.questions {
            // Several picks in the order Claude listed them, joined the way Claude Code writes them
            let chosen = question.options.map(\.label).filter { picks[question.question]?.contains($0) == true }
            if !chosen.isEmpty { answers[question.question] = chosen.joined(separator: ", ") }
        }
        store.answerQuestion(session.id, with: QuestionAnswers(answers: answers))
    }
}

/// Claude's plan, when it asks to leave plan mode and start: the plan in full, then Approve (⌘↩), Approve with
/// edits accepted from then on, or Keep Planning (⌘⌫), which sends what you typed below as what to change.
struct PlanApprovalCard: View {
    let session: Session
    let approval: PendingApproval
    let store: SessionStore
    var hints = false
    var maxHeight: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard.fill").font(.system(size: 11, weight: .semibold))
                Text("PLAN READY").font(.system(size: 10.5, weight: .bold)).tracking(0.8)
                Spacer()
                if let handBack = approval.handBackAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(handBack.timeIntervalSince(context.date)))
                        Text("terminal takes over in \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                            .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Theme.faint)
                    }
                }
            }
            .foregroundStyle(Theme.needsYou)
            ScrollView(.vertical, showsIndicators: true) {
                MarkdownBlocksView(blocks: MarkdownBlocks.parse(approval.plan ?? ""))
                    .padding(.trailing, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 7) {
                AllowButton(title: "Approve", hint: hints, height: 26) { store.respond(to: session.id, with: .allow) }
                    .help("Start on the plan, asking before each edit")
                Button { store.respond(to: session.id, with: .always) } label: {
                    Text("Approve, Accept Edits").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                        .padding(.horizontal, 11).frame(height: 26)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Start on the plan and let Claude make edits without asking")
                Button { keepPlanning() } label: {
                    HStack(spacing: 5) {
                        Text("Keep Planning").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                        if hints { Text("⌘⌫").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.faint) }
                    }
                    .padding(.horizontal, 11).frame(height: 26)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Tell Claude to keep planning (what you type below goes with it)")
                Spacer()
                Text("type what to change below").font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
        }
        .padding(14)
        .background(Wash(color: Theme.needsYou))
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Approve") { store.respond(to: session.id, with: .allow) }
        .accessibilityAction(named: "Keep Planning") { keepPlanning() }
    }

    /// What's in the reply box goes along as the change you want (the store picks it up).
    private func keepPlanning() {
        store.respond(to: session.id, with: .deny)
    }
}

/// A permission prompt, read in full: what it is, the exact command (or the edit as a diff), where it runs, and the
/// answers. A line along the bottom runs out when WatchMan hands the prompt back to the terminal.
struct PermissionCard: View {
    let session: Session
    let approval: PendingApproval
    let store: SessionStore
    var hints = false
    @State private var showAll = false
    @State private var left: CGFloat = 1

    private var look: (symbol: String, label: String) {
        switch approval.kind {
        case .command: ("terminal", "Run a command")
        case .edit: ("pencil", "Edit a file")
        case .write: ("doc.badge.plus", "Write a file")
        case .question: ("questionmark.bubble.fill", "Question")
        case .plan: ("list.bullet.clipboard.fill", "Plan")
        case .other: ("hand.raised.fill", "Use \(approval.tool)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: look.symbol).font(.system(size: 11, weight: .semibold))
                Text(look.label.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.8)
                Spacer()
                if let handBack = approval.handBackAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(handBack.timeIntervalSince(context.date)))
                        Text("terminal takes over in \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                            .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Theme.faint)
                    }
                }
            }
            .foregroundStyle(Theme.needsYou)
            Text(approval.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
            switch approval.kind {
            case .command: command
            case .edit, .write: diff
            case .question, .plan, .other:
                Text(approval.detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.primary.opacity(0.9))
            }
            if approval.isRisky {
                Label("This deletes, overwrites, runs as root or rewrites history. Read it before allowing.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.needsYou)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 7) {
                AllowButton(hint: hints, height: 26) { answer(.allow) }
                DenyButton(hint: hints, height: 26) { answer(.deny) }
                ApprovalMoreMenu(session: session, approval: approval, store: store, height: 26)
            }
        }
        .padding(14)
        .background(Wash(color: Theme.needsYou))
        .overlay(alignment: .bottomLeading) {
            GeometryReader { geo in
                Rectangle().fill(Color.white.opacity(0.32)).frame(width: max(0, (geo.size.width - 28) * left), height: 2)
                    .offset(x: 14, y: geo.size.height - 3)
            }
            .allowsHitTesting(false)
        }
        .onAppear(perform: startCountdown)
        .onChange(of: approval.handBackAt) { _, _ in startCountdown() }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Allow") { answer(.allow) }
        .accessibilityAction(named: "Deny") { answer(.deny) }
    }

    /// One linear animation down to the hand-back, not a timer.
    private func startCountdown() {
        guard let handBack = approval.handBackAt else { left = 0; return }
        let total = max(1, handBack.timeIntervalSince(approval.requestedAt))
        let remaining = max(0, handBack.timeIntervalSinceNow)
        var start = Transaction()
        start.disablesAnimations = true
        withTransaction(start) { left = CGFloat(remaining / total) }
        withAnimation(.linear(duration: remaining)) { left = 0 }
    }

    private func answer(_ decision: PermissionDecision) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.respond(to: session.id, with: decision) }
    }

    private var command: some View {
        let text = approval.command ?? approval.detail
        let long = text.count > 400
        return VStack(alignment: .leading, spacing: 5) {
            Text("$ " + (long && !showAll ? String(text.prefix(400)) + "…" : text))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            HStack(spacing: 8) {
                if let cwd = approval.cwd { Text("in \(Self.tilde(cwd))").font(.system(size: 10.5)).foregroundStyle(Theme.faint) }
                if long { showAllButton }
            }
        }
    }

    private var diff: some View {
        let diff = approval.diff ?? LineDiff(lines: [], added: 0, removed: 0)
        let cap = 7
        let shown = showAll ? diff.lines : Array(diff.lines.prefix(cap))
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(approval.fileName ?? approval.tool).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.primary)
                Text("+\(diff.added)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.working)
                Text("−\(diff.removed)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.failed)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                    Self.diffLine(line)
                }
            }
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            HStack(spacing: 8) {
                if let path = approval.filePath { Text(Self.tilde(path)).font(.system(size: 10.5)).foregroundStyle(Theme.faint).lineLimit(1) }
                if diff.lines.count > cap { showAllButton }
            }
        }
    }

    private static func diffLine(_ line: LineDiff.Line) -> some View {
        let (prefix, color, fill): (String, Color, Color) = switch line.kind {
        case .removed: ("−", Theme.failed, Theme.failed.opacity(0.14))
        case .added: ("+", Theme.working, Theme.working.opacity(0.13))
        case .context: (" ", Theme.secondary, .clear)
        case .gap: ("⋯", Theme.faint, .clear)
        }
        return Text(line.kind == .gap ? "⋯" : "\(prefix) \(line.text)")
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
    }

    private var showAllButton: some View {
        Button(showAll ? "Show less" : "Show all") { withAnimation(.smooth(duration: 0.2)) { showAll.toggle() } }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.unseen)
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// "‹ All sessions": back to the list.
struct BackToSessions: View {
    let store: SessionStore
    var title = "Sessions"

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.18)) { store.pageId = nil }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Back to the list (Esc)")
        .fixedSize()
    }
}

/// A page's actions: Open (with its app's icon), ⋯ and ×.
struct PageControls: View {
    let session: Session
    let store: SessionStore
    let close: () -> Void
    var showClose = true

    var body: some View {
        HStack(spacing: 6) {
            Button { store.open(session) } label: {
                HStack(spacing: 5) {
                    HostIcon(host: session.host, size: 14)
                    Text("Open").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                }
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Color.white.opacity(0.10), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Open in \(session.host.label) (O)")
            .accessibilityLabel("Open in \(session.host.label)")
            SessionMoreMenu(session: session, store: store)
            if showClose {
                Spacer(minLength: 0)
                IconButton(symbol: "macwindow", help: "Open in the WatchMan window") {
                    NotificationCenter.default.post(name: .watchManOpenWindow, object: session.id)
                }
                IconButton(symbol: "xmark", help: "Close (Esc)", action: close)
                    .accessibilityLabel("Close")
            }
        }
    }
}

/// A page's ⋯ menu.
struct SessionMoreMenu: View {
    let session: Session
    let store: SessionStore

    var body: some View {
        Menu {
            SessionMoreMenuItems(session: session, store: store)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.secondary)
        .frame(width: 28, height: 24)
        .background(Color.white.opacity(0.08), in: Capsule())
        .help("More")
        .accessibilityLabel("More")
    }
}

/// What the ⋯ menu holds, in the panel and in the window's toolbar.
struct SessionMoreMenuItems: View {
    let session: Session
    let store: SessionStore

    var body: some View {
        Button(session.summary == nil ? "Summarize with Haiku" : "Hide Summary") {
            if session.summary == nil {
                store.pageNote = "Summarizing with Haiku…"
                Task {
                    let result = await store.summarize(session.id)
                    store.pageNote = result == nil ? "Couldn't summarize (is the claude CLI installed?)" : nil
                }
            } else {
                store.setSummary(nil, for: session.id)
            }
        }
        if let text = session.lastReply {
            Button("Copy Last Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                store.pageNote = "Copied"
            }
        }
        if let obsidian = ObsidianIndex.shared.note(for: session.projectRoot) {
            Button("Open Obsidian Note") { ObsidianIndex.shared.open(obsidian) }
        }
        if let remote = session.remoteURL {
            Button("Open in the Claude App") { NSWorkspace.shared.open(remote) }
            Button("Copy the Remote Control Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(remote.absoluteString, forType: .string)
                store.pageNote = "Copied"
            }
        }
        if session.host.canSend {
            Button("Run /project-sync") {
                Task { store.pageNote = await store.reply("/project-sync", to: session.id) ?? "Sent: /project-sync" }
            }
        }
        if let root = session.projectRoot {
            Divider()
            let muted = ProjectSettings.shared.isMuted(root)
            Button(muted ? "Unmute \(session.label)" : "Mute \(session.label)") {
                ProjectSettings.shared.update(root) { $0.muted = muted ? nil : true }
                store.pageNote = muted ? "Alerts back on for \(session.label)" : "No sounds, messages or phone alerts for \(session.label)"
            }
        }
        if session.status == .working, Hosts.canInterrupt(session.host) {
            Divider()
            Button("Stop Claude") {
                Task { store.pageNote = await Hosts.interrupt(session) ?? "Stopped" }
            }
        }
    }
}

/// One message, the way Claude Code draws it in the terminal: your prompt after a > on a grey band, Claude's
/// after a white dot (a long one shows its start and its end, where the conclusion and the question are, with
/// the middle folded).
struct ChatMessageView: View {
    let message: TranscriptState.Message
    @State private var unfolded = false

    private static let foldAfter = 16

    /// Your prompt without the tags Claude Code wraps pasted text in.
    static func cleanPrompt(_ text: String) -> String {
        text.replacingOccurrences(of: #"</?pasted_content[^>]*>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        if !message.questions.isEmpty {
            QuestionChatCard(questions: message.questions, answers: message.answers, note: message.answerNote)
                .padding(.top, 4)
        } else if message.fromYou {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(">")
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                let text = Self.cleanPrompt(message.text)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(text)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .padding(.top, 4)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("●").font(.system(size: 9)).foregroundStyle(Theme.primary)
                let blocks = MarkdownBlocks.parse(message.text)
                VStack(alignment: .leading, spacing: 8) {
                    if blocks.count > Self.foldAfter, !unfolded {
                        MarkdownBlocksView(blocks: Array(blocks.prefix(4)))
                        Button { unfolded = true } label: {
                            Text("··· \(blocks.count - 12) more ···")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.07), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        MarkdownBlocksView(blocks: Array(blocks.suffix(8)))
                    } else {
                        MarkdownBlocksView(blocks: blocks)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Stopped with an error: what Claude Code said, and Retry.
struct ErrorCard: View {
    let session: Session
    let store: SessionStore

    /// A usage limit reads as a wait, not a failure: orange, with when it resets.
    private var look: (symbol: String, color: Color, title: String, detail: String) {
        if session.rateLimited {
            return ("hourglass", Theme.limit, "Usage limit reached",
                    (session.limitReset.map { "It resets \($0). " } ?? "") + "WatchMan can type \"continue\" for you then, so Claude picks up where it stopped.")
        }
        return ("xmark.octagon.fill", Theme.failed, "Stopped with an error",
                session.errorText ?? "Claude Code reported an error (often an overloaded API). Retry picks up where it stopped.")
    }

    var body: some View {
        let look = look
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: look.symbol).font(.system(size: 15)).foregroundStyle(look.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(look.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(look.color)
                Text(look.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 6)
            if session.host.canSend {
                if session.rateLimited {
                    // Retrying now would only hit the limit again: continue when it resets
                    ContinueAtButton(session: session, store: store, tint: look.color)
                } else {
                    PillButton(title: "Retry", symbol: "arrow.clockwise", tint: look.color) { store.retry(session.id) }
                        .help("Types \"continue\" into the session")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(look.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Claude's to-do list for the work: the glance line, and the whole list when opened.
struct PlanCard: View {
    let tasks: [ClaudeTask]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.smooth(duration: 0.18)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    Text("Plan").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                    Text("\(tasks.doneCount) of \(tasks.count) done").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    ProgressView(value: Double(tasks.doneCount), total: Double(max(tasks.count, 1)))
                        .tint(Theme.working)
                        .frame(width: 80)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(tasks) { task in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: task.status == .done ? "checkmark.circle.fill"
                                  : task.status == .inProgress ? "circle.lefthalf.filled" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(task.status == .done ? Theme.working : task.status == .inProgress ? Theme.unseen : Theme.faint)
                            Text(task.text)
                                .font(.system(size: 12.5, weight: task.status == .inProgress ? .semibold : .regular))
                                .foregroundStyle(task.status == .done ? Theme.secondary : Theme.primary)
                                .strikethrough(task.status == .done, color: Theme.secondary.opacity(0.6))
                        }
                    }
                }
                .padding(.leading, 17)
            } else {
                TaskGlance(tasks: tasks).padding(.leading, -8)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// "8 files edited · tests ✓ · 1 commit · 45K tokens" for the last turn.
struct TurnStrip: View {
    let turn: TurnSummary

    var body: some View {
        HStack(spacing: 6) {
            if !turn.filesEdited.isEmpty {
                chip("pencil", "\(turn.filesEdited.count) file\(turn.filesEdited.count == 1 ? "" : "s") edited", Theme.secondary)
                    .help(turn.filesEdited.map { ($0 as NSString).lastPathComponent }.sorted().joined(separator: ", "))
            }
            if let passed = turn.testsPassed {
                chip(passed ? "checkmark.circle.fill" : "xmark.circle.fill", passed ? "tests passed" : "tests failed",
                     passed ? Theme.working : Theme.failed)
            }
            if turn.commits > 0 {
                chip("arrow.triangle.branch", "\(turn.commits) commit\(turn.commits == 1 ? "" : "s")", Theme.secondary)
            }
            if turn.tokens > 0 {
                chip("sparkles", "\(UsageSummary.format(turn.tokens)) tokens", Theme.faint)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8.5))
            Text(text).font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.06), in: Capsule())
    }
}

/// Claude's closing question, highlighted, with one-click answers.
struct ClosingQuestionView: View {
    let ask: ClosingQuestion
    let canAnswer: Bool
    let answer: (ClosingQuestion.Answer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").font(.system(size: 10)).foregroundStyle(Theme.unseen)
                Text(ask.question).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(3)
            }
            if canAnswer, !ask.answers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ask.answers, id: \.text) { item in
                            PillButton(title: item.label, symbol: "arrowshape.turn.up.right.fill", tint: Theme.unseen) {
                                answer(item)
                            }
                            .help("Send: \(item.text)")
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Theme.unseen.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PillButton: View {
    let title: String
    let symbol: String
    var tint: Color = Theme.primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension Notification.Name {
    static let watchManNeedsKeyboard = Notification.Name("watchManNeedsKeyboard")
}

extension SessionStore {
    /// Opens the session's tab and marks its result as seen.
    func open(_ session: Session) {
        markSeen(session.id)
        Hosts.open(session)
        NotificationCenter.default.post(name: .watchManCollapse, object: nil)
    }

    /// Stops Claude (Esc), waits for it to settle at its prompt, then types the message.
    func interruptAndSend(_ text: String, to id: String) async -> String? {
        guard let session = sessions[id] else { return nil }
        guard Hosts.canInterrupt(session.host) else { return "\(session.host.label) can't be stopped from WatchMan." }
        if let error = await Hosts.interrupt(session) { return error }
        try? await Task.sleep(for: .milliseconds(1500))
        return await reply(text, to: id)
    }

    /// Sends a reply, refusing while Claude waits on a permission prompt (Enter would answer it).
    func reply(_ text: String, to id: String) async -> String? {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let session = sessions[id] else { return nil }
        // Claude asked a question: your words are the answer (like typing your own in the terminal's picker)
        if session.pendingApproval?.isQuestion == true, hasPendingPrompt(id) {
            answerQuestion(id, with: QuestionAnswers(response: message))
            return nil
        }
        // Claude's plan: your words are what to change, and it keeps planning
        if session.pendingApproval?.isPlan == true, hasPendingPrompt(id) {
            respond(to: id, with: .deny, message: message)
            return nil
        }
        if session.pendingApproval != nil { return "Claude is waiting for a permission answer. Answer that first." }
        if case .needsYou(let reason) = session.status, reason.lowercased().contains("permission") {
            return "Claude is waiting for a permission answer in the terminal. Answer that first."
        }
        markSeen(id)
        let error = await Hosts.send(message, to: session)
        if error == nil {
            showFeedback("Sent", for: id)
            if session.status.isNeedsYou { advanceInbox(from: id) }
        }
        return error
    }
}
