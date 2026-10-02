import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import WatchManCore

@main
struct WatchManPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    /// The link to the Mac through iCloud.
    @State private var store = PhoneStore(link: CloudLink())

    var body: some Scene {
        WindowGroup {
            TabView(selection: $store.tab) {
                Tab("Sessions", systemImage: "list.bullet.rectangle", value: 0) { SessionsScreen(store: store) }
                    .badge(store.waiting.count)
                Tab("Overview", systemImage: "square.grid.2x2", value: 1) { OverviewScreen(store: store) }
                Tab("Resume", systemImage: "clock.arrow.circlepath", value: 2) { ResumeScreen(store: store) }
                Tab("Settings", systemImage: "gearshape", value: 3) { SettingsScreen(store: store) }
            }
            // System opens from its row on the Overview
            // Scrolling puts the keyboard away (dragging down with it, as in Messages)
            .scrollDismissesKeyboard(.interactively)
            // A widget or the Live Activity opens its session (or just the app)
            .onOpenURL { url in
                guard let id = PhoneLinks.sessionId(in: url) else { return }
                store.tab = 0
                store.path = [id]
            }
            // A tapped alert opens its session
            .onReceive(NotificationCenter.default.publisher(for: .watchManPhoneOpen)) { note in
                guard let id = note.object as? String else { return }
                store.tab = 0
                store.path = [id]
                Task { await store.refresh() }
            }
            .tint(PhoneTheme.accent)
            .task { await store.refresh() }
            // Coming back to the app (iCloud's pushes refresh through the app delegate)
            .onChange(of: phase) { _, now in if now == .active { Task { await store.refresh() } } }
            // While it's open, a light refresh every 20 s in case a push was held back
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    if phase == .active { await store.refresh() }
                }
            }
        }
    }
}

// MARK: - Sessions

struct SessionsScreen: View {
    @Bindable var store: PhoneStore
    @State private var newSession = false

    var body: some View {
        NavigationStack(path: $store.path) {
            List {
                ForEach(store.grouped, id: \.state) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            NavigationLink(value: session.id) { SessionRow(session: session) }
                        }
                    } header: {
                        HStack {
                            Text(PhoneTheme.title(group.state))
                            Spacer()
                            Text("\(group.sessions.count)").foregroundStyle(PhoneTheme.color(group.state))
                        }
                    }
                }
                if store.state.sessions.isEmpty && !store.loading {
                    if let problem = store.problem {
                        // Not linked yet: say why, instead of an empty list
                        ContentUnavailableView {
                            Label("Not linked to your Mac yet", systemImage: "icloud.slash")
                        } description: {
                            Text(problem)
                        } actions: {
                            Link("Get WatchMan for Mac", destination: WatchManWeb.macDownload)
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ContentUnavailableView {
                            VStack(spacing: 12) {
                                FaceView(size: 64).accessibilityHidden(true)
                                Text("No Sessions")
                            }
                        } description: {
                            Text("Claude Code sessions on your Mac show up here.")
                        } actions: {
                            Button("New Session") { newSession = true }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) { MacReachBanner(store: store).padding(.horizontal) }
            .navigationTitle("Sessions")
            .navigationDestination(for: String.self) { id in SessionScreen(store: store, sessionId: id) }
            .refreshable { await store.refresh() }
            .toolbar {
                Button { newSession = true } label: { Label("New Session", systemImage: "plus") }
            }
            .sheet(isPresented: $newSession) { NewSessionSheet(store: store) }
        }
    }
}

struct SessionRow: View {
    let session: SessionSnapshot

    var body: some View {
        HStack(spacing: 12) {
            ProjectBadge(name: session.name, key: session.colorKey)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name).font(.headline)
                Text(session.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            StateChip(session: session)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StateChip: View {
    let session: SessionSnapshot
    /// The state in words too ("Working · 2 min"), where nothing else says it (the session page).
    var showsState = false

    var body: some View {
        let color = PhoneTheme.color(session.state)
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption2.weight(.bold))
            if showsState {
                Text(stateText).font(.caption.weight(.semibold))
            } else {
                Text(session.since, format: .relative(presentation: .numeric, unitsStyle: .narrow)).font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
    }

    /// "Working · 2 min", "Done · 5 min ago".
    private var stateText: String {
        let seconds = max(0, Date().timeIntervalSince(session.since))
        let span = seconds < 60 ? "just now" : seconds < 3600 ? "\(Int(seconds / 60)) min"
            : seconds < 86_400 ? "\(Int(seconds / 3600)) h" : "\(Int(seconds / 86_400)) d"
        let past = session.state == .done || session.state == .idle
        return PhoneTheme.title(session.state) + " · " + span + (past && seconds >= 60 ? " ago" : "")
    }

    private var symbol: String {
        switch session.state {
        case .needsYou: session.prompt?.kind == .question ? "questionmark.bubble.fill"
            : session.prompt?.kind == .plan ? "list.bullet.clipboard.fill" : "hand.raised.fill"
        case .working: "circle.fill"
        case .done: session.unseen ? "checkmark.circle.fill" : "checkmark"
        case .idle: "moon.fill"
        case .limited: "hourglass"
        case .failed: "xmark.octagon.fill"
        }
    }
}

// MARK: - A session

struct SessionScreen: View {
    let store: PhoneStore
    let sessionId: String
    @State private var draft = ""
    @State private var tab = Tab.chat
    /// The tabs opened so far: each keeps its own scroll place while another is on screen.
    @State private var opened: Set<Tab> = [.chat]
    /// The screen's height above the keyboard, which the pinned prompt card may take part of.
    @State private var screenHeight: CGFloat = 0
    /// Photos to send with the next reply, and the picker's choice.
    @State private var photos: [Data] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var sendNote: String?
    /// The clipboard holds an image to paste into the reply.
    @State private var clipboardHasImage = false

    enum Tab: String, CaseIterable { case chat = "Chat", steps = "Steps", changes = "Changes" }

    private var session: SessionSnapshot? { store.state.sessions.first { $0.id == sessionId } }
    private var chat: ChatSnapshot? { store.chats[sessionId] }

    var body: some View {
        // The state and the tabs stay at the top, the prompt and your words at the foot; only the tab between scrolls
        ZStack {
            if let session {
                ForEach(Tab.allCases, id: \.self) { page in
                    if opened.contains(page) {
                        content(page, session)
                            .opacity(tab == page ? 1 : 0)
                            .allowsHitTesting(tab == page)
                            .accessibilityHidden(tab != page)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable {
            await store.refresh()
            await store.loadChat(sessionId)
            if tab == .changes { await store.ask(.changes, session: sessionId) }
        }
        .topBar { if let session { header(session) } }
        .safeAreaInset(edge: .bottom, spacing: 0) { foot }
        .background {
            Color.clear.ignoresSafeArea(.container)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { screenHeight = $0 }
        }
        .onChange(of: tab) { _, now in opened.insert(now) }
        .navigationTitle(session?.name ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if let session { StopButton(store: store, session: session) } }
        .task {
            // Its alerts are read now
            await StaleAlerts.clear(sessionId)
            // Looking at a new result here counts as seeing it on the Mac too
            if session?.unseen == true { await store.send(.mac(.seen), to: sessionId) }
            // An older session's chat isn't shared until asked for
            await store.loadChatAsking(sessionId)
        }
    }

    /// The session's state and the tabs.
    private func header(_ session: SessionSnapshot) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                StateChip(session: session, showsState: true)
                if let context = session.contextPercent {
                    Text("Context \(Int(context))%").font(.caption.weight(.semibold))
                        .foregroundStyle(context >= 80 ? PhoneTheme.limit : .secondary)
                }
                Spacer()
                Text(session.host).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    /// A tab's own scroll. Each opens at the newest, at the end, and follows what comes while you're there.
    @ViewBuilder
    private func content(_ page: Tab, _ session: SessionSnapshot) -> some View {
        // Something new at the end: another item, more steps on the last one, or a message you just sent
        let end = chat.map { "\($0.items.count)-\($0.items.last?.text.count ?? 0)-\(store.pending[sessionId]?.count ?? 0)" }
        switch page {
        case .chat:
            NewestLastScroll(end: end) {
                EarlierMessagesButton(store: store, sessionId: sessionId)
                ChatList(chat: chat, waitingOnQuestion: session.prompt?.kind == .question)
                PendingReplies(store: store, sessionId: sessionId)
                SessionExtrasView(store: store, session: session)
            }
        case .steps:
            NewestLastScroll(end: end) { StepsList(chat: chat) }
        case .changes:
            let changes = store.extras?.changes.flatMap { $0.sessionId == sessionId ? $0 : nil }
            NewestLastScroll(end: changes.map { "\($0.files.count)-\($0.at.timeIntervalSince1970)-\(session.tasks?.count ?? 0)" }) {
                ChangesList(session: session)
                ProjectChangesSection(store: store, session: session)
            }
        }
    }

    /// What the session waits on, then your words.
    @ViewBuilder
    private var foot: some View {
        if let session, session.prompt != nil || session.canReply {
            VStack(spacing: 8) {
                if let prompt = session.prompt {
                    PinnedPrompt(store: store, session: session, prompt: prompt, limit: screenHeight * 0.45)
                }
                if session.canReply { replyBar }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// Your words: a reply, your own answer to a question, or what to change in a plan.
    private var replyBar: some View {
        VStack(alignment: .leading, spacing: 4) {
        PhotoStrip(photos: $photos)
        if let sendNote { Text(sendNote).font(.caption).foregroundStyle(PhoneTheme.failed) }
        HStack(spacing: 8) {
            // Photos go with a plain reply (not an answer to a question or a plan)
            if session?.prompt == nil {
                // An image you copied (a screenshot, a photo): the system's Paste button, so iOS doesn't ask first
                if clipboardHasImage {
                    PasteButton(supportedContentTypes: [.image]) { providers in
                        for provider in providers where provider.canLoadObject(ofClass: UIImage.self) {
                            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                                guard let image = object as? UIImage, let data = PhonePhotos.jpeg(image) else { return }
                                Task { @MainActor in if photos.count < 6 { photos.append(data) } }
                            }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Paste image")
                }
                PhotosPicker(selection: $picked, maxSelectionCount: 6, matching: .images) {
                    Image(systemName: "photo.on.rectangle").font(.title3)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Add photos")
                .onChange(of: picked) { _, items in
                    guard !items.isEmpty else { return }
                    Task {
                        for item in items { if let data = await PhonePhotos.jpeg(from: item) { photos.append(data) } }
                        picked = []
                    }
                }
            }
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Button {
                let text = draft
                draft = ""
                let attached = photos
                photos = []
                sendNote = nil
                Task {
                    if !attached.isEmpty, session?.prompt == nil {
                        let id = store.addPending(text, to: sessionId)
                        sendNote = await store.reply(text, photos: attached, to: sessionId)
                        if let sendNote { store.failPending(id, in: sessionId, because: sendNote) }
                    } else if session?.prompt?.kind == .plan {
                        await store.send(.deny(message: text), to: sessionId)
                    } else if session?.prompt?.kind == .question {
                        await store.send(.answer(QuestionAnswers(response: text)), to: sessionId)
                    } else {
                        await store.sendReply(text, to: sessionId)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty)
            .accessibilityLabel("Send")
        }
        }
        // Whether there's an image to paste, checked without reading the clipboard (so iOS doesn't ask)
        .onAppear { clipboardHasImage = UIPasteboard.general.hasImages }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            clipboardHasImage = UIPasteboard.general.hasImages
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            clipboardHasImage = UIPasteboard.general.hasImages
        }
    }

    private var placeholder: String {
        switch session?.prompt?.kind {
        case .question: "Or type your own answer"
        case .plan: "What should change in the plan?"
        default: session?.state == .working ? "Message for when it finishes" : "Message \(session?.name ?? "")"
        }
    }
}

/// A tab's own scroll that opens at its newest end and follows what arrives while you're there; scrolled back to
/// read, it stays where you are.
struct NewestLastScroll<Content: View>: View {
    /// Changes when something arrives at the end; nil until there's anything.
    let end: String?
    @ViewBuilder var content: Content
    @State private var atEnd = true
    @State private var position = ScrollPosition(edge: .bottom)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .scrollPosition($position)
        .scrollDismissesKeyboard(.interactively)
        // Opens at the newest, even when the page is pushed with the content already there
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // Within a short way of the end counts as there
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 60
        } action: { _, now in
            withAnimation(.smooth(duration: 0.2)) { atEnd = now }
        }
        // Scrolled back to read: one tap back to the newest
        .overlay(alignment: .bottomTrailing) {
            if !atEnd {
                Button { withAnimation { position.scrollTo(edge: .bottom) } } label: {
                    Image(systemName: "arrow.down")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color(.separator), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 12)
                .accessibilityLabel("Jump to the newest")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .onChange(of: end) { old, _ in
            if old == nil {
                // The first content arrived after the page opened
                position.scrollTo(edge: .bottom)
            } else if atEnd {
                withAnimation { position.scrollTo(edge: .bottom) }
            }
        }
    }
}

extension View {
    /// A bar under the navigation bar that the page scrolls under: part of the system's scroll edge on iOS 26,
    /// on the bar material before it.
    @ViewBuilder
    func topBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: .top, spacing: 0) { bar().background(.bar) }
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

/// The prompt card above the reply bar, compact. It scrolls inside only when even that can't fit `limit`
/// (very large text, or the keyboard up).
struct PinnedPrompt: View {
    let store: PhoneStore
    let session: SessionSnapshot
    let prompt: PromptSnapshot
    let limit: CGFloat
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            PromptCard(store: store, session: session, prompt: prompt, compact: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: limit > 0 ? min(height, limit) : height)
    }
}

/// The whole prompt (the plan, the diff, every question) with its buttons, opened from the pinned card.
struct PromptSheet: View {
    let store: PhoneStore
    let sessionId: String
    @Environment(\.dismiss) private var dismiss

    private var session: SessionSnapshot? { store.state.sessions.first { $0.id == sessionId } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let session, let prompt = session.prompt {
                    PromptCard(store: store, session: session, prompt: prompt).padding()
                }
            }
            .navigationTitle(session?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// The prompt the session waits on, answerable here.
struct PromptCard: View {
    let store: PhoneStore
    let session: SessionSnapshot
    let prompt: PromptSnapshot
    /// Pinned on the session page: the title, the start of the command and the buttons. The plan, the diff and a
    /// set of questions open in a sheet.
    var compact = false
    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            HStack(spacing: 6) {
                Label(heading, systemImage: symbol)
                if prompt.kind == .question, prompt.questions.count == 1, let header = prompt.questions.first?.header {
                    Text("· " + header)
                }
            }
            .font(.caption.weight(.bold)).foregroundStyle(PhoneTheme.needsYou)
            .textCase(.uppercase)
            // A question is read in full: it's what you answer
            Text(prompt.title).font(.headline)
                .lineLimit(compact && prompt.kind != .question ? 3 : nil)
                .fixedSize(horizontal: false, vertical: true)
            if let command = prompt.command {
                Text("$ " + command).font(.callout.monospaced()).lineLimit(compact ? 2 : nil).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.quaternarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            }
            if compact {
                if let more = moreLabel {
                    Button { showsAll = true } label: {
                        Label(more, systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .font(.subheadline.weight(.semibold))
                }
            } else {
                if !prompt.diff.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(prompt.diff.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced())
                                .foregroundStyle(line.hasPrefix("+") ? PhoneTheme.working : line.hasPrefix("−") ? PhoneTheme.failed : .secondary)
                        }
                    }
                }
                if let plan = prompt.plan {
                    Text(LocalizedStringKey(plan)).font(.callout)
                }
            }
            if prompt.risky {
                Label("This deletes, overwrites, runs as root or rewrites history.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(PhoneTheme.needsYou)
            }
            if compact, questionsInSheet {
                HStack {
                    Button("Answer \(prompt.questions.count) Questions") { showsAll = true }.buttonStyle(.borderedProminent)
                    Button("Skip") { Task { await store.send(.deny(message: nil), to: session.id) } }.buttonStyle(.bordered)
                }
                .controlSize(.large)
            } else {
                buttons.controlSize(.large)
            }
            if store.sent[session.id] != nil {
                Label("Sent to your Mac", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        // A tap you can feel once the answer is on its way
        .sensoryFeedback(.success, trigger: store.sent[session.id] != nil) { was, now in now && !was }
        .padding(.all, compact ? 14 : nil)
        .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
        .background(PhoneTheme.needsYou.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sheet(isPresented: $showsAll) { PromptSheet(store: store, sessionId: session.id) }
    }

    /// Several questions are answered in the sheet, where they all fit.
    private var questionsInSheet: Bool { prompt.kind == .question && prompt.questions.count > 1 }

    /// What the compact card leaves for the sheet, as its button's words.
    private var moreLabel: String? {
        if prompt.plan != nil { return "Read the Plan" }
        if !prompt.diff.isEmpty { return "See the Edit" }
        if let command = prompt.command, command.count > 80 || command.contains("\n") { return "See the Whole Command" }
        return nil
    }

    @ViewBuilder
    private var buttons: some View {
        switch prompt.kind {
        case .permission:
            HStack {
                Button("Allow") { Task { await store.send(.allow, to: session.id) } }.buttonStyle(.borderedProminent)
                Button("Deny") { Task { await store.send(.deny(message: nil), to: session.id) } }.buttonStyle(.bordered)
                // Saving a rule lasts, so it says which rule before you pick it
                Menu {
                    Section(alwaysNote) {
                        Button { Task { await store.send(.alwaysAllow, to: session.id) } } label: {
                            Label("Always Allow", systemImage: "checkmark.shield")
                        }
                    }
                } label: {
                    Text("Always…")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
            }
        case .question where prompt.questions.count > 1 || prompt.questions.contains(where: \.multiSelect):
            QuestionForm(store: store, session: session, prompt: prompt)
        case .question:
            ForEach(prompt.questions, id: \.question) { question in
                VStack(alignment: .leading, spacing: 8) {
                    if prompt.questions.count > 1 { Text(question.question).font(.subheadline.weight(.semibold)) }
                    ForEach(question.options, id: \.label) { option in
                        Button {
                            Task { await store.send(.answer(QuestionAnswers(answers: [question.question: option.label])), to: session.id) }
                        } label: {
                            ChoiceText(option: option, descriptionLines: compact ? 3 : nil)
                                .multilineTextAlignment(.leading)
                                .padding(.vertical, 2)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            Button("Skip") { Task { await store.send(.deny(message: nil), to: session.id) } }
                .font(.subheadline)
                .accessibilityHint("Tells Claude you'd rather not answer")
        case .plan:
            VStack(alignment: .leading) {
                HStack {
                    Button("Approve") { Task { await store.send(.allow, to: session.id) } }.buttonStyle(.borderedProminent)
                    Button("Accept Edits") { Task { await store.send(.alwaysAllow, to: session.id) } }.buttonStyle(.bordered)
                }
                Button("Keep Planning") { Task { await store.send(.deny(message: nil), to: session.id) } }.buttonStyle(.bordered)
            }
        }
    }

    /// What "Always" saves, e.g. "Won't ask again for Bash(flutter build:*)".
    private var alwaysNote: String {
        guard let rules = prompt.rules, !rules.isEmpty else { return "Won't ask again for this in the project" }
        return "Won't ask again for " + rules.joined(separator: ", ")
    }

    private var heading: String {
        switch prompt.kind {
        case .permission: "Permission"
        case .question: "Claude asks"
        case .plan: "Plan ready"
        }
    }

    private var symbol: String {
        switch prompt.kind {
        case .permission: "hand.raised.fill"
        case .question: "questionmark.bubble.fill"
        case .plan: "list.bullet.clipboard.fill"
        }
    }
}

/// The chat as the terminal shows it: your prompts, Claude's messages (markdown, code and tables drawn as on
/// the Mac), the steps between.
struct ChatList: View {
    let chat: ChatSnapshot?
    /// The session waits on a question: the last question card says so.
    var waitingOnQuestion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let chat, !chat.items.isEmpty {
                let lastQuestion = chat.items.lastIndex { $0.questions?.isEmpty == false }
                ForEach(Array(chat.items.enumerated()), id: \.offset) { index, item in
                    switch item.role {
                    case .you:
                        YourMessage(text: ChatText.cleanPrompt(item.text))
                    case .claude where item.questions?.isEmpty == false:
                        QuestionChatCard(questions: item.questions ?? [], answers: item.answers ?? [:], note: item.answerNote,
                                         waiting: waitingOnQuestion && index == lastQuestion)
                    case .claude:
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("●").font(.system(size: 9)).foregroundStyle(Palette.primary)
                            MarkdownBlocksView(blocks: MarkdownBlocks.parse(item.text))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    case .steps:
                        ChatStepsView(steps: StepsList.entries(item))
                    }
                }
            } else {
                Text("Nothing said yet.").foregroundStyle(.secondary)
            }
        }
    }
}

/// Your messages on their way to the Mac, at the end of the chat: sending, waiting for the Mac (asleep, or
/// iCloud is slow), or lost after ten minutes, with Send Again.
struct PendingReplies: View {
    let store: PhoneStore
    let sessionId: String

    var body: some View {
        if let replies = store.pending[sessionId], !replies.isEmpty {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(replies) { reply in
                        VStack(alignment: .leading, spacing: 6) {
                            YourMessage(text: reply.text).opacity(0.6)
                            status(reply, now: context.date)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func status(_ reply: PendingReply, now: Date) -> some View {
        let age = now.timeIntervalSince(reply.at)
        if reply.failure != nil || reply.lost {
            VStack(alignment: .leading, spacing: 6) {
                Label(reply.failure ?? "Not delivered: your Mac didn't pick it up", systemImage: "exclamationmark.circle")
                    .foregroundStyle(PhoneTheme.failed)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Button("Send Again") {
                        store.removePending(reply.id, from: sessionId)
                        Task { await store.sendReply(reply.text, to: sessionId) }
                    }
                    Button("Remove", role: .destructive) { store.removePending(reply.id, from: sessionId) }
                }
            }
            .font(.caption.weight(.medium))
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(age < 20 ? "Sending…" : "Waiting for your Mac to pick it up…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Your prompt in the chat. A long one (pasted text) shows its start, the rest a tap away.
struct YourMessage: View {
    let text: String
    @State private var open = false

    private var long: Bool { text.count > 600 || text.filter { $0 == "\n" }.count > 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.callout)
                .lineLimit(open || !long ? nil : 8)
                .textSelection(.enabled)
            if long {
                Button(open ? "Show Less" : "Show All") { withAnimation(.smooth(duration: 0.2)) { open.toggle() } }
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Every step of the recent turns, newest last, in the terminal's colours.
struct StepsList: View {
    let chat: ChatSnapshot?

    /// A steps item's lines as timeline entries for the shared steps view.
    static func entries(_ item: ChatSnapshot.Item) -> [TranscriptState.TimelineEntry] {
        item.text.split(separator: "\n").enumerated().map { index, line in
            TranscriptState.TimelineEntry(id: index, at: item.at, kind: .tool, text: String(line))
        }
    }

    var body: some View {
        let steps = (chat?.items ?? []).filter { $0.role == .steps }.flatMap(Self.entries)
        if steps.isEmpty {
            Text("No steps yet.").foregroundStyle(.secondary)
        } else {
            ChatStepsView(steps: Array(steps.enumerated().map { index, step in
                var step = step
                step.id = index
                return step
            }), showsAll: true)
        }
    }
}

/// What the last turn changed (files, tests, commits) and Claude's plan for the work.
struct ChangesList: View {
    let session: SessionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let tasks = session.tasks, !tasks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    let done = tasks.filter { $0.state == .done }.count
                    Text("Plan · \(done) of \(tasks.count) done").font(.headline)
                    ProgressView(value: Double(done), total: Double(tasks.count)).tint(Palette.working)
                    ForEach(Array(tasks.enumerated()), id: \.offset) { _, task in
                        Label {
                            Text(task.text).strikethrough(task.state == .done)
                                .foregroundStyle(task.state == .done ? .secondary : .primary)
                        } icon: {
                            Image(systemName: task.state == .done ? "checkmark.circle.fill" : task.state == .inProgress ? "circle.lefthalf.filled" : "circle")
                                .foregroundStyle(task.state == .done ? Palette.working : task.state == .inProgress ? Palette.unseen : .secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            if let turn = session.turn {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Last turn").font(.headline)
                    if let prompt = turn.prompt {
                        Text("“\(prompt)”").font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                    ForEach(turn.files, id: \.self) { file in
                        Label(file, systemImage: "doc.text").font(.callout.monospaced())
                    }
                    HStack(spacing: 10) {
                        if let passed = turn.testsPassed {
                            Label(passed ? "Tests passed" : "Tests failed", systemImage: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(passed ? Palette.working : Palette.failed)
                        }
                        if turn.commits > 0 {
                            Label("\(turn.commits) commit\(turn.commits == 1 ? "" : "s")", systemImage: "arrow.triangle.branch")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption.weight(.medium))
                }
            }
            if session.turn == nil && (session.tasks ?? []).isEmpty {
                Text("No changes in the last turn.").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Overview

struct OverviewScreen: View {
    let store: PhoneStore
    @State private var showsSystem = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        FaceView(mood: !store.waiting.isEmpty ? .needsYou
                                 : store.state.sessions.contains { $0.state == .working } ? .working : .calm, size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.waiting.isEmpty ? "All clear" : "\(store.waiting.count) \(store.waiting.count == 1 ? "needs" : "need") you").font(.title2.bold())
                            Text("\(store.state.sessions.filter { $0.state == .working }.count) working on \(store.state.macName)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let usage = store.state.usage {
                        HStack(spacing: 24) {
                            if let session = usage.session { ring("Session", session) }
                            if let week = usage.week { ring("Week", week) }
                        }
                        if let forecast = PhoneForecast.text(usage) {
                            Text(forecast.text).font(.footnote).foregroundStyle(forecast.warn ? PhoneTheme.limit : .secondary)
                        }
                    }
                    if let problem = store.problem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(PhoneTheme.failed)
                    }
                    if !store.waiting.isEmpty {
                        Text("Needs you").font(.headline)
                        ForEach(store.waiting) { session in
                            VStack(alignment: .leading, spacing: 8) {
                                SessionRow(session: session)
                                if let prompt = session.prompt { PromptCard(store: store, session: session, prompt: prompt) }
                            }
                        }
                    }
                    UnsavedSection(store: store)
                    systemRow
                }
                .padding()
            }
            .safeAreaInset(edge: .top) { MacReachBanner(store: store).padding(.horizontal) }
            .navigationTitle("Overview")
            .refreshable { await store.ask(.refresh(.unsaved)) }
            .sheet(isPresented: $showsSystem) { SystemScreen(store: store) }
        }
        .task { await store.ask(.refresh(.unsaved)) }
    }

    /// The Mac's memory in one line; the whole System page opens from it.
    private var systemRow: some View {
        Button { showsSystem = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "memorychip").font(.title3).foregroundStyle(.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System").font(.body.weight(.semibold))
                    if let system = store.extras?.system {
                        Text("\(system.usedGB, format: .number.precision(.fractionLength(1))) of \(Int(system.totalGB.rounded())) GB, pressure \(system.pressureLabel)")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Memory, leftovers and the Dev Log").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func ring(_ name: String, _ window: UsageWindow) -> some View {
        let color = window.percent >= 90 ? PhoneTheme.failed : window.percent >= 70 ? PhoneTheme.limit : PhoneTheme.working
        return HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color(.systemFill), lineWidth: 5)
                Circle().trim(from: 0, to: window.percent / 100).stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(window.percent))%").font(.caption.bold())
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading) {
                Text(name).font(.subheadline.weight(.semibold))
                if let resets = window.resetsAt {
                    Text("resets \(resets, format: .dateTime.weekday(.abbreviated).hour().minute())").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
