import SwiftUI
import WatchManCore

/// The list of sessions, shared by the notch and the menu bar popover.
struct SessionListView: View {
    let store: SessionStore
    var maxHeight: CGFloat = 420
    @State private var contentHeight: CGFloat = 200
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// ⇥ to the next waiting session: the page leaves to the left and the next comes in from the right.
    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeOut(duration: 0.2)) }
        return .asymmetric(
            insertion: .offset(x: 40).combined(with: .opacity).animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.1)),
            removal: .offset(x: -40).combined(with: .opacity).animation(.easeIn(duration: 0.16)))
    }

    var body: some View {
        if let id = store.pageId, let session = store.sessions[id] {
            SessionPageView(session: session, store: store, height: maxHeight)
                .id(session.id)
                .transition(pageTransition)
        } else if !store.pendingDrop.isEmpty {
            DropChooser(store: store, maxHeight: maxHeight)
        } else if let page = store.otherPage {
            SidePage(page: page, store: store, height: maxHeight)
        } else if store.allClear {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(Theme.working)
                Text("All clear").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
                Text("Nothing else is waiting for you.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            list
        }
    }

    private var list: some View {
        let parts = store.split()
        return VStack(alignment: .leading, spacing: 8) {
            if store.attentionOnly { header }
            if parts.active.isEmpty && parts.dormant.isEmpty {
                Text(store.attentionOnly ? "Nothing needs you and nothing new."
                     : "No Claude sessions yet. They show up here as soon as they do something.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                // Grows with its rows up to maxHeight (drag the handle to change it), then scrolls
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 10) {
                            sections(parts.active)
                            if !parts.dormant.isEmpty {
                                dormantToggle(parts.dormant.count)
                                if store.showDormant { rows(parts.dormant, offset: parts.active.count).opacity(0.8) }
                            }
                            if !store.attentionOnly { resumeRow }
                        }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }
                    .frame(height: min(contentHeight, maxHeight))
                    // Back from a session's page: the list shows where you were
                    .onAppear {
                        guard let id = store.selectedId else { return }
                        Task {
                            try? await Task.sleep(for: .milliseconds(60))
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    .onChange(of: store.selectedId) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
    }

    /// The list in sections: what needs you, what's working, what's done, what's idle.
    private func sections(_ sessions: [Session]) -> some View {
        let groups = SessionSection.group(sessions)
        var offsets: [Int] = []
        var running = 0
        for group in groups { offsets.append(running); running += group.sessions.count }
        return VStack(spacing: 10) {
            ForEach(Array(groups.enumerated()), id: \.element.kind) { index, group in
                VStack(spacing: 2) {
                    SectionLabel(title: group.kind.title, count: group.sessions.count, color: group.kind.color)
                        .arrive(index * 2)
                    rows(group.sessions, offset: offsets[index])
                        .arrive(index * 2 + 1)
                }
            }
        }
    }

    private func rows(_ sessions: [Session], offset: Int = 0) -> some View {
        let shared = store.sharedLabels
        return VStack(spacing: 2) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                SessionRowView(session: session, store: store, shortcut: offset + index < 9 ? offset + index + 1 : nil,
                               sharedLabel: shared.contains(session.label))
                    .id(session.id)
            }
        }
    }

    private func dormantToggle(_ count: Int) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.18)) { store.showDormant.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: store.showDormant ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Idle for over an hour · \(count)")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button("Clear") {
                withAnimation(.smooth(duration: 0.18)) { store.clearIdle() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .help("Hide these until they do something again")
        }
        .foregroundStyle(Theme.faint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Earlier sessions live at the end of the list, one click away.
    private var resumeRow: some View {
        Button { store.otherPage = .recent } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 10, weight: .semibold))
                Text("Resume an earlier session").font(.system(size: 11, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.faint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Opened from the right side: only what needs you and what's new, with a way back to everything.
    private var header: some View {
        HStack(spacing: 8) {
            if store.attentionOnly {
                Text("Needs you and new")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .fixedSize()
                Button {
                    withAnimation(.smooth(duration: 0.18)) { store.attentionOnly = false }
                } label: {
                    Text("Show all \(store.ordered.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
    }
}

/// The open panel's notch row: your plan's usage, named ("Session 23% · Week 41%"), with when each resets on
/// hover. The list itself already says what's waiting, working and new.
struct PanelSummary: View {
    let store: SessionStore

    /// Rings and both limits when there's room left of the camera, then without rings, then the session only.
    var body: some View {
        if let usage = store.planUsage {
            ViewThatFits(in: .horizontal) {
                line(usage, rings: true, week: true)
                line(usage, rings: false, week: true)
                line(usage, rings: false, week: false)
            }
            .help("Your Claude plan: \(PlanUsage.summary(usage))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Claude plan usage: \(PlanUsage.summary(usage))")
        }
    }

    private func line(_ usage: PlanUsage, rings: Bool, week: Bool) -> some View {
        HStack(spacing: 12) {
            if let session = usage.session { item("Session", session, ring: rings) }
            if week, let weekly = usage.week { item("Week", weekly, ring: rings) }
        }
        .fixedSize()
    }

    private func item(_ name: String, _ window: UsageWindow, ring: Bool) -> some View {
        HStack(spacing: 5) {
            if ring { UsageRing(percent: window.percent, color: window.color, size: 12, line: 2.5) }
            Text(name).font(.system(size: 11.5)).foregroundStyle(Theme.faint)
            Text("\(Int(window.percent))%").font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(window.percent >= 70 ? window.color : Theme.secondary)
        }
    }
}

/// The sections of the list.
struct SessionSection {
    enum Kind: Int, Comparable {
        case needsYou, working, done, idle
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .needsYou: "Needs you"
            case .working: "Working"
            case .done: "Done"
            case .idle: "Idle"
            }
        }

        var color: Color {
            switch self {
            case .needsYou: Theme.needsYou
            case .working: Theme.working
            case .done: Theme.unseen
            case .idle: Theme.faint
            }
        }

        init(_ session: Session) {
            if session.failed || session.rateLimited || session.status.isNeedsYou { self = .needsYou }
            else if session.status == .working { self = .working }
            else if session.status == .finished { self = .done }
            else { self = .idle }
        }
    }

    var kind: Kind
    var sessions: [Session]

    /// Keeps the list's order inside each section.
    static func group(_ sessions: [Session]) -> [SessionSection] {
        var groups: [Kind: [Session]] = [:]
        for session in sessions { groups[Kind(session), default: []].append(session) }
        return groups.keys.sorted().map { SessionSection(kind: $0, sessions: groups[$0] ?? []) }
    }
}

extension SessionStore {
    /// Project names more than one listed session shares ("WatchMan" three times): those rows lead with their task.
    var sharedLabels: Set<String> {
        var counts: [String: Int] = [:]
        for session in ordered { counts[session.label, default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    /// Sessions run in more than one app, so rows show which.
    var mixedHosts: Bool { Set(ordered.map(\.host)).count > 1 }
}

/// One session in the list: its project tile, what it is and what it's doing, its status chip, and Allow / Deny
/// on the same line when it asks. Under the pointer the chip gives way to its app and its chat.
/// Click: the chat. ⌘-click: its terminal or editor. Right-click: everything else.
struct SessionRowView: View {
    let session: Session
    let store: SessionStore
    var shortcut: Int?
    /// Another listed session has the same project name: lead with the task.
    var sharedLabel = false
    @State private var hovering = false

    private var selected: Bool { store.selectedId == session.id }
    private var revealed: Bool { hovering || selected }
    private var approval: PendingApproval? { store.hasPendingPrompt(session.id) ? session.pendingApproval : nil }

    var body: some View {
        let titles = session.rowTitles(shared: sharedLabel)
        HStack(spacing: 11) {
            ProjectTile(session: session)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(titles.title)
                        .font(.system(size: 13, weight: session.isUnseenResult ? .bold : .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let subtitle = titles.subtitle {
                        Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                    if session.remoteSessionId != nil { RemoteBadge() }
                    if session.stuck != nil {
                        Text("stuck?")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.needsYou)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.needsYou.opacity(0.15), in: Capsule())
                    }
                    if let queued = store.followUps[session.id], !queued.isEmpty {
                        Text("\(queued.count) queued").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.unseen)
                    }
                    VerificationBadges(verification: session.verification)
                }
                RowDetail(session: session, size: 11.5)
            }
            Spacer(minLength: 8)
            if let approval {
                ApprovalAnswers(session: session, approval: approval, store: store, hints: selected && store.panelHasKeyboard,
                                review: { openChat() })
            } else if !session.tasks.isEmpty {
                PlanTrack(tasks: session.tasks)
            }
            // The chip, and in its place under the pointer: the shortcut, the app and the chat
            StatusChip(session: session)
                .frame(minWidth: 44, alignment: .trailing)
                .opacity(revealed ? 0 : 1)
                .overlay(alignment: .trailing) {
                    HStack(spacing: 5) {
                        if let shortcut {
                            Text("\(shortcut)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.faint)
                                .frame(width: 15, height: 15)
                                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
                        }
                        OpenButtons(session: session, store: store, openChat: openChat)
                    }
                    .fixedSize()
                    .opacity(revealed ? 1 : 0)
                    .allowsHitTesting(revealed)
                }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 46)
        .background(selected ? Theme.cardSelected : (hovering ? Theme.cardHover : Color.clear),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(selected ? 0.12 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) { store.open(session) } else { openChat() }
        }
        .onHover { hovering = $0 }
        .contextMenu { RowMenu(session: session, store: store, openChat: openChat) }
        .help("Show \(session.label) · ⌘-click opens \(session.host.label)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.label)
        .accessibilityAction(named: "Open the chat") { openChat() }
        .accessibilityAction(named: "Open in \(session.host.label)") { store.open(session) }
        .modifier(ApprovalAccessibility(session: session, store: store, active: approval != nil))
    }

    private func openChat() {
        withAnimation(.smooth(duration: 0.18)) { store.openPage(session.id) }
    }
}

/// Allow and Deny as VoiceOver actions on anything that shows a waiting prompt.
struct ApprovalAccessibility: ViewModifier {
    let session: Session
    let store: SessionStore
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content
                .accessibilityAction(named: "Allow") { store.respond(to: session.id, with: .allow) }
                .accessibilityAction(named: "Deny") { store.respond(to: session.id, with: .deny) }
        } else {
            content
        }
    }
}

/// A row's right-click menu.
struct RowMenu: View {
    let session: Session
    let store: SessionStore
    let openChat: () -> Void

    var body: some View {
        Button("Open Chat") { openChat() }
        Button("Open in \(session.host.label)") { store.open(session) }
        if session.host.canSend {
            Button("Reply") {
                openChat()
                store.focusReplyId = session.id
                NotificationCenter.default.post(name: .watchManNeedsKeyboard, object: nil)
            }
        }
        Divider()
        if let text = session.lastReply {
            Button("Copy Last Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        if let root = session.projectRoot {
            let muted = ProjectSettings.shared.isMuted(root)
            Button(muted ? "Unmute \(session.label)" : "Mute \(session.label)") {
                ProjectSettings.shared.update(root) { $0.muted = muted ? nil : true }
            }
        }
    }
}

/// A row's second line: the working step coloured like the chat's tool lines, "Thinking" with moving dots,
/// why it waits in amber, or the first sentence of its result.
struct RowDetail: View {
    let session: Session
    var size: CGFloat = 12

    var body: some View {
        if let approval = session.pendingApproval, session.status.isNeedsYou {
            HStack(spacing: 4) {
                Text(approval.kind == .command ? "Wants to run" : approval.kind == .other ? "Wants to use \(approval.tool)" : "Wants to edit")
                    .foregroundStyle(Theme.secondary)
                    .fixedSize()
                Text(approval.command ?? approval.fileName ?? approval.detail)
                    .font(.system(size: size, design: .monospaced))
                    .foregroundStyle(Theme.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: size))
        } else if session.rateLimited {
            Text("Usage limit reached" + (session.limitReset.map { " · resets \($0)" } ?? ""))
                .font(.system(size: size))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        } else if session.status == .working, let step = session.lastStep, step != "Thinking…" {
            let (verb, detail) = ChatStepsView.split(step)
            HStack(spacing: 4) {
                Text(verb)
                    .fontWeight(.semibold)
                    .foregroundStyle(ChatStepsView.color(for: verb))
                    .fixedSize()
                if let detail {
                    Text(detail).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            .font(.system(size: size))
        } else if session.status == .working {
            ThinkingText(size: size)
        } else {
            MarkdownText(text: session.rowPreview, lineLimit: 1)
                .font(.system(size: size))
                .foregroundStyle(session.isUnseenResult ? Theme.primary.opacity(0.85) : Theme.secondary)
                .truncationMode(.tail)
        }
    }
}

/// "Thinking" with three dots taking turns (still with Reduce Motion).
struct ThinkingText: View {
    var size: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text("Thinking").font(.system(size: size)).foregroundStyle(Theme.secondary)
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.secondary)
                    .frame(width: 2.5, height: 2.5)
                    .opacity(reduceMotion ? 0.8 : (on ? 1 : 0.2))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.5).repeatForever().delay(Double(index) * 0.18),
                               value: on)
            }
        }
        .onAppear { on = true }
    }
}

/// "May be stuck" warning with what to do about it.
struct StuckBanner: View {
    let session: Session
    let reason: StuckReason
    let store: SessionStore
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                Text("May be stuck · \(reason.text)").font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(Theme.needsYou)
            HStack(spacing: 6) {
                if Hosts.canInterrupt(session.host) {
                    PillButton(title: "Interrupt (Esc)", symbol: "stop.fill", tint: Theme.failed) {
                        Task { feedback = await Hosts.interrupt(session) ?? "Interrupted" }
                    }
                }
                PillButton(title: "Open", symbol: "arrow.up.right") { store.open(session) }
                PillButton(title: "Dismiss", symbol: "xmark") { store.dismissStuck(session.id) }
            }
            if let feedback { Text(feedback).font(.system(size: 10.5)).foregroundStyle(Theme.secondary) }
        }
        .padding(7)
        .background(Theme.needsYou.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Messages waiting to be typed in when the session finishes.
struct QueuedChips: View {
    let sessionId: String
    let queue: [String]
    let store: SessionStore

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(Theme.unseen)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(queue.enumerated()), id: \.offset) { index, message in
                        HStack(spacing: 4) {
                            Text(message).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                            Button { store.removeFollowUp(at: index, for: sessionId) } label: {
                                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .help("Remove from the queue")
                        }
                        .foregroundStyle(Theme.unseen)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.unseen.opacity(0.13), in: Capsule())
                    }
                }
            }
        }
        .help("Sent one by one, each time Claude finishes")
    }
}

/// Reply box. `compact` is the one-line version shown right on rows that need you.
struct ReplyField: View {
    let session: Session
    let store: SessionStore
    var compact = false
    /// The session page's composer: bigger text and a hint about sending while Claude works.
    var large = false
    @State private var feedback: String?
    @State private var busy = false
    @State private var dropTargeted = false
    @FocusState private var focused: Bool
    /// In the WatchMan window: focus requests come from ⌘R there, and typing never pulls in the notch panel.
    @Environment(\.inMainWindow) private var inMainWindow

    /// The half-typed reply lives in the store, so it survives the panel closing.
    private var draft: Binding<String> {
        Binding(get: { store.drafts[session.id] ?? "" }, set: { store.drafts[session.id] = $0.isEmpty ? nil : $0 })
    }
    private var text: String { store.drafts[session.id] ?? "" }
    /// While Claude works, Enter queues the message to be sent when it finishes.
    private var queueing: Bool { session.status == .working }
    private var placeholder: String {
        if session.pendingApproval?.isQuestion == true, store.hasPendingPrompt(session.id) { return "Or type your own answer…" }
        if session.pendingApproval?.isPlan == true, store.hasPendingPrompt(session.id) { return "What should change in the plan? (↩ keeps planning with it)" }
        if queueing { return large ? "Message for when \(session.displayName) finishes…" : "Queue a message for when it finishes…" }
        return compact ? "Reply…" : "Message \(session.displayName)… (paste or drop a screenshot or file)"
    }

    /// Adds dropped files (or a dropped image, saved first) to the reply as quoted paths Claude can open.
    private func attach(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let path = url?.path else { return }
                    Task { @MainActor in appendPath(path) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage, let tiff = image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("WatchMan/Drops", isDirectory: true)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let file = folder.appendingPathComponent("drop-\(Int(Date().timeIntervalSince1970)).png")
                    guard (try? png.write(to: file)) != nil else { return }
                    Task { @MainActor in appendPath(file.path) }
                }
            }
        }
    }

    private func appendPath(_ path: String) {
        let quoted = path.contains(" ") ? "\"\(path)\"" : path
        let current = text
        store.drafts[session.id] = current.isEmpty ? quoted + " " : current + (current.hasSuffix(" ") ? "" : " ") + quoted + " "
        focused = true
        feedback = "Attached \((path as NSString).lastPathComponent)"
    }

    func queue(_ message: String) {
        store.enqueueFollowUp(message, for: session.id)
        store.drafts[session.id] = nil
        feedback = "Queued: sent when \(session.displayName) finishes"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Enter sends, Shift+Enter starts a new line; drop files or screenshots to send their path
                TextField(placeholder, text: draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: large ? 13 : 12))
                    .lineLimit(1...(large ? 8 : 6))
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            store.drafts[session.id] = text + "\n"
                        } else if press.modifiers.contains(.command), queueing {
                            stopAndSend(text)
                        } else {
                            queueing ? queue(text) : send(text)
                        }
                        return .handled
                    }
                    .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
                        attach(providers)
                        return true
                    }
                    .padding(.horizontal, large ? 11 : 9)
                    .padding(.vertical, compact ? 4 : large ? 8 : 6)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.unseen, lineWidth: dropTargeted ? 1.5 : 0))
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                if !compact {
                    IconButton(symbol: "camera.viewfinder", help: "Attach a screenshot of a window: click the window (Esc cancels)") {
                        store.captureWindow(for: session.id)
                    }
                }
                if queueing {
                    IconButton(symbol: "clock", help: "Send when Claude finishes", tint: Theme.unseen) { queue(text) }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    IconButton(symbol: "arrow.up", help: "Send") { send(text) }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
                if busy { ProgressView().controlSize(.mini) }
            }
            if let feedback {
                Text(feedback).font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
            } else if large, queueing, Hosts.canInterrupt(session.host) {
                Text("↩ sends when it finishes  ·  ⌘↩ stops it and sends now")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.faint)
            }
        }
        .onChange(of: focused) { _, isFocused in
            guard !inMainWindow else { return }
            store.isEditing = isFocused
            if isFocused { NotificationCenter.default.post(name: .watchManNeedsKeyboard, object: nil) }
        }
        .onChange(of: focusRequest) { _, id in takeFocus(id) }
        .onAppear { takeFocus(focusRequest) }
    }

    private var focusRequest: String? { inMainWindow ? store.focusWindowReplyId : store.focusReplyId }

    private func takeFocus(_ id: String?) {
        guard id == session.id else { return }
        focused = true
        if inMainWindow { store.focusWindowReplyId = nil } else { store.focusReplyId = nil }
    }

    /// Esc, then the message: for when Claude is going the wrong way.
    func stopAndSend(_ message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            busy = true
            feedback = "Stopping Claude, then sending…"
            let error = await store.interruptAndSend(message, to: session.id)
            busy = false
            feedback = error ?? "Sent"
            if error == nil { store.drafts[session.id] = nil }
        }
    }

    func send(_ message: String) {
        Task {
            busy = true
            feedback = "Sending…"
            let error = await store.reply(message, to: session.id)
            busy = false
            feedback = error ?? "Sent"
            if error == nil { store.drafts[session.id] = nil }
        }
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.6), radius: pulsing ? 3 : 0)
            .opacity(pulsing && dim ? 0.4 : 1)
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) { dim = true }
            }
    }
}

struct VerificationBadges: View {
    let verification: Verification

    var body: some View {
        HStack(spacing: 3) {
            if let analyze = verification.analyze { badge("analyze", analyze.result) }
            if let test = verification.test { badge("test", test.result) }
        }
    }

    private func badge(_ name: String, _ result: Verification.Result) -> some View {
        let passed = result == .passed
        return Text("\(passed ? "✓" : "✗") \(name)")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(passed ? Theme.working : Theme.failed)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background((passed ? Theme.working : Theme.failed).opacity(0.12), in: Capsule())
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Theme.secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        // VoiceOver reads the short part of the tooltip ("Settings", "Pin", "Close")
        .accessibilityLabel(String(help.split(whereSeparator: { ":(".contains($0) }).first ?? Substring(help))
            .trimmingCharacters(in: .whitespaces))
    }
}

extension Notification.Name {
    static let watchManCollapse = Notification.Name("watchManCollapse")
}

/// A page reached from the header or "+ New": To-dos, earlier sessions, or the system. Back with ‹ or Esc.
struct SidePage: View {
    let page: SessionStore.OtherPage
    let store: SessionStore
    let height: CGFloat

    private var title: String {
        switch page {
        case .todos: "Start from a To-do"
        case .recent: "Resume an earlier session"
        case .system: "System"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The way back is in the notch row (or the panel's header row); here, just the page's name
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.primary)
                .padding(.horizontal, 4)
                .arrive(1)
            Group {
                switch page {
                case .todos: TodosView()
                case .recent: RecentView(store: store)
                case .system: ScrollView(.vertical, showsIndicators: true) { SystemView(store: store) }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(height: height)
    }
}


/// Files dropped on the notch: which session do they go to?
struct DropChooser: View {
    let store: SessionStore
    let maxHeight: CGFloat

    var body: some View {
        let files = store.pendingDrop
        let targets = store.ordered.filter(\.host.canSend)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(Theme.unseen)
                Text(files.count == 1 ? "Send \((files[0] as NSString).lastPathComponent) to…" : "Send \(files.count) files to…")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.primary).lineLimit(1)
                Spacer()
                Button("Cancel") { store.pendingDrop = [] }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 10)
            .arrive(1)
            if targets.isEmpty {
                Text("No session can take a reply from WatchMan right now.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(.horizontal, 10)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(targets) { session in
                        Button { withAnimation(.smooth(duration: 0.18)) { store.sendDrop(to: session.id) } } label: {
                            HStack(spacing: 11) {
                                ProjectTile(session: session)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.rowTitles(shared: store.sharedLabels.contains(session.label)).title)
                                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                                    RowDetail(session: session, size: 11.5)
                                }
                                Spacer(minLength: 8)
                                StatusChip(session: session)
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 46)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
            }
            .frame(maxHeight: min(maxHeight, CGFloat(targets.count) * 48 + 4))
            .arrive(2)
        }
    }
}

/// A row that lights up under the pointer and when pressed.
struct RowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.cardSelected : (hovering ? Theme.cardHover : Color.clear),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { hovering = $0 }
    }
}
