// Renders WatchMan's views with sample sessions to build/snapshots/*.png (off-screen, nothing is shown).
import AppKit
import ImageIO
import SwiftUI
import WatchManCore

@MainActor
func render<V: View>(_ view: V, size: CGSize, name: String, backdrop: Color = Color(white: 0.82)) {
    let content = ZStack(alignment: .top) {
        backdrop
        view
    }
    .frame(width: size.width, height: size.height)
    .environment(\.colorScheme, .dark)
    let hosting = NSHostingView(rootView: content)
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    // Long enough for the parts that arrive one after another to settle
    RunLoop.main.run(until: Date().addingTimeInterval(Double(ProcessInfo.processInfo.environment["SNAP_WAIT"] ?? "2.5") ?? 2.5))
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    // The first argument that isn't a --flag is the output folder
    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "build.noindex/snapshots")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
    print("wrote \(name).png")
}

@MainActor
func sampleStore() -> SessionStore {
    let now = Date()
    func session(_ id: String, _ title: String, _ host: HostKind, _ status: SessionStatus, ago: TimeInterval,
                 step: String? = nil, reply: String? = nil, seen: Bool = true, project: String? = nil) -> Session {
        var s = Session(id: id, cwd: "/Users/you", host: host, now: now)
        s.title = title
        s.status = status
        s.statusSince = now.addingTimeInterval(-ago)
        s.lastActivity = now.addingTimeInterval(-ago / 2)
        s.lastStep = step
        s.lastReply = reply
        s.seen = seen
        s.projectRoot = project
        return s
    }
    var lumen = session("k", "Lumen", .ghostty, .needsYou("Permission · Run · flutter build apk"), ago: 380,
                          project: "/Users/you/Developer/VSCode/lumen")
    lumen.pendingApproval = PendingApproval(tool: "Bash", detail: "Run · Build the release APK", requestedAt: now,
                                              description: "Build the release APK",
                                              command: "flutter build apk --release --split-per-abi",
                                              cwd: "/Users/you/Developer/VSCode/lumen", rules: ["Bash(flutter build:*)"],
                                              handBackAt: now.addingTimeInterval(72))
    var trailmap = session("m", "Trailmap", .ghostty, .working, ago: 190, step: "Edit · workout_screen.dart",
                         project: "/Users/you/Developer/VSCode/trail_map")
    trailmap.verification = Verification(analyze: .init(result: .passed, at: now), test: .init(result: .failed, at: now))
    trailmap.stuck = .repeatingFailure("Run · flutter build apk")
    trailmap.tasks = [ClaudeTask(id: "1", text: "Kit tokens", status: .done), ClaudeTask(id: "2", text: "Migrate coach screens", status: .done),
                    ClaudeTask(id: "3", text: "Workout screen", status: .inProgress), ClaudeTask(id: "4", text: "Run the tests", status: .pending),
                    ClaudeTask(id: "5", text: "Commit", status: .pending)]
    trailmap.subagents = [Subagent(id: "a1", type: "Explore", description: "Find old widgets", step: "Grep · OldCard"),
                        Subagent(id: "a2", type: "general-purpose", description: "Migrate client screens", step: "Edit · client_home.dart")]
    let store = SessionStore()
    store.replaceAll([
        lumen,
        session("a", "Harbor Web", .ghostty, .needsYou("Which icon set should I use: Lucide or Heroicons?"), ago: 95,
                project: "/Users/you/Developer/VSCode/harbor-web"),
        session("c", "Shipyard", .ghostty, .finished, ago: 60,
                reply: "Build **passed** on Shipyard. iOS `ipa` uploaded to TestFlight.\nAndroid `aab` ready, waiting for your review.",
                seen: false),
        trailmap,
        session("v", "Build approach clarification", .vscodeExtension, .working, ago: 40, step: "Read · project.yml"),
        session("o", "Obsidian access", .ghostty, .finished, ago: 1800,
                reply: (1...30).map { "Step \($0): checked the vault notes and fixed links." }.joined(separator: "\n")
                    + "\n\n**Done.** Want me to also update the weekly review?"),
        session("f", "PhotoBooth", .iterm, .idle, ago: 7200),
        // At Claude's usage limit: orange, with when it resets
        { var l = session("l", "Atlas onboarding", .ghostty, .needsYou("Usage limit reached"), ago: 300,
                          project: "/Users/you/Developer/VSCode/atlas-app")
          l.failed = true
          l.rateLimited = true
          l.limitReset = "9pm"
          return l }(),
        { var e = session("e", "Pulse", .ghostty, .needsYou("Stopped with an error"), ago: 40,
                          project: "/Users/you/Developer/VSCode/Pulse")
          e.failed = true
          e.errorText = "API Error: 529 Overloaded. Claude will retry on the next message."
          return e }(),
    ])
    if var obsidian = store.sessions["o"] {
        var turn = TurnSummary()
        turn.prompt = "check the vault links and fix the broken ones"
        turn.filesEdited = ["/v/a.md", "/v/b.md", "/v/c.md"]
        turn.testsPassed = true
        turn.commits = 1
        turn.tokens = 45_000
        obsidian.lastTurn = turn
        obsidian.lastReply = "Checked 30 notes.\n\nThree options for the weekly review:\n1. **Update it now** — recommended\n2. Wait until Sunday\n3. Skip this week\n\nWhich should I do?"
        store.replaceAll(Array(store.sessions.values.filter { $0.id != "o" }) + [obsidian])
    }
    store.previewPrompts = ["k"]
    store.followUps = ["v": ["run the tests", "/project-sync"]]
    return store
}

@MainActor
func run() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let store = sampleStore()
    let usageNow = Date()
    store.applyStatusLine(StatusLineInfo(sessionId: "k", contextPercent: 84, usage: PlanUsage(
        session: UsageWindow(percent: 23, resetsAt: Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: usageNow)),
        week: UsageWindow(percent: 74, resetsAt: usageNow.addingTimeInterval(3 * 86400)))))
    let model = NotchModel()
    model.notchWidth = 185
    model.notchHeight = 32

    /// Lays the island out the way NotchController.layout does, on a canvas whose centre is the notch.
    func place(_ store: SessionStore, canvas: CGFloat, left: CGFloat?, right: CGFloat, maxHeight: CGFloat = 900,
               rotation: Int = 0, leftChoice: AppSettings.LeftContent = .automatic) {
        model.ears = NotchEars.layout(store, leftSpace: left, rightSpace: right, rotation: rotation, left: leftChoice)
        model.mood = model.ears.mood
        model.barWidth = model.ears.left.width + model.notchWidth + model.ears.right.width + 2 * NotchModel.shoulder
        model.messageHeight = model.mode == .collapsed ? (store.toasts.first.map { $0.height + 8 } ?? 0) : 0
        let rect = model.islandRect(midX: canvas / 2, peekRows: TopSessionsView.height(for: store.ordered), maxHeight: maxHeight,
                                    ears: model.ears, barWidth: model.barWidth)
        model.panelWidth = canvas
        model.islandX = rect.left
        model.islandWidth = rect.right - rect.left
        model.islandHeight = rect.height
        model.barOffset = rect.barLeft - rect.left
        switch model.mode {
        case .collapsed where model.messageHeight > 0: (model.shapeShoulder, model.shapeRadius) = (9, 20)
        case .collapsed: (model.shapeShoulder, model.shapeRadius) = (NotchModel.shoulder, NotchModel.stripRadius)
        case .peek: (model.shapeShoulder, model.shapeRadius) = (8, 18)
        case .expanded: (model.shapeShoulder, model.shapeRadius) = (10, 24)
        }
    }

    /// Closed strip. Red lines mark where the app menus end (left) and where the first menu bar icon starts (right).
    func closed(_ name: String, _ store: SessionStore, left: CGFloat?, right: CGFloat, rotation: Int = 0,
                leftChoice: AppSettings.LeftContent = .automatic, hovered: Bool = false) {
        model.mode = .collapsed
        model.hovered = hovered
        let canvas: CGFloat = 900
        place(store, canvas: canvas, left: left, right: right, rotation: rotation, leftChoice: leftChoice)
        let notchLeft = canvas / 2 - model.notchWidth / 2
        let view = ZStack(alignment: .topLeading) {
            // The menu bar: the strip has to blend into it
            Color(white: 0.16).frame(height: 32)
            NotchView(model: model, store: store)
            if let left {
                Rectangle().fill(Color.red).frame(width: 2, height: 32).offset(x: notchLeft - NotchModel.shoulder - 10 - left - 2)
            }
            Rectangle().fill(Color.red).frame(width: 2, height: 32)
                .offset(x: notchLeft + model.notchWidth + right + NotchModel.shoulder + 4)
        }
        render(view, size: CGSize(width: canvas, height: 32 + 70 + NotchModel.toastTop + 62 + 46 + 2 * NotchModel.toastSpacing + 14), name: name)
        model.hovered = false
    }

    func storeWith(_ list: [Session]) -> SessionStore {
        let made = SessionStore()
        made.replaceAll(list)
        return made
    }
    let all = store.sessions
    func status(_ id: String, _ status: SessionStatus, since: TimeInterval, seen: Bool = true) -> Session {
        var s = all[id]!
        s.status = status
        s.statusSince = Date().addingTimeInterval(-since)
        s.seen = seen
        return s
    }
    let idle = storeWith([status("f", .idle, since: 7200), status("c", .finished, since: 3600)])
    let oneWorking = storeWith([all["m"]!, status("f", .idle, since: 7200)])
    let twoWorking = storeWith([all["m"]!, all["v"]!, status("f", .idle, since: 7200)])
    let needs = storeWith([all["k"]!, all["m"]!])
    let done = storeWith([status("c", .finished, since: 3, seen: false), all["m"]!])
    let sent = storeWith([all["m"]!, all["v"]!])
    sent.previewFeedback(.feedback("m", name: "Trailmap", verb: "Sent"))
    needs.previewAttention(.needsYou)

    closed("s1-idle", idle, left: 260, right: 120)
    closed("s2-working", oneWorking, left: 260, right: 120)
    closed("s3-several-a", twoWorking, left: 260, right: 120, rotation: 0)
    closed("s3-several-b", twoWorking, left: 260, right: 120, rotation: 1)
    closed("s4-needs-you", needs, left: 260, right: 120)
    closed("s5-done", done, left: 260, right: 120)
    closed("s6-sent", sent, left: 260, right: 120)
    closed("s7-everything", store, left: 260, right: 120)
    closed("s8-tight", store, left: 70, right: 46)
    store.previewTicker(.init(name: "Lumen", text: "needs you", status: .needsYou("x"), unseen: false))
    closed("s9-menu-bar-full", store, left: 0, right: 0)
    store.previewTicker(nil)
    closed("s10-no-accessibility", store, left: nil, right: 120)
    closed("s11-orb-only", store, left: 260, right: 120, leftChoice: .ring)
    closed("s12-hover", needs, left: 260, right: 120, hovered: true)
    // External display: no notch, a small pill in the middle of the menu bar
    model.notchWidth = 24
    closed("s13-external-display", store, left: 260, right: 120)
    model.notchWidth = 185

    // Hover: top 3 (canvas a bit wider than the island to show its shadow)
    model.mode = .peek
    place(store, canvas: 560, left: 120, right: 90)
    render(NotchView(model: model, store: store), size: CGSize(width: 560, height: model.islandHeight + 30), name: "3-hover-top3")

    // Opened from the right side: only what needs you and what's new
    model.mode = .expanded
    store.attentionOnly = true
    model.expandedContentHeight = 300
    place(store, canvas: 680, left: 120, right: 90)
    render(NotchView(model: model, store: store), size: CGSize(width: 680, height: model.islandHeight + 30), name: "4b-open-attention")
    store.attentionOnly = false

    // Opened list
    model.mode = .expanded
    model.expandedContentHeight = 540
    place(store, canvas: 680, left: 120, right: 90)
    render(NotchView(model: model, store: store), size: CGSize(width: 680, height: model.islandHeight + 30), name: "4-open-list")

    // A session's page, opened from the list (Claude asked a question: its options are buttons)
    store.pageId = "o"
    store.selectedId = "o"
    model.pinned = true
    model.expandedContentHeight = 540
    place(store, canvas: 680, left: 120, right: 90)
    render(NotchView(model: model, store: store), size: CGSize(width: 680, height: model.islandHeight + 30), name: "5-open-page")
    store.pageId = nil
    model.pinned = false

    // ⌥Space: going through what's waiting, on the one that waited longest
    store.startInbox()
    model.expandedContentHeight = 540
    place(store, canvas: 680, left: 120, right: 90)
    render(NotchView(model: model, store: store), size: CGSize(width: 680, height: model.islandHeight + 30), name: "5b-inbox")
    store.inbox = false
    store.pageId = nil
    store.allClear = true
    render(NotchView(model: model, store: store), size: CGSize(width: 680, height: 260), name: "5c-all-clear")
    store.allClear = false

    // Pages that used to be tabs
    store.otherPage = .system
    render(NotchView(model: model, store: store), size: CGSize(width: 680, height: model.islandHeight + 30), name: "5d-system-page")
    store.otherPage = nil

    // Pages up close: working (live steps), a permission prompt, and the Steps and Changes views
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var demo = Session(id: "d", cwd: repo.path, host: .ghostty, now: Date().addingTimeInterval(-420))
    demo.title = "WatchMan"
    demo.projectRoot = repo.path
    demo.status = .working
    demo.lastStep = "Edit · NotchView.swift"
    demo.previousStep = "Read · project.yml"
    demo.stepNumber = 6
    demo.transcriptPath = repo.appendingPathComponent("Tests/CoreTests/Fixtures/transcript.jsonl").path
    store.setSession(demo)
    let page = CGSize(width: 880, height: 560)
    render(SessionPageView(session: demo, store: store, height: 440).padding(14), size: page, name: "7-page-working",
           backdrop: .black)
    refreshPrompt()
    if let lumen = store.sessions["k"] {
        render(SessionPageView(session: lumen, store: store, height: 520).padding(14), size: page,
               name: "7b-page-permission", backdrop: .black)
    }
    // An edit waiting for permission: the file, +N −M and the diff
    var edit = Session(id: "e", cwd: "/Users/you/Developer/VSCode/trail_map", host: .vscodeTerminal, now: Date().addingTimeInterval(-90))
    edit.title = "Trailmap"
    edit.projectRoot = "/Users/you/Developer/VSCode/trail_map"
    edit.status = .needsYou("Permission · Edit · workout_screen.dart")
    edit.statusSince = Date().addingTimeInterval(-70)
    edit.pendingApproval = PendingApproval(
        tool: "Edit", detail: "Edit · workout_screen.dart", requestedAt: Date().addingTimeInterval(-70),
        filePath: "/Users/you/Developer/VSCode/trail_map/lib/screens/workout_screen.dart",
        cwd: "/Users/you/Developer/VSCode/trail_map",
        edits: [TextEdit(oldString: "  final int sets;\n  final int reps;\n  Widget build(BuildContext context) {\n    return Text('$sets x $reps');",
                         newString: "  final int sets;\n  final int reps;\n  final Duration rest;\n  Widget build(BuildContext context) {\n    return WorkoutCard(sets: sets, reps: reps, rest: rest);")],
        rules: ["Edit"], handBackAt: Date().addingTimeInterval(20))
    store.setSession(edit)
    store.previewPrompts.insert("e")
    render(SessionPageView(session: edit, store: store, height: 520).padding(14), size: page,
           name: "7f-page-edit", backdrop: .black)
    store.previewPrompts.remove("e")
    var markdown = demo
    markdown.status = .finished
    markdown.lastTurn = TurnSummary()
    markdown.lastTurn?.prompt = "what do you think about DynamicNotchKit?"
    markdown.transcriptPath = nil
    markdown.lastReply = """
    **The missing features: all doable except the iPhone one.**

    | # | Feature | Where the data comes from | Effort |
    |---|---|---|---|
    | 1 | Claude's to-do list on hover | Claude Code writes its to-do list into the transcript | Medium |
    | 2 | Subagent pills on hover | Each subagent starts as an Agent step with a description | Medium |
    | 4 | Red look on error | Claude Code already reports `StopFailure` | Small |

    **My suggestion:**
    - build 4 + 5 first (small, errors matter most)
    - then 1–3 together

    Say "build 1–5" or pick some.
    """
    render(SessionPageView(session: markdown, store: store, height: 440).padding(14), size: page, name: "7c-page-markdown",
           backdrop: .black)
    // Claude's questions in the chat: one waiting for you, one answered, and steps that wrap on the phone
    let release = AskedQuestion(question: "How should the repo go public? People can't download the release while it's private.",
                                header: "Public repo", options: [
                                    .init(label: "Fresh public repo (Recommended)", description: "Rename this one to WatchMan-dev and publish one clean commit."),
                                    .init(label: "Make this repo public", description: "Keeps the whole history, including old personal data."),
                                ])
    let questionCards = VStack(alignment: .leading, spacing: 14) {
        ChatStepsView(steps: [
            .init(id: 1, at: Date(), kind: .tool, text: "Run · Tick the release in PLAN.md and refresh the percentages"),
            .init(id: 2, at: Date(), kind: .tool, text: "Message · moussa-e1"),
            .init(id: 3, at: Date(), kind: .tool, text: "Ask · Public repo"),
        ])
        QuestionChatCard(questions: [release], answers: [:], note: nil, waiting: true)
        QuestionChatCard(questions: [release], answers: [release.question: "Fresh public repo (Recommended)"], note: nil)
    }
    render(questionCards.padding(16), size: CGSize(width: 390, height: 640), name: "7h-question-cards", backdrop: .black)
    if let pulse = store.sessions["e"] {
        render(SessionPageView(session: pulse, store: store, height: 440).padding(14), size: page, name: "7d-page-error",
               backdrop: .black)
    }
    if let trailmapPage = store.sessions["m"] {
        var working = trailmapPage
        working.transcriptPath = nil
        render(SessionPageView(session: working, store: store, height: 440).padding(14), size: page, name: "7e-page-plan",
               backdrop: .black)
    }
    render(SessionPageView(session: demo, store: store, height: 440, section: .steps).padding(14), size: page,
           name: "8-steps", backdrop: .black)
    render(SessionPageView(session: demo, store: store, height: 440, section: .changes).padding(14), size: page,
           name: "9-changes", backdrop: .black)

    // Messages below the notch: a permission prompt answered right there, and a finished result.
    // (The run takes a while: give the sample prompt a fresh hand-back time first.)
    func refreshPrompt() {
        guard var k = store.sessions["k"] else { return }
        k.pendingApproval?.handBackAt = Date().addingTimeInterval(72)
        store.setSession(k)
    }
    refreshPrompt()
    if let lumen = store.sessions["k"], let shipyard = store.sessions["c"] {
        store.showToast(.permission(approval: PendingApproval(tool: "Bash", detail: "Run · Build the release APK", requestedAt: Date(),
                                                              command: "flutter build apk --release --split-per-abi --obfuscate --split-debug-info=build/symbols")),
                        for: lumen, seconds: 60)
        store.showToast(.finished(text: SessionStore.resultLine(shipyard)), for: shipyard, seconds: 60)
        closed("2c-messages", store, left: 260, right: 120)
        for toast in store.toasts { store.dismissToast(toast.id) }
        // Back after a while; several finishing together share one message
        store.showToast(.away(finished: 3, waiting: 2, stuck: 1), id: SessionStore.awayId, seconds: 60)
        for id in ["c", "o", "m"] { if let s = store.sessions[id] { store.showToast(.finished(text: "done"), for: s, seconds: 60) } }
        closed("2e-away-and-bundled", store, left: 260, right: 120)
        for toast in store.toasts { store.dismissToast(toast.id) }
        // A risky command: Review instead of Allow
        refreshPrompt()
        store.showToast(.permission(approval: PendingApproval(tool: "Bash", detail: "Run · Publish the branch", requestedAt: Date(),
                                                              description: "Publish the branch", command: "git push --force origin main")),
                        for: lumen, seconds: 60)
        closed("2d-risky-command", store, left: 260, right: 120)
        for toast in store.toasts { store.dismissToast(toast.id) }
    }
    // Claude's own question (AskUserQuestion): its choices, not Allow / Deny
    if var ask = store.sessions["a"] {
        let question = AskedQuestion(question: "Which icon set should I use?", header: "Icons", options: [
            .init(label: "Lucide", description: "Clean outline icons, over 1,400, and only the ones you use ship."),
            .init(label: "Heroicons", description: "Tailwind's set: fewer icons, solid and outline."),
            .init(label: "Phosphor", description: "Six weights and a very large set."),
        ])
        ask.pendingApproval = PendingApproval(tool: "AskUserQuestion", detail: "AskUserQuestion", requestedAt: Date(),
                                              handBackAt: Date().addingTimeInterval(80), questions: [question])
        ask.status = .needsYou(question.question)
        store.setSession(ask)
        store.previewPrompts.insert("a")
        store.showToast(.permission(approval: ask.pendingApproval!), for: ask, seconds: 60)
        closed("2f-question", store, left: 260, right: 120)
        for toast in store.toasts { store.dismissToast(toast.id) }
        render(SessionPageView(session: ask, store: store, height: 520).padding(14), size: CGSize(width: 880, height: 560),
               name: "7g-page-question", backdrop: .black)
    }
    // Claude's plan, asking to leave plan mode: the plan, Approve, Approve with edits accepted, Keep Planning
    if var planned = store.sessions["m"] {
        let plan = """
        # Plan: Workout history screen

        1. Add a `WorkoutHistory` model and a Firestore query by week
        2. Build `HistoryScreen` with a weekly bar chart and a list
        3. Link it from the profile tab
        4. Widget tests for empty, loading and filled states

        Files: `lib/history/`, `lib/profile/profile_screen.dart`
        """
        planned.pendingApproval = PendingApproval(tool: "ExitPlanMode", detail: "ExitPlanMode", requestedAt: Date(),
                                                  handBackAt: Date().addingTimeInterval(240), plan: plan)
        planned.status = .needsYou("Plan ready · Workout history screen")
        store.setSession(planned)
        store.previewPrompts.insert("m")
        store.showToast(.permission(approval: planned.pendingApproval!), for: planned, seconds: 60)
        closed("2g-plan", store, left: 260, right: 120)
        for toast in store.toasts { store.dismissToast(toast.id) }
        render(SessionPageView(session: planned, store: store, height: 520).padding(14), size: CGSize(width: 880, height: 560),
               name: "7h-page-plan", backdrop: .black)
    }

    render(SettingsView(), size: SettingsView.size, name: "6-settings", backdrop: Color(white: 0.12))
    render(SettingsView(pane: .notch), size: SettingsView.size, name: "6b-settings-notch", backdrop: Color(white: 0.12))
    render(SettingsView(pane: .claudeCode), size: SettingsView.size, name: "6c-settings-permissions", backdrop: Color(white: 0.12))
    render(SettingsView(pane: .notifications), size: SettingsView.size, name: "6d-settings-alerts", backdrop: Color(white: 0.12))
    render(SettingsView(pane: .keyboard), size: SettingsView.size, name: "6e-settings-keyboard", backdrop: Color(white: 0.12))
    // The WatchMan window: the overview, a session waiting on a permission, and a working session's diff
    refreshPrompt()
    store.activity = sampleActivity(store)
    let windowModel = WindowModel()
    renderWindow(MainWindowView(store: store, model: windowModel), size: CGSize(width: 1120, height: 760), name: "10-window-overview")
    render(OverviewPage(store: store) { _ in }.background(Theme.window), size: CGSize(width: 900, height: 2000),
           name: "10d-window-overview-all", backdrop: Theme.window)
    render(WindowSidebar(store: store, model: windowModel).environment(\.inMainWindow, true), size: CGSize(width: 260, height: 760),
           name: "10s-window-sidebar", backdrop: Color(white: 0.13))
    windowModel.page = .session("k")
    renderWindow(MainWindowView(store: store, model: windowModel), size: CGSize(width: 1180, height: 760), name: "10b-window-session")
    windowModel.page = .session("a")
    renderWindow(MainWindowView(store: store, model: windowModel), size: CGSize(width: 1180, height: 760), name: "10c-window-question")
    // Files dropped on the notch: which session?
    store.pendingDrop = ["/Users/you/Desktop/Screenshot 2026-10-01 at 18.20.png"]
    render(DropChooser(store: store, maxHeight: 400).padding(14), size: CGSize(width: 600, height: 330), name: "6f-drop-chooser",
           backdrop: .black)
    store.pendingDrop = []
}

/// WatchMan's app icon: a dark macOS squircle holding WatchMan's ball, a glowing violet-to-blue orb whose two
/// white eyes glance up and to the right, the same character that lives beside the notch.
struct AppIconView: View {
    /// The iPhone's icon: the same art filling the whole square, opaque, without corners or a shadow (iOS rounds it).
    var iPhone = false

    private let violet = Color(red: 0.62, green: 0.42, blue: 1.0)
    private let indigo = Color(red: 0.42, green: 0.40, blue: 1.0)
    private let blue = Color(red: 0.25, green: 0.64, blue: 1.0)

    var body: some View {
        ZStack {
            if iPhone {
                background.frame(width: 1024, height: 1024)
                ball.scaleEffect(1024 / 824)
            } else {
                background
                    .frame(width: 824, height: 824)
                    .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 3))
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                ball
            }
        }
        .frame(width: 1024, height: 1024)
    }

    private var background: some View {
        LinearGradient(colors: [Color(red: 0.13, green: 0.13, blue: 0.18), Color(red: 0.04, green: 0.04, blue: 0.06)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// The ball's glow, the ball, and its eyes looking up at you
    private var ball: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [indigo.opacity(0.6), indigo.opacity(0)], center: .center, startRadius: 236, endRadius: 336))
                .frame(width: 672, height: 672)
                .offset(y: 10)
            Circle()
                .fill(LinearGradient(colors: [violet, indigo, blue], startPoint: UnitPoint(x: 0.15, y: 0.1),
                                     endPoint: UnitPoint(x: 0.85, y: 0.95)))
                .frame(width: 512, height: 512)
            HStack(spacing: 36) {
                Ellipse().fill(.white).frame(width: 72, height: 112)
                Ellipse().fill(.white).frame(width: 72, height: 112)
            }
            .offset(x: 30, y: -54)
        }
    }
}

struct EyeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.55))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.55))
        path.closeSubpath()
        return path
    }
}

/// Draws a Core Animation tree as it looks right now, mid-animation: each animated layer takes its live
/// (presentation) values while its animations are lifted off for the draw, then everything is put back.
/// (Drawing a layer tree directly shows only its resting values, and skips a scale that also stretches depth.)
@MainActor
func drawLive(_ layer: CALayer, in ctx: CGContext) {
    var restore: [() -> Void] = []
    func visit(_ l: CALayer) {
        if let p = l.presentation(), let keys = l.animationKeys(), !keys.isEmpty {
            let m = p.transform
            let flat = CGAffineTransform(a: m.m11, b: m.m12, c: m.m21, d: m.m22, tx: m.m41, ty: m.m42)
            let live = (flat, p.position, p.bounds, p.opacity, p.contents, p.shadowOpacity, p.shadowColor, p.backgroundColor)
            let shape = (p as? CAShapeLayer).map { ($0.path, $0.strokeEnd) }
            let saved = (l.transform, l.position, l.bounds, l.opacity, l.contents, l.shadowOpacity, l.shadowColor, l.backgroundColor)
            let savedShape = (l as? CAShapeLayer).map { ($0.path, $0.strokeEnd) }
            let animations = keys.compactMap { key in l.animation(forKey: key).map { (key, $0) } }
            l.removeAllAnimations()
            l.setAffineTransform(live.0)
            (l.position, l.bounds, l.opacity, l.contents) = (live.1, live.2, live.3, live.4)
            (l.shadowOpacity, l.shadowColor, l.backgroundColor) = (live.5, live.6, live.7)
            if let shapeLayer = l as? CAShapeLayer, let shape { (shapeLayer.path, shapeLayer.strokeEnd) = shape }
            restore.append {
                (l.transform, l.position, l.bounds, l.opacity, l.contents) = (saved.0, saved.1, saved.2, saved.3, saved.4)
                (l.shadowOpacity, l.shadowColor, l.backgroundColor) = (saved.5, saved.6, saved.7)
                if let shapeLayer = l as? CAShapeLayer, let savedShape { (shapeLayer.path, shapeLayer.strokeEnd) = savedShape }
                for (key, animation) in animations { l.add(animation, forKey: key) }
            }
        }
        l.sublayers?.forEach(visit)
        if let mask = l.mask { visit(mask) }
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    visit(layer)
    CATransaction.commit()
    layer.render(in: ctx)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    restore.reversed().forEach { $0() }
    CATransaction.commit()
}

/// A film of the alive notch made from the app's own views: the SwiftUI notch and messages, and the real
/// Core Animation ball and working line, their animations stepped frame by frame. What it shows is what runs.
@MainActor
func renderAliveFilm() {
    let base = Date()
    let duration = 19.0, fps = 15.0
    let size = CGSize(width: 640, height: 236)
    let scale: CGFloat = 2

    func session(_ id: String, _ title: String) -> Session {
        var s = Session(id: id, cwd: "/p/\(id)", host: .ghostty, now: base.addingTimeInterval(-60))
        s.title = title
        return s
    }
    var trailmap = session("m", "Trailmap")
    var lumen = session("k", "Lumen")
    var harbor = session("a", "Harbor Web")
    var shipyard = session("c", "Shipyard")
    lumen.pendingApproval = PendingApproval(tool: "Bash", detail: "Run · flutter build apk --release", requestedAt: base)
    harbor.lastReply = "I set up both.\n\nWhich icon set should I use?\n1. **Lucide**\n2. **Heroicons**"
    shipyard.lastReply = "Build **passed** on Shipyard. iOS `ipa` uploaded to TestFlight."
    let store = SessionStore()
    store.previewPrompts = ["k"]
    func put(_ sessions: Session...) { for s in sessions { store.setSession(s) } }
    put(trailmap, lumen, harbor, shipyard)

    struct Scene { var start: Double; var label: String; var apply: () -> Void }
    var ids: [String: UUID] = [:]
    func toast(_ kind: SessionStore.Toast.Kind, _ s: Session) {
        store.showToast(kind, for: s, seconds: 1000)
        ids[s.id] = store.toasts.last?.id
    }
    func dismiss(_ s: Session) { if let id = ids[s.id] { store.dismissToast(id) } }
    let at = { (t: Double) in base.addingTimeInterval(t) }
    let scenes: [Scene] = [
        Scene(start: 0, label: "Quiet · only the ball breathes") {},
        Scene(start: 2.5, label: "Working · the text shimmers, each new step slides in, the ball swirls") {
            trailmap.status = .working; trailmap.statusSince = at(2.5); trailmap.lastActivity = at(2.5); trailmap.lastStep = "Read · main.dart"
            put(trailmap)
            toast(.started(prompt: "fix the login bug"), trailmap)
        },
        Scene(start: 5.0, label: "Working · the text shimmers, each new step slides in, the ball swirls") { dismiss(trailmap) },
        Scene(start: 8.5, label: "Needs you · a message with Allow / Deny in it, the ball beats amber") {
            lumen.status = .needsYou("Permission · Run · flutter build apk"); lumen.statusSince = at(8.5); put(lumen)
            toast(.permission(approval: PendingApproval(tool: "Bash", detail: "Run · flutter build apk --release", requestedAt: base,
                                                        command: "flutter build apk --release")), lumen)
        },
        Scene(start: 10.2, label: "Several at once · the messages stack") {
            harbor.status = .needsYou("Which icon set should I use?"); harbor.statusSince = at(10.2); put(harbor)
            toast(.question(text: "Which icon set should I use?", answers: ClosingQuestion.find(in: harbor.lastReply!)?.answers ?? []), harbor)
        },
        Scene(start: 12.6, label: "Several at once · the messages stack") {
            dismiss(lumen); dismiss(harbor)
            for var s in [lumen, harbor, trailmap] { s.status = .idle; s.statusSince = at(12.6); s.lastActivity = at(12.6); put(s) }
            lumen.status = .idle; harbor.status = .idle; trailmap.status = .idle
        },
        Scene(start: 13, label: "Done · a message with the result, the ball smiles and throws confetti") {
            shipyard.status = .finished; shipyard.seen = false; shipyard.statusSince = at(13); shipyard.lastActivity = at(13)
            put(shipyard)
            toast(.finished(text: SessionStore.resultLine(shipyard)), shipyard)
        },
        Scene(start: 17.2, label: "Quiet again") {
            dismiss(shipyard); shipyard.seen = true; put(shipyard)
        },
    ]
    let steps: [(Double, String)] = [(4.6, "Edit · workout_screen.dart"), (6.6, "Run · flutter test")]

    let model = NotchModel()
    model.notchWidth = 185
    model.notchHeight = 32
    model.mode = .collapsed
    let orb = OrbView(frame: NSRect(origin: .zero, size: size))
    let text = ActivityTextView(frame: NSRect(origin: .zero, size: size))
    // In a window far off screen, so Core Animation keeps a live presentation of their animations
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSView(frame: NSRect(origin: .zero, size: size))
    window.contentView = host
    for view in [orb, text] as [NSView] {
        host.addSubview(view)
        view.layout()
        view.layer?.speed = 0
        view.layer?.timeOffset = 0
    }
    window.orderFrontRegardless()
    CATransaction.flush()
    var missing = 0

    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "build.noindex/snapshots")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let count = Int(duration * fps)
    guard let gif = CGImageDestinationCreateWithURL(out.appendingPathComponent("alive.gif") as CFURL,
                                                     "com.compuserve.gif" as CFString, count, nil) else { return }
    CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

    var applied = -1, stepApplied = -1
    for i in 0..<count {
        let t = Double(i) / fps
        // The real layers' clock is the film's clock
        for view in [orb, text] as [NSView] { view.layer?.timeOffset = t }
        let index = scenes.lastIndex { $0.start <= t }!
        while applied < index { applied += 1; scenes[applied].apply() }
        if let step = steps.lastIndex(where: { $0.0 <= t }), step > stepApplied, trailmap.status == .working {
            stepApplied = step
            trailmap.lastStep = steps[step].1
            put(trailmap)
        }

        let ears = NotchEars.layout(store, leftSpace: 210, rightSpace: 80, now: at(t))
        model.ears = ears
        model.mood = ears.mood
        model.barWidth = ears.left.width + model.notchWidth + ears.right.width + 2 * NotchModel.shoulder
        let rect = model.islandRect(midX: size.width / 2, peekRows: TopSessionsView.height(for: store.ordered), maxHeight: 900,
                                    ears: ears, barWidth: model.barWidth)
        model.panelWidth = size.width
        model.islandX = rect.left
        model.islandWidth = rect.right - rect.left
        model.islandHeight = rect.height
        model.barOffset = rect.barLeft - rect.left
        let living = NotchController.livingPlacement(ears: ears, barLeft: rect.barLeft, notchWidth: model.notchWidth,
                                                     notchHeight: model.notchHeight, expanded: false)
        orb.update(mood: ears.mood, center: living.orb, hovered: false)
        text.update(text: living.text, origin: living.textOrigin, width: living.textWidth)
        orb.alphaValue = 1
        text.alphaValue = living.text == nil ? 0 : 1
        CATransaction.flush()

        let swiftUI = ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.11), Color(red: 0.11, green: 0.07, blue: 0.16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Color(white: 0.17).opacity(0.9).frame(height: model.notchHeight)
            HStack(spacing: 14) {
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text("Wed 15:20")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .position(x: 572, y: model.notchHeight / 2)
            NotchView(model: model, store: store)
            Text(scenes[index].label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size.width)
                .position(x: size.width / 2, y: 196)
            Text("Rendered from WatchMan's own views and animations · real size, 2×")
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.5))
                .position(x: size.width / 2, y: 218)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: swiftUI)
        renderer.scale = scale
        guard let flat = renderer.cgImage,
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
        ctx.draw(flat, in: CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        ctx.scaleBy(x: scale, y: scale)
        for view in [orb, text] as [NSView] where view.alphaValue > 0 {
            guard let layer = view.layer else { continue }
            if layer.presentation() == nil { missing += 1 }
            drawLive(layer, in: ctx)
        }
        guard let image = ctx.makeImage() else { continue }
        CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
    }
    CGImageDestinationFinalize(gif)
    window.orderOut(nil)
    print("wrote alive.gif", missing > 0 ? "(\(missing) frames without live animation state)" : "")
}

/// A sheet of the ball's reactions, one row each, at a few moments after it starts. Writes reactions.png.
@MainActor
func renderReactions() {
    let reactions: [(OrbReaction, NotchMood)] = [(.started, .working), (.stuck, .working), (.error, .quiet), (.limit, .quiet),
                                                (.usage(0.8), .quiet), (.back, .quiet)]
    let moments: [Double] = [0.1, 0.3, 0.6, 1.0, 1.6]
    let cell = CGSize(width: 90, height: 64), zoom: CGFloat = 5
    let size = CGSize(width: cell.width * CGFloat(moments.count), height: cell.height * CGFloat(reactions.count))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSView(frame: NSRect(origin: .zero, size: cell))
    window.contentView = host
    window.orderFrontRegardless()
    guard let ctx = CGContext(data: nil, width: Int(size.width * zoom), height: Int(size.height * zoom), bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: size.width * zoom, height: size.height * zoom))
    for (row, (reaction, mood)) in reactions.enumerated() {
        for (column, t) in moments.enumerated() {
            let orb = OrbView(frame: NSRect(origin: .zero, size: cell))
            host.addSubview(orb)
            orb.layout()
            orb.layer?.speed = 0
            orb.layer?.timeOffset = 0.001
            orb.update(mood: mood, center: CGPoint(x: cell.width / 2, y: cell.height / 2), hovered: false)
            orb.alphaValue = 1
            orb.layer?.removeAllAnimations()
            // Long after the mood settled, then the reaction
            orb.layer?.timeOffset = 20
            orb.react(reaction)
            orb.layer?.timeOffset = 20 + t
            CATransaction.flush()
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(column) * cell.width * zoom, y: CGFloat(reactions.count - 1 - row) * cell.height * zoom)
            ctx.scaleBy(x: zoom, y: zoom)
            if let layer = orb.layer { drawLive(layer, in: ctx) }
            ctx.restoreGState()
            orb.removeFromSuperview()
        }
    }
    window.orderOut(nil)
    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "build.noindex/snapshots")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    guard let image = ctx.makeImage() else { return }
    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("reactions.png"))
    print("wrote reactions.png")
}

/// A sheet of the orb's faces, one per mood, big enough to judge: a still after the eyes open, then the
/// moment each one moves (a blink, a glance, the hop and its confetti, the drifting z). Writes faces.png.
@MainActor
func renderFaces() {
    let moods: [NotchMood] = [.quiet, .working, .needsYou, .done, .worried, .asleep]
    let moments: [NotchMood: Double] = [.quiet: 2.53, .working: 3.23, .needsYou: 1.3, .done: 0.3, .worried: 0.12, .asleep: 1.4]
    let cell = CGSize(width: 150, height: 64), zoom: CGFloat = 6
    let size = CGSize(width: cell.width * CGFloat(moods.count), height: cell.height * 2)
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSView(frame: NSRect(origin: .zero, size: cell))
    window.contentView = host
    window.orderFrontRegardless()
    guard let ctx = CGContext(data: nil, width: Int(size.width * zoom), height: Int(size.height * zoom), bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: size.width * zoom, height: size.height * zoom))
    for (column, mood) in moods.enumerated() {
        for (row, t) in [0.6, moments[mood] ?? 1].enumerated() {
            let orb = OrbView(frame: NSRect(origin: .zero, size: cell))
            host.addSubview(orb)
            orb.layout()
            orb.layer?.speed = 0
            // Not 0: an animation that begins at 0 would be moved to whenever it's committed
            orb.layer?.timeOffset = 0.001
            orb.update(mood: mood, center: CGPoint(x: 40, y: cell.height / 2), hovered: false)
            orb.alphaValue = 1
            // No fade-in on the sheet: only the orb's own animations
            orb.layer?.removeAllAnimations()
            orb.layer?.timeOffset = t
            CATransaction.flush()
            ctx.saveGState()
            // Row 0 on top: Core Graphics counts up from the bottom
            ctx.translateBy(x: CGFloat(column) * cell.width * zoom, y: CGFloat(1 - row) * cell.height * zoom)
            ctx.scaleBy(x: zoom, y: zoom)
            if let layer = orb.layer { drawLive(layer, in: ctx) }
            ctx.restoreGState()
            orb.removeFromSuperview()
        }
    }
    window.orderOut(nil)
    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "build.noindex/snapshots")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    guard let image = ctx.makeImage() else { return }
    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("faces.png"))
    print("wrote faces.png")
}

/// A close-up film of the orb's face in every mood (three across, two down), its real animations stepped frame
/// by frame, for judging the character as it moves. Writes faces.gif.
@MainActor
func renderFacesFilm() {
    let moods: [(NotchMood, String)] = [(.quiet, "Quiet"), (.working, "Working"), (.needsYou, "Needs you"),
                                        (.done, "Done"), (.worried, "Can't hear Claude"), (.asleep, "Asleep")]
    // --frames: every frame as a PNG at 60 fps (for a smooth video) instead of a 15 fps GIF
    let frames = CommandLine.arguments.contains("--frames")
    let cell = CGSize(width: 100, height: 72), zoom: CGFloat = frames ? 4 : 6, fps = frames ? 60.0 : 15.0, duration = 15.0
    let size = CGSize(width: cell.width * 3, height: cell.height * 2)
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: cell.width, height: cell.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSView(frame: NSRect(origin: .zero, size: cell))
    window.contentView = host
    window.orderFrontRegardless()
    let orbs = moods.map { mood, _ in
        let orb = OrbView(frame: NSRect(origin: .zero, size: cell))
        host.addSubview(orb)
        orb.layout()
        orb.layer?.speed = 0
        // Not 0: an animation that begins at 0 would be moved to whenever it's committed
        orb.layer?.timeOffset = 0.001
        orb.update(mood: mood, center: CGPoint(x: cell.width / 2, y: cell.height / 2 + 6), hovered: false)
        orb.alphaValue = 1
        // No fade-in: only the orb's own animations
        orb.layer?.removeAllAnimations()
        return orb
    }
    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "build.noindex/snapshots")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let count = Int(duration * fps)
    guard let gif = CGImageDestinationCreateWithURL(out.appendingPathComponent("faces.gif") as CFURL,
                                                     "com.compuserve.gif" as CFString, count, nil) else { return }
    CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .medium),
                                                .foregroundColor: NSColor(white: 1, alpha: 0.6)]
    for i in 0..<count {
        for orb in orbs { orb.layer?.timeOffset = 0.001 + Double(i) / fps }
        CATransaction.flush()
        guard let ctx = CGContext(data: nil, width: Int(size.width * zoom), height: Int(size.height * zoom), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * zoom, height: size.height * zoom))
        ctx.scaleBy(x: zoom, y: zoom)
        for (index, orb) in orbs.enumerated() {
            ctx.saveGState()
            // First row on top: Core Graphics counts up from the bottom
            ctx.translateBy(x: CGFloat(index % 3) * cell.width, y: CGFloat(1 - index / 3) * cell.height)
            if let layer = orb.layer { drawLive(layer, in: ctx) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let name = moods[index].1 as NSString
            name.draw(at: CGPoint(x: (cell.width - name.size(withAttributes: label).width) / 2, y: 8), withAttributes: label)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }
        guard let image = ctx.makeImage() else { continue }
        if frames {
            let folder = out.appendingPathComponent("frames")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent(String(format: "%04d.png", i)))
            continue
        }
        CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
    }
    CGImageDestinationFinalize(gif)
    window.orderOut(nil)
    print("wrote faces.gif")
}

if let index = CommandLine.arguments.firstIndex(of: "--page"), index + 1 < CommandLine.arguments.count {
    // A real session's page from its transcript, at the size the open island gives it (880 × 700)
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let path = CommandLine.arguments[index + 1]
        var session = Session(id: "real", cwd: NSHomeDirectory(), host: .ghostty, now: Date())
        session.title = "Real session"
        session.status = .finished
        session.transcriptPath = path
        let store = SessionStore()
        store.replaceAll([session])
        let page = SessionPageView(session: session, store: store, height: 700).padding(14)
        render(page, size: CGSize(width: 880, height: 728), name: "page-real", backdrop: .black)
    }
} else if CommandLine.arguments.contains("--settings") {
    // Every Settings pane, for reviewing the window
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        render(ShortcutsSheet(), size: CGSize(width: 520, height: 540), name: "settings-shortcuts-sheet", backdrop: Color(white: 0.12))
        for pane in SettingsView.Pane.sidebar {
            render(SettingsView(pane: pane), size: SettingsView.size, name: "settings-" + pane.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"),
                   backdrop: Color(white: 0.12))
        }
    }
} else if CommandLine.arguments.contains("--faces-film") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        renderFacesFilm()
    }
} else if CommandLine.arguments.contains("--faces") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        renderFaces()
    }
} else if CommandLine.arguments.contains("--alive") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        renderAliveFilm()
    }
} else if CommandLine.arguments.contains("--reactions") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        renderReactions()
    }
} else if CommandLine.arguments.contains("--icon") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        render(AppIconView(), size: CGSize(width: 1024, height: 1024), name: "app-icon", backdrop: .clear)
        render(AppIconView(iPhone: true), size: CGSize(width: 1024, height: 1024), name: "app-icon-ios", backdrop: .black)
    }
} else if CommandLine.arguments.contains("--phone-glance") {
    // The iPhone's widgets and Live Activity with the sample sessions, at the iPhone's sizes (points, 2x)
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        renderPhoneGlance()
    }
} else if CommandLine.arguments.contains("--phone-test") {
    // Round trip through ntfy on throwaway topics: valid button press acts once; replayed and forged ones are ignored
    MainActor.assumeIsolated {
        Task { @MainActor in
            let settings = AppSettings.shared
            settings.ntfyTopic = "watchman-selftest-" + String(PhoneCodes.randomCode().prefix(10))
            settings.ntfyReplyTopic = ""
            settings.phoneActionsEnabled = true
            let store = SessionStore()
            var session = Session(id: "selftest", cwd: "/tmp", host: .ghostty, now: Date())
            session.title = "Self-test"
            session.status = .finished
            store.replaceAll([session])
            PhoneBridge.shared.store = store
            PhoneBridge.shared.start()
            let buttons = PhoneBridge.shared.buttons(for: session)
            let body = buttons.first?["body"] as? String ?? ""
            print("buttons:", buttons.map { $0["label"] as? String ?? "?" }, "reply topic:", PhoneBridge.shared.replyTopic)
            try? await Task.sleep(for: .seconds(3))
            let replyURL = URL(string: "https://ntfy.sh/\(PhoneBridge.shared.replyTopic)")!
            func post(_ text: String) async {
                var request = URLRequest(url: replyURL)
                request.httpMethod = "POST"
                request.httpBody = Data(text.utf8)
                _ = try? await URLSession.shared.data(for: request)
            }
            await post(body)                                   // valid
            try? await Task.sleep(for: .seconds(1))
            await post(body)                                   // replayed
            await post("continue:selftest:" + PhoneCodes.randomCode())   // forged
            try? await Task.sleep(for: .seconds(4))
            let poll = URL(string: "https://ntfy.sh/\(settings.ntfyTopic)/json?poll=1&since=60s")!
            var data = Data()
            if let result = try? await URLSession.shared.data(from: poll) { data = result.0 }
            let confirmations = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["message"] as? String
            }
            print("confirmations on phone topic:", confirmations)
            exit(confirmations.count == 1 ? 0 : 1)
        }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(60))
} else if CommandLine.arguments.contains("--todos") {
    // Renders the To-dos tab from the real project notes
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await ObsidianIndex.shared.reload()
            render(TodosView().padding(14), size: CGSize(width: 580, height: 520), name: "10-todos", backdrop: .black)
            render(TodosView(scope: .students).padding(14), size: CGSize(width: 580, height: 520), name: "11-todos-students",
                   backdrop: .black)
            exit(0)
        }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(60))
} else if CommandLine.arguments.contains("--digest-dry") {
    // Prints today's Dev Log without Haiku and without writing it
    MainActor.assumeIsolated {
        Task { @MainActor in
            print(await DigestWriter.buildToday(summarize: false).markdown)
            exit(0)
        }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(120))
} else if CommandLine.arguments.contains("--discover") {
    // Prints what session discovery finds on this Mac
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        for found in await SessionDiscovery.scan().sorted(by: { ($0.entry.updatedAt ?? .distantPast) > ($1.entry.updatedAt ?? .distantPast) }) {
            let e = found.entry
            print("\(e.pid)\t\(found.host.label)\t\(found.tty ?? "-")\t\(e.status ?? "?")\t\(found.transcriptPath == nil ? "no transcript" : "transcript ok")\t\(e.name ?? (e.cwd as NSString).lastPathComponent)")
        }
        semaphore.signal()
    }
    semaphore.wait()
} else {
    MainActor.assumeIsolated { run() }
}

/// The WatchMan window as macOS draws it: a titled window (toolbar, system sidebar, inspector) far off screen,
/// captured with its frame.
@MainActor
func renderWindow<V: View>(_ view: V, size: CGSize, name: String) {
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.toolbarStyle = .unified
    window.appearance = NSAppearance(named: .darkAqua)
    let hosting = NSHostingController(rootView: view.environment(\.inMainWindow, true))
    hosting.sceneBridgingOptions = [.toolbars, .title]
    window.contentViewController = hosting
    window.setContentSize(size)
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(Double(ProcessInfo.processInfo.environment["SNAP_WAIT"] ?? "2.5") ?? 2.5))
    guard let frame = window.contentView?.superview, let layer = frame.layer else { return }
    // The layer tree, not cacheDisplay: the sidebar's list and the toolbar only exist as layers
    let scale = window.backingScaleFactor
    guard let ctx = CGContext(data: nil, width: Int(frame.bounds.width * scale), height: Int(frame.bounds.height * scale),
                              bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: frame.bounds.width * scale, height: frame.bounds.height * scale))
    ctx.scaleBy(x: scale, y: scale)
    layer.render(in: ctx)
    guard let image = ctx.makeImage() else { return }
    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "build.noindex/snapshots")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
    window.orderOut(nil)
    print("wrote \(name).png")
}

/// A day of events for the window's timeline.
@MainActor
func sampleActivity(_ store: SessionStore) -> ActivityLog {
    let now = Date()
    var log = ActivityLog()
    func add(_ id: String, _ kind: ActivityEntry.Kind, _ text: String, _ minutes: Double) {
        guard let session = store.sessions[id] else { return }
        log.add(ActivityEntry(at: now.addingTimeInterval(-minutes * 60), sessionId: id, name: session.label,
                              colorKey: session.colorKey, kind: kind, text: text))
    }
    add("a", .started, "Set up the icons for the dashboard", 40)
    add("w", .started, "Fix the overlap in the notch", 25)
    add("l", .limited, "Usage limit · resets 9pm", 18)
    add("k", .started, "Build the release APK", 12)
    add("c", .finished, "Build **passed** on Shipyard.", 9)
    add("k", .asked, "Build the release APK", 8)
    add("a", .asked, "Which icon set should I use: Lucide or Heroicons?", 3)
    add("m", .asked, "Edit workout_screen.dart", 1)
    return log
}

/// The iPhone's widgets and Live Activity, each on a wallpaper-like backdrop, to review their design.
@MainActor
func renderPhoneGlance() {
    let now = Date()
    let glance = Glance.sample(now: now)
    let wallpaper = LinearGradient(colors: [Color(red: 0.17, green: 0.13, blue: 0.30), Color(red: 0.06, green: 0.06, blue: 0.12)],
                                   startPoint: .top, endPoint: .bottom)
    func widget<V: View>(_ view: V, _ size: CGSize) -> some View {
        view.padding(16)
            .frame(width: size.width, height: size.height)
            .background(WidgetBackdrop())
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
    func scaled<V: View>(_ view: V, _ size: CGSize, _ name: String) {
        let big = CGSize(width: size.width * 2, height: size.height * 2)
        render(ZStack { wallpaper; view }.scaleEffect(2).frame(width: big.width, height: big.height), size: big, name: name, backdrop: .black)
    }
    scaled(widget(SmallGlanceView(glance: glance, now: now), CGSize(width: 170, height: 170)), CGSize(width: 210, height: 210), "phone-widget-small")
    scaled(widget(MediumGlanceView(glance: glance, now: now), CGSize(width: 364, height: 170)), CGSize(width: 400, height: 210), "phone-widget-medium")
    scaled(widget(LargeGlanceView(glance: glance, now: now), CGSize(width: 364, height: 382)), CGSize(width: 400, height: 420), "phone-widget-large")
    scaled(widget(LargeGlanceView(glance: glance, now: now), CGSize(width: 364, height: 260)), CGSize(width: 400, height: 300), "phone-widget-large-tight")
    var calm = glance
    calm.sessions = calm.sessions.filter { !$0.waiting }
    scaled(widget(SmallGlanceView(glance: calm, now: now), CGSize(width: 170, height: 170)), CGSize(width: 210, height: 210), "phone-widget-small-clear")

    func lock(_ state: LiveGlance) -> some View {
        ActivityLockView(state: state)
            .frame(width: 370)
            .background(Color(red: 0.07, green: 0.07, blue: 0.11).opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
    func island(_ state: LiveGlance) -> some View {
        IslandExpandedView(state: state)
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 16, trailing: 18))
            .frame(width: 370)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
    }
    let permission = LiveGlance(glance)
    var question = glance
    question.sessions.removeAll { $0.id == "k" }
    var working = glance
    working.sessions = working.sessions.filter { !$0.waiting }
    var sent = LiveGlance(glance)
    sent.sentFor = "k"
    sent.sentPrompt = sent.focus?.prompt?.key
    var allDone = glance
    allDone.sessions = allDone.sessions.filter { $0.state == .done }
    var limited = working
    limited.sessions[0].state = .limited
    limited.sessions[0].resets = now.addingTimeInterval(5000)
    var failed = working
    failed.sessions[0].state = .failed
    failed.sessions[0].detail = "Build failed"
    let states: [(String, LiveGlance)] = [("permission", permission), ("question", LiveGlance(question)),
                                          ("working", LiveGlance(working)), ("sent", sent),
                                          ("done", LiveGlance(allDone, quietSince: now)),
                                          ("limited", LiveGlance(limited)), ("failed", LiveGlance(failed))]
    for (name, state) in states {
        scaled(lock(state).padding(20), CGSize(width: 410, height: 210), "phone-activity-\(name)")
        scaled(island(state).padding(20), CGSize(width: 410, height: 210), "phone-island-\(name)")
    }
    // Every look of the ball
    let moods: [FaceMood] = [.calm, .working, .needsYou, .happy, .worried, .sleepy, .asleep, .wink, .surprised]
    let faces = HStack(spacing: 18) {
        ForEach(moods, id: \.self) { mood in
            VStack(spacing: 6) {
                FaceView(mood: mood, size: 56)
                Text(mood.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    scaled(faces.padding(20), CGSize(width: 740, height: 120), "phone-faces")
    // The closed island: the face, and the count or a tick
    for (name, state) in [("waiting", permission), ("clear", LiveGlance(working)), ("question", LiveGlance(question)),
                          ("failed", LiveGlance(failed)), ("done", LiveGlance(allDone))] {
        let pill = HStack {
            IslandLeading(state: state)
            Spacer()
            IslandTrailing(state: state)
        }
        .padding(.horizontal, 12)
        .frame(width: 250, height: 37)
        .background(Color.black, in: Capsule())
        scaled(pill.padding(20), CGSize(width: 290, height: 77), "phone-island-compact-\(name)")
    }
}
