import AppKit
import Observation
import SwiftUI
import WatchManCore

/// What the window shows.
enum WindowPage: Hashable {
    case overview, todos, recent, system
    case session(String)
}

/// The window's own state: separate from the notch panel's, so the two never move each other.
@MainActor @Observable
final class WindowModel {
    var page: WindowPage = .overview
    var search = ""
    var showInspector = true
    var showIdle = false
    var columns: NavigationSplitViewVisibility = .all
    /// Bumped by Find (⌘F) to put the keyboard in the sidebar's search field.
    var searchRequest = 0
}

/// WatchMan as a normal Mac app: a window with every session in a sidebar, a page for each, and an overview.
/// The Dock icon shows while the window is open (or always, or never: Settings → General).
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let store: SessionStore
    private let model = WindowModel()
    private var window: NSWindow?
    private var pasteMonitor: Any?
    var openSettings: (SettingsView.Pane?) -> Void = { _ in }

    init(store: SessionStore) {
        self.store = store
        super.init()
        trackDockBadge()
    }

    /// Opens the window (on a session's page when given) and brings WatchMan to the front.
    func show(session id: String? = nil) {
        // Fresh state from Claude Code's own registry (Remote Control, names, sessions started elsewhere)
        store.discover()
        if let id, store.sessions[id] != nil {
            model.page = .session(id)
            store.markSeen(id)
        }
        if window == nil { makeWindow() }
        applyDockPolicy(windowOpen: true)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 500)
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("WatchManMainWindow")
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingController(rootView: MainWindowView(store: store, model: model).environment(\.inMainWindow, true))
        // The SwiftUI toolbar, title and search field become the window's own
        hosting.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = hosting
        if window.frame.origin == .zero { window.center() }
        self.window = window
        installMenu()
        watchPaste()
    }

    func windowWillClose(_ notification: Notification) {
        applyDockPolicy(windowOpen: false)
    }

    /// The Dock icon: while the window is open (default), always, or never.
    func applyDockPolicy(windowOpen: Bool? = nil) {
        let open = windowOpen ?? (window?.isVisible ?? false)
        let policy: NSApplication.ActivationPolicy = switch AppSettings.shared.dockIcon {
        case .always: .regular
        case .never: .accessory
        case .whileOpen: open ? .regular : .accessory
        }
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if policy == .regular { installMenu() }
        }
    }

    // MARK: Paste

    /// ⌘V in the reply box with a copied picture or files attaches them (text pastes as usual).
    private func watchPaste() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let isPaste = event.charactersIgnoringModifiers == "v"
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            let number = event.windowNumber
            guard isPaste else { return event }
            let handled = MainActor.assumeIsolated { self.pasteAttachments(windowNumber: number) }
            return handled ? nil : event
        }
    }

    private func pasteAttachments(windowNumber: Int) -> Bool {
        guard let window, window.windowNumber == windowNumber, let session = selectedSession,
              let editor = window.firstResponder as? NSTextView,
              // Not the sidebar's search field
              !(editor.delegate is NSSearchField) else { return false }
        return store.pasteAttachments(into: session.id)
    }

    // MARK: Dock

    /// The Dock icon's badge: how many sessions wait on you. Follows the store, no polling.
    private func trackDockBadge() {
        let count = withObservationTracking { store.waitingCount } onChange: { [weak self] in
            Task { @MainActor in self?.trackDockBadge() }
        }
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    /// The Dock icon's menu: the sessions that wait or have a new result, and the window.
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        let worth = store.ordered.filter { $0.status.isNeedsYou || $0.isUnseenResult || $0.failed || $0.rateLimited }
        for session in worth.prefix(8) {
            let state = session.status.isNeedsYou ? "needs you" : session.rateLimited ? "usage limit"
                : session.failed ? "stopped" : "new result"
            let item = NSMenuItem(title: "\(session.label) — \(state)", action: #selector(openFromDock(_:)), keyEquivalent: "")
            item.representedObject = session.id
            item.target = self
            menu.addItem(item)
        }
        if !worth.isEmpty { menu.addItem(.separator()) }
        let open = NSMenuItem(title: "Open the WatchMan Window", action: #selector(openFromDock(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        return menu
    }

    @objc private func openFromDock(_ sender: NSMenuItem) { show(session: sender.representedObject as? String) }

    // MARK: Menus

    private var selectedSession: Session? {
        if case .session(let id) = model.page { return store.sessions[id] }
        return nil
    }

    /// The window's session commands only act while the window is in front.
    private var windowSession: Session? { window?.isKeyWindow == true ? selectedSession : nil }

    /// Every command in the window is also in the menu bar, with its key.
    private func installMenu() {
        let main = NSMenu()

        let appMenu = NSMenu(title: "WatchMan")
        appMenu.addItem(withTitle: "About WatchMan", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(item("Check for Updates…", #selector(checkUpdates), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(settingsAction), ","))
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide WatchMan", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit WatchMan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, to: main)

        let file = NSMenu(title: "File")
        let newSession = NSMenu(title: "New Session")
        newSession.delegate = self
        file.addItem(withTitle: "New Session", action: nil, keyEquivalent: "").submenu = newSession
        file.addItem(item("Start from a To-do…", #selector(showTodos), ""))
        file.addItem(item("Resume an Earlier Session…", #selector(showRecent), ""))
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(item("Search Sessions…", #selector(findAction), "f"))
        edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "").submenu = find
        add(edit, to: main)

        let view = NSMenu(title: "View")
        view.addItem(item("Hide Sidebar", #selector(toggleSidebar), "s", [.control, .command]))
        view.addItem(item("Hide Details", #selector(toggleInspector), "0", [.option, .command]))
        view.addItem(.separator())
        for (index, page) in [("Overview", WindowPage.overview), ("To-dos", .todos), ("Resume", .recent), ("System", .system)].enumerated() {
            let entry = item(page.0, #selector(showPage(_:)), "\(index + 1)", [.option, .command])
            entry.tag = index
            view.addItem(entry)
        }
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.control, .command]
        add(view, to: main)

        let session = NSMenu(title: "Session")
        session.addItem(item("Allow", #selector(allowAction), "\r"))
        session.addItem(item("Deny", #selector(denyAction), "\u{8}"))
        session.addItem(.separator())
        for index in 0..<4 {
            let answer = item("Answer \(index + 1)", #selector(answerAction(_:)), "\(index + 1)")
            answer.tag = index
            session.addItem(answer)
        }
        session.addItem(item("Reply", #selector(replyAction), "r"))
        session.addItem(.separator())
        session.addItem(item("Open in Terminal", #selector(openAction), "o"))
        session.addItem(item("Open in the Claude App", #selector(openRemoteAction), ""))
        session.addItem(item("Copy the Remote Control Link", #selector(copyRemoteAction), ""))
        session.addItem(item("Copy Last Message", #selector(copyMessageAction), ""))
        session.addItem(.separator())
        session.addItem(item("Next Session", #selector(nextSession), String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
                             [.option, .command]))
        session.addItem(item("Previous Session", #selector(previousSession), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)),
                             [.option, .command]))
        session.addItem(.separator())
        session.addItem(item("Stop Claude", #selector(stopAction), "."))
        add(session, to: main)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(windowMenu, to: main)
        NSApp.windowsMenu = windowMenu

        let help = NSMenu(title: "Help")
        help.addItem(item("Keyboard Shortcuts", #selector(shortcutsHelp), ""))
        help.addItem(item("WatchMan on GitHub", #selector(githubHelp), ""))
        add(help, to: main)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    private func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    private func add(_ menu: NSMenu, to main: NSMenu) {
        let holder = NSMenuItem()
        holder.submenu = menu
        main.addItem(holder)
    }

    /// Titles follow the state (Show or Hide Sidebar, the answers' own words), and commands that can't act are off.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let session = windowSession
        switch item.action {
        case #selector(toggleSidebar):
            item.title = model.columns == .detailOnly ? "Show Sidebar" : "Hide Sidebar"
            return window?.isVisible == true
        case #selector(toggleInspector):
            item.title = model.showInspector ? "Hide Details" : "Show Details"
            return selectedSession != nil
        case #selector(allowAction):
            item.title = session?.pendingApproval?.isPlan == true ? "Approve the Plan" : "Allow"
            return session.map { store.hasPendingPrompt($0.id) && $0.asksPermission } ?? false
        case #selector(denyAction):
            item.title = session?.pendingApproval?.isQuestion == true ? "Skip the Question"
                : session?.pendingApproval?.isPlan == true ? "Keep Planning" : "Deny"
            return session.map { store.hasPendingPrompt($0.id) } ?? false
        case #selector(answerAction(_:)):
            let chips = session.map { store.answerChips(for: $0) } ?? []
            guard chips.indices.contains(item.tag) else {
                item.title = "Answer \(item.tag + 1)"
                return false
            }
            item.title = "Answer: \(chips[item.tag].label)"
            return true
        case #selector(replyAction):
            return session.map { $0.host.canSend && !store.hasPendingPrompt($0.id) } ?? false
        case #selector(openAction):
            item.title = session.map { "Open in \($0.host.label)" } ?? "Open in Terminal"
            return session != nil
        case #selector(openRemoteAction), #selector(copyRemoteAction):
            return session?.remoteURL != nil
        case #selector(copyMessageAction):
            return session?.lastReply != nil
        case #selector(stopAction):
            return session.map { $0.status == .working && Hosts.canInterrupt($0.host) } ?? false
        case #selector(nextSession), #selector(previousSession):
            return window?.isKeyWindow == true && !sessionOrder.isEmpty
        case #selector(findAction), #selector(showPage(_:)):
            return window?.isVisible == true
        default:
            return true
        }
    }

    /// File → New Session: the projects to start Claude in, built when the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "New Session" else { return }
        menu.removeAllItems()
        for group in NewSessionButton.groups {
            let groupMenu = NSMenu(title: group.name)
            for folder in group.folders {
                let entry = NSMenuItem(title: (folder as NSString).lastPathComponent, action: #selector(startSession(_:)), keyEquivalent: "")
                entry.representedObject = folder
                entry.target = self
                groupMenu.addItem(entry)
            }
            menu.addItem(withTitle: group.name, action: nil, keyEquivalent: "").submenu = groupMenu
        }
        if !NewSessionButton.groups.isEmpty { menu.addItem(.separator()) }
        let home = NSMenuItem(title: "Start Claude in Home Folder", action: #selector(startSession(_:)), keyEquivalent: "")
        home.representedObject = FileManager.default.homeDirectoryForCurrentUser.path
        home.target = self
        menu.addItem(home)
    }

    /// The sessions in the sidebar's order, for Next and Previous Session.
    private var sessionOrder: [String] {
        let parts = store.split()
        return SessionSection.group(parts.active).flatMap { $0.sessions.map(\.id) } + (model.showIdle ? parts.dormant.map(\.id) : [])
    }

    private func step(_ by: Int) {
        let order = sessionOrder
        guard !order.isEmpty else { return }
        let current = selectedSession.flatMap { order.firstIndex(of: $0.id) }
        let next = current.map { (($0 + by) % order.count + order.count) % order.count } ?? (by > 0 ? 0 : order.count - 1)
        model.page = .session(order[next])
        store.markSeen(order[next])
    }

    @objc private func settingsAction() { openSettings(nil) }
    /// Opens the download page when there's a newer version; otherwise says so in Settings → General.
    @objc private func checkUpdates() {
        Task {
            await UpdateCheck.shared.check()
            if UpdateCheck.shared.available != nil { UpdateCheck.shared.openDownload() } else { openSettings(.general) }
        }
    }
    @objc private func shortcutsHelp() { openSettings(.keyboard) }
    @objc private func githubHelp() {
        if let url = URL(string: "https://github.com/A7mdMosa/WatchMan") { NSWorkspace.shared.open(url) }
    }
    @objc private func showTodos() { show(); model.page = .todos }
    @objc private func showRecent() { show(); model.page = .recent }
    @objc private func startSession(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? String else { return }
        NewSessionButton.start(in: folder, with: "")
    }
    @objc private func findAction() {
        if model.columns == .detailOnly { model.columns = .all }
        model.searchRequest += 1
    }
    @objc private func toggleSidebar() { model.columns = model.columns == .detailOnly ? .all : .detailOnly }
    @objc private func toggleInspector() { model.showInspector.toggle() }
    @objc private func showPage(_ sender: NSMenuItem) {
        model.page = [WindowPage.overview, .todos, .recent, .system][max(0, min(3, sender.tag))]
    }
    @objc private func allowAction() { if let session = windowSession { store.respond(to: session.id, with: .allow) } }
    @objc private func denyAction() { if let session = windowSession { store.respond(to: session.id, with: .deny) } }
    @objc private func answerAction(_ sender: NSMenuItem) { if let session = windowSession { store.sendAnswer(sender.tag, for: session.id) } }
    @objc private func replyAction() { if let session = windowSession { store.focusWindowReplyId = session.id } }
    @objc private func openAction() { if let session = windowSession { store.open(session) } }
    @objc private func openRemoteAction() { if let url = windowSession?.remoteURL { NSWorkspace.shared.open(url) } }
    @objc private func copyRemoteAction() {
        guard let url = windowSession?.remoteURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        store.pageNote = "Copied"
    }
    @objc private func copyMessageAction() {
        guard let text = windowSession?.lastReply else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store.pageNote = "Copied"
    }
    @objc private func nextSession() { step(1) }
    @objc private func previousSession() { step(-1) }
    @objc private func stopAction() {
        guard let session = windowSession else { return }
        Task { store.pageNote = await Hosts.interrupt(session) ?? "Stopped" }
    }
}

extension Notification.Name {
    /// Opens the WatchMan window (the object, when there is one, is a session id to show).
    static let watchManOpenWindow = Notification.Name("watchManOpenWindow")
}

extension Theme {
    /// The window's content background: a touch lighter than the notch's black.
    static let window = Color(red: 0.075, green: 0.078, blue: 0.09)
}

// MARK: - The window's content

struct MainWindowView: View {
    let store: SessionStore
    @Bindable var model: WindowModel
    @FocusState private var searchFocused: Bool

    private var selectedSession: Session? {
        if case .session(let id) = model.page { return store.sessions[id] }
        return nil
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $model.columns) {
            WindowSidebar(store: store, model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            detail
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search Sessions")
        .searchFocused($searchFocused)
        .onChange(of: model.searchRequest) { _, _ in searchFocused = true }
        .environment(\.colorScheme, .dark)
        // A session that ends leaves the window on the overview
        .onChange(of: selectedSession == nil) { _, gone in
            if gone, case .session = model.page { model.page = .overview }
        }
    }

    private var detail: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.window)
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .inspector(isPresented: inspectorShown) {
                Group {
                    if let session = selectedSession { SessionInspector(session: session, store: store) }
                }
                .inspectorColumnWidth(min: 220, ideal: 270, max: 360)
            }
    }

    private var inspectorShown: Binding<Bool> {
        Binding(get: { model.showInspector && selectedSession != nil },
                set: { if selectedSession != nil { model.showInspector = $0 } })
    }

    // MARK: Title and toolbar

    private var title: String {
        switch model.page {
        case .overview: "Overview"
        case .todos: "To-dos"
        case .recent: "Resume"
        case .system: "System"
        case .session: selectedSession?.label ?? "Session"
        }
    }

    /// Under the title: the session's task (or where it runs), or what the page is for.
    private var subtitle: String {
        switch model.page {
        case .overview: ""
        case .todos: "Start Claude on one"
        case .recent: "Earlier sessions to pick up again"
        case .system: "Memory, leftover processes and usage"
        case .session: selectedSession.map { $0.task ?? $0.host.label } ?? ""
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let session = selectedSession {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.open(session) } label: {
                    Label { Text("Open in \(session.host.label)") } icon: { HostIcon(host: session.host, size: 16) }
                }
                .help("Open in \(session.host.label) (⌘O)")
                Menu {
                    SessionMoreMenuItems(session: session, store: store)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                NewSessionMenuItems(store: store) { page in model.page = page == .todos ? .todos : .recent }
            } label: {
                Label("New Session", systemImage: "plus")
            }
            .help("Start a Claude session")
        }
        if selectedSession != nil {
            ToolbarItem(placement: .primaryAction) {
                Button { model.showInspector.toggle() } label: {
                    Label(model.showInspector ? "Hide Details" : "Show Details", systemImage: "sidebar.trailing")
                }
                .help(model.showInspector ? "Hide details (⌥⌘0)" : "Show details (⌥⌘0)")
            }
        }
    }

    // MARK: Pages

    @ViewBuilder
    private var content: some View {
        switch model.page {
        case .overview:
            OverviewPage(store: store) { id in select(id) }
        case .todos:
            ScrollView { TodosView().padding(20) }
        case .recent:
            ScrollView { RecentView(store: store).padding(20) }
        case .system:
            ScrollView { SystemView(store: store).padding(20) }
        case .session:
            if let session = selectedSession {
                GeometryReader { geo in
                    SessionPageView(session: session, store: store, height: max(300, geo.size.height - 40), inWindow: true)
                        .id(session.id)
                        .padding(20)
                }
            }
        }
    }

    private func select(_ id: String) {
        model.page = .session(id)
        store.markSeen(id)
    }
}

// MARK: - Sidebar

/// The pages first, then every session grouped by what it needs, the idle ones folded away. A system sidebar
/// list: arrow keys move through it, and the selection takes the accent colour.
struct WindowSidebar: View {
    let store: SessionStore
    @Bindable var model: WindowModel

    private func matches(_ session: Session) -> Bool {
        let query = model.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return [session.label, session.task ?? "", session.lastStep ?? ""].contains { $0.lowercased().contains(query) }
    }

    private var selection: Binding<WindowPage?> {
        Binding(get: { model.page }, set: { page in
            guard let page else { return }
            model.page = page
            if case .session(let id) = page { store.markSeen(id) }
        })
    }

    var body: some View {
        let parts = store.split()
        let active = parts.active.filter(matches)
        let dormant = parts.dormant.filter(matches)
        List(selection: selection) {
            Section {
                Label("Overview", systemImage: "square.grid.2x2").tag(WindowPage.overview)
                Label("To-dos", systemImage: "checklist").tag(WindowPage.todos)
                Label("Resume", systemImage: "clock.arrow.circlepath").tag(WindowPage.recent)
                Label("System", systemImage: "gauge.with.dots.needle.33percent").tag(WindowPage.system)
            }
            ForEach(SessionSection.group(active), id: \.kind) { group in
                Section {
                    ForEach(group.sessions) { session in row(session) }
                } header: {
                    header(group.kind.title, group.sessions.count, group.kind.color)
                }
            }
            if !dormant.isEmpty {
                Section(isExpanded: $model.showIdle) {
                    ForEach(dormant) { session in row(session) }
                } header: {
                    header("Idle for over an hour", dormant.count, Theme.faint)
                }
            }
            if active.isEmpty && dormant.isEmpty {
                Text(model.search.isEmpty ? "No Claude sessions yet." : "No session matches.")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
    }

    private func header(_ title: String, _ count: Int, _ color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)").monospacedDigit().foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ session: Session) -> some View {
        HStack(spacing: 8) {
            ProjectTile(session: session, size: 20)
            Text(session.rowTitles(shared: store.sharedLabels.contains(session.label)).title)
                .fontWeight(session.isUnseenResult ? .semibold : nil)
                .lineLimit(1)
            if session.remoteSessionId != nil {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.web)
                    .help("Remote Control is on")
                    .accessibilityLabel("Remote Control on")
            }
            Spacer(minLength: 4)
            StatusChip(session: session)
        }
        .tag(WindowPage.session(session.id))
        .contextMenu { RowMenu(session: session, store: store, openChat: { model.page = .session(session.id) }) }
    }
}

// MARK: - Overview

/// The window's home: the face and one line on how things stand, every session that needs you with its answers
/// right there, then what happened today, event by event.
struct OverviewPage: View {
    let store: SessionStore
    let select: (String) -> Void
    @State private var usage: UsageSummary?
    @State private var memory = MemoryStatus.current()
    @State private var showAll = false
    @State private var projects: [(name: String, tokens: Int)] = []

    private var waiting: [Session] { store.ordered.filter { SessionSection.Kind($0) == .needsYou } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if !waiting.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        label("Needs you")
                        ForEach(waiting) { session in
                            WaitingCard(session: session, store: store) { select(session.id) }
                        }
                    }
                    .arrive(1)
                }
                UnsavedWorkSection(store: store).arrive(2)
                timeline.arrive(3)
                projectsThisWeek.arrive(4)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 880, alignment: .leading)
        }
        .task {
            usage = await UsageTracker.shared.summary()
            memory = MemoryStatus.current()
            let weekStart = store.planUsage?.week?.resetsAt?.addingTimeInterval(-UsageForecast.weekLength) ?? Date().addingTimeInterval(-UsageForecast.weekLength)
            projects = await UsageTracker.shared.projectTotals(since: weekStart)
        }
    }

    /// Which projects the week's tokens went to (from this Mac's transcripts), the five biggest.
    @ViewBuilder
    private var projectsThisWeek: some View {
        let top = Array(projects.prefix(5))
        let total = max(1, projects.reduce(0) { $0 + $1.tokens })
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                label("This week by project")
                VStack(spacing: 8) {
                    ForEach(top, id: \.name) { project in
                        let share = Double(project.tokens) / Double(total)
                        HStack(spacing: 10) {
                            Text(project.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary)
                                .lineLimit(1).frame(width: 170, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.07))
                                    Capsule().fill(Theme.projectColor(project.name).opacity(0.8)).frame(width: max(4, geo.size.width * share))
                                }
                            }
                            .frame(height: 6)
                            Text("\(Int((share * 100).rounded()))%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(Theme.secondary).frame(width: 40, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(project.name): \(Int((share * 100).rounded())) percent of this week's tokens")
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("From this Mac's sessions; the plan's limit also counts claude.ai and other devices.")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
        }
    }

    // MARK: Header

    private var mood: NotchMood {
        if !waiting.isEmpty { return .needsYou }
        if store.workingCount > 0 { return .working }
        if store.unseenCount > 0 { return .done }
        return .quiet
    }

    private var headline: String {
        let count = waiting.count
        if count > 0 { return count == 1 ? "1 session needs you" : "\(count) sessions need you" }
        if store.sessions.isEmpty { return "No sessions yet" }
        return "All clear"
    }

    private var header: some View {
        HStack(spacing: 16) {
            OrbFace(mood: mood)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primary)
                summaryLine
            }
            Spacer(minLength: 12)
            if let plan = store.planUsage {
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 22) {
                        if let session = plan.session { usage("Session", session) }
                        if let week = plan.week { usage("Week", week) }
                    }
                    if let forecast = forecast(plan) {
                        Text(forecast.text).font(.system(size: 12)).foregroundStyle(forecast.warn ? Theme.limit : Theme.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Plan usage: \(PlanUsage.summary(plan))")
            }
        }
        .arrive(0)
    }

    /// Where the plan is heading at today's pace: the session running out soon matters most, then the week.
    private func forecast(_ plan: PlanUsage) -> (text: String, warn: Bool)? {
        if let session = plan.session, let out = UsageForecast.runsOut(session, length: UsageForecast.sessionLength) {
            return ("At this pace the session runs out at \(out.formatted(date: .omitted, time: .shortened))", true)
        }
        guard let week = plan.week else { return nil }
        if let out = UsageForecast.runsOut(week, length: UsageForecast.weekLength) {
            return ("At this pace the week runs out \(out.formatted(.dateTime.weekday(.wide).hour().minute()))", true)
        }
        if let end = UsageForecast.percentAtReset(week, length: UsageForecast.weekLength) {
            return ("On pace for about \(Int(min(99, end)))% of the week", false)
        }
        return nil
    }

    /// One of the plan's limits: a ring with the share used, and when it resets.
    private func usage(_ name: String, _ window: UsageWindow) -> some View {
        HStack(spacing: 10) {
            ZStack {
                UsageRing(percent: window.percent, color: window.color, size: 44, line: 5)
                Text("\(Int(window.percent))%").font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Theme.primary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                Text(window.resetText.map { "resets \($0)" } ?? " ").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .help(name == "Session" ? "Your plan's current 5-hour session" : "Your plan's week, all models")
    }

    /// "3 working · 23K tokens this block", and memory only when it's tight.
    private var summaryLine: some View {
        var parts: [String] = []
        let working = store.workingCount
        if working > 0 { parts.append(working == 1 ? "1 working" : "\(working) working") }
        if store.unseenCount > 0 { parts.append(store.unseenCount == 1 ? "1 new result" : "\(store.unseenCount) new results") }
        let used = store.planUsage == nil ? usage?.currentBlockTokens ?? 0 : 0
        let budget = store.planUsage == nil ? AppSettings.shared.blockBudget : 0
        if budget > 0 {
            parts.append("\(Int(min(1, Double(used) / Double(budget)) * 100))% of this block's tokens")
        } else if used > 0 {
            parts.append("\(UsageSummary.format(used)) tokens this block")
        }
        if parts.isEmpty { parts.append(store.sessions.isEmpty ? "Start Claude in a terminal and it shows up here." : "Nothing running.") }
        return HStack(spacing: 6) {
            Text(parts.joined(separator: " · ")).foregroundStyle(Theme.secondary)
            if memory.pressureLevel >= 2 {
                Text("·").foregroundStyle(Theme.faint)
                Label(String(format: "Memory %.1f of %.0f GB", memory.usedGB, memory.totalGB), systemImage: "memorychip")
                    .foregroundStyle(memory.pressureColor)
            }
        }
        .font(.system(size: 13))
    }

    // MARK: Timeline

    private var timeline: some View {
        let entries = store.activity.recent(within: 24 * 3600)
        let shown = showAll ? entries : Array(entries.prefix(24))
        let today = shown.filter { Calendar.current.isDateInToday($0.at) }
        let earlier = shown.filter { !Calendar.current.isDateInToday($0.at) }
        return VStack(alignment: .leading, spacing: 10) {
            if entries.isEmpty {
                label("Today")
                Text("Nothing yet. Sessions show up here as they start, ask and finish.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            if !today.isEmpty { day("Today", today) }
            if !earlier.isEmpty { day("Yesterday", earlier) }
            if entries.count > shown.count {
                Button("Show all \(entries.count)") { withAnimation(.smooth(duration: 0.2)) { showAll = true } }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
    }

    private func day(_ title: String, _ entries: [ActivityEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(title)
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    let live = store.sessions[entry.sessionId] != nil
                    Button { if live { select(entry.sessionId) } } label: { TimelineRow(entry: entry) }
                        .buttonStyle(RowButtonStyle())
                        .disabled(!live)
                        .help(live ? "Open \(entry.name)" : "\(entry.name) has ended")
                }
            }
            .padding(6)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.faint)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One event in the timeline: the time, the project, what happened in its colour, and the detail.
struct TimelineRow: View {
    let entry: ActivityEntry

    private var look: (verb: String, color: Color) {
        switch entry.kind {
        case .started: ("Started", Theme.secondary)
        case .asked: ("Asked", Theme.needsYou)
        case .finished: ("Finished", Theme.working)
        case .failed: ("Stopped", Theme.failed)
        case .limited: ("Limit", Theme.limit)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.at.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.faint)
                .frame(width: 64, alignment: .leading)
            ProjectTile(label: entry.name, colorKey: entry.colorKey, size: 20)
            Text(entry.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1).fixedSize()
            Text(look.verb).font(.system(size: 12, weight: .semibold)).foregroundStyle(look.color).fixedSize()
            MarkdownText(text: entry.text, lineLimit: 1)
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A session that needs you, answerable from the overview: Allow or Deny a permission, pick an answer to a
/// question, or Retry after an error.
struct WaitingCard: View {
    let session: Session
    let store: SessionStore
    let open: () -> Void

    private var approval: PendingApproval? { store.hasPendingPrompt(session.id) ? session.pendingApproval : nil }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProjectTile(session: session, size: 28)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(session.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.primary)
                    StatusChip(session: session)
                    Spacer()
                    Button("Open", action: open)
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .help("Open \(session.label)'s page")
                }
                detail
            }
        }
        .padding(14)
        .background(Wash(color: session.rateLimited ? Theme.limit : session.failed ? Theme.failed : Theme.needsYou, strength: 0.22))
    }

    @ViewBuilder
    private var detail: some View {
        if let approval, approval.isQuestion {
            Text(approval.title).font(.system(size: 13)).foregroundStyle(Theme.primary).lineLimit(2)
            if let question = approval.simpleQuestion {
                QuestionChoices(session: session, question: question, store: store, limit: 4, height: 26)
            } else {
                PillButton(title: "Answer \(approval.questions.count) Questions", symbol: "questionmark.bubble", tint: Theme.needsYou, action: open)
            }
        } else if let approval, approval.isPlan {
            Text(approval.title).font(.system(size: 13)).foregroundStyle(Theme.primary).lineLimit(2)
            HStack(spacing: 7) {
                PillButton(title: "Read the Plan", symbol: "list.bullet.clipboard", tint: Theme.needsYou, action: open)
                AllowButton(title: "Approve", height: 26) { store.respond(to: session.id, with: .allow) }
            }
        } else if let approval {
            Text(approval.title).font(.system(size: 13)).foregroundStyle(Theme.primary).lineLimit(2)
            if let command = approval.command {
                Text("$ " + command)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.middle)
            } else if let file = approval.fileName {
                Text(file).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 7) {
                AllowButton(height: 26) { store.respond(to: session.id, with: .allow) }
                DenyButton(height: 26) { store.respond(to: session.id, with: .deny) }
            }
        } else if session.rateLimited || session.failed {
            Text(session.rateLimited ? (session.limitReset.map { "Usage limit · resets \($0)" } ?? "Usage limit reached")
                 : session.errorText ?? "Stopped with an error")
                .font(.system(size: 13)).foregroundStyle(Theme.primary).lineLimit(2)
            if session.host.canSend {
                if session.rateLimited {
                    ContinueAtButton(session: session, store: store)
                } else {
                    PillButton(title: "Retry", symbol: "arrow.clockwise", tint: Theme.failed) { store.retry(session.id) }
                }
            }
        } else if case .needsYou(let reason) = session.status, reason.hasPrefix("Permission") {
            // A permission prompt WatchMan doesn't hold (it went back to the terminal): answer it there
            Text(reason.replacingOccurrences(of: "Permission · ", with: "Wants to: "))
                .font(.system(size: 13)).foregroundStyle(Theme.primary).lineLimit(2)
            PillButton(title: "Answer in \(session.host.label)", symbol: "arrow.up.forward.app", tint: Theme.primary) {
                store.open(session)
            }
        } else {
            let question = session.lastReply.flatMap { ClosingQuestion.find(in: $0) }?.question ?? session.rowPreview
            Text(question).font(.system(size: 13)).foregroundStyle(Theme.primary).lineLimit(2)
            let chips = store.answerChips(for: session)
            HStack(spacing: 6) {
                ForEach(Array(chips.enumerated()), id: \.element.text) { index, chip in
                    PillButton(title: chip.label, symbol: "arrowshape.turn.up.right.fill", tint: chip.isAnswer ? Theme.unseen : Theme.secondary) {
                        store.sendAnswer(index, for: session.id)
                    }
                    .help("Send: \(chip.text)")
                }
                if session.host.canSend {
                    PillButton(title: "Reply", symbol: "text.cursor", tint: Theme.primary) {
                        open()
                        store.focusWindowReplyId = session.id
                    }
                }
            }
        }
    }
}

/// The notch's face, big, for the overview: it looks the way things stand (waiting, working, done, calm).
struct OrbFace: NSViewRepresentable {
    var mood: NotchMood

    func makeNSView(context: Context) -> OrbFaceView { OrbFaceView() }

    func updateNSView(_ view: OrbFaceView, context: Context) { view.mood = mood }
}

/// Holds an OrbView drawn at three times its notch size, running only while the window can be seen.
final class OrbFaceView: NSView {
    private let orb = OrbView(frame: .zero)
    private var occlusion: NSObjectProtocol?
    var mood: NotchMood = .quiet { didSet { if mood != oldValue { place() } } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(orb)
    }

    required init?(coder: NSCoder) { nil }

    private static let scale: CGFloat = 2.6

    override func layout() {
        super.layout()
        orb.frame = bounds
        orb.layer?.sublayerTransform = CATransform3DMakeScale(Self.scale, Self.scale, 1)
        place()
    }

    /// The layer scales from its bottom-left corner while OrbView takes a top-left point, so the orb goes where
    /// the scale carries it to the middle.
    private func place() {
        guard bounds.width > 0 else { return }
        let center = CGPoint(x: bounds.midX / Self.scale, y: bounds.height - bounds.midY / Self.scale)
        orb.update(mood: mood, center: center, hovered: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        guard let window else { return }
        occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunning() }
        }
        updateRunning()
    }

    private func updateRunning() {
        orb.setRunning(window?.occlusionState.contains(.visible) == true)
    }
}

// MARK: - Details beside a session

/// Beside a session's page in the window: where it runs, then Claude's plan, what the last turn changed, the
/// checks and subagents, each only when there's something to show.
struct SessionInspector: View {
    let session: Session
    let store: SessionStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Session") {
                    HStack(spacing: 6) {
                        HostIcon(host: session.host, size: 14)
                        Text(session.host.label).font(.system(size: 13)).foregroundStyle(Theme.primary)
                    }
                    if let root = session.projectRoot ?? Optional(session.cwd) {
                        Text(PermissionCard.tilde(root)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondary)
                            .lineLimit(2).textSelection(.enabled)
                    }
                    Text("Last activity \(session.lastActivity.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    if let context = session.contextPercent {
                        contextMeter(context)
                    }
                    if let remote = session.remoteURL {
                        HStack(spacing: 6) {
                            RemoteBadge(label: "Remote Control on")
                            Button("Open") { NSWorkspace.shared.open(remote) }
                                .buttonStyle(.link).font(.system(size: 12))
                        }
                    } else {
                        Text("Remote Control off").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
                if !session.tasks.isEmpty {
                    section("Plan") {
                        PlanTrack(tasks: session.tasks, width: 130)
                        ForEach(session.tasks) { task in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Image(systemName: task.status == .done ? "checkmark.circle.fill"
                                      : task.status == .inProgress ? "circle.lefthalf.filled" : "circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(task.status == .done ? Theme.working : task.status == .inProgress ? Theme.unseen : Theme.faint)
                                Text(task.text)
                                    .font(.system(size: 12.5, weight: task.status == .inProgress ? .semibold : .regular))
                                    .foregroundStyle(task.status == .done ? Theme.secondary : Theme.primary)
                                    .strikethrough(task.status == .done, color: Theme.secondary.opacity(0.6))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if let turn = session.lastTurn, !turn.isEmpty {
                    section("Last turn") {
                        if let prompt = turn.prompt {
                            Text("“\(ChatMessageView.cleanPrompt(prompt))”").font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(3)
                        }
                        ForEach(turn.filesEdited.sorted(), id: \.self) { path in
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text").font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                                Text((path as NSString).lastPathComponent).font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.primary).lineLimit(1)
                            }
                            .help(PermissionCard.tilde(path))
                        }
                        HStack(spacing: 6) {
                            if let passed = turn.testsPassed {
                                badge(passed ? "tests passed" : "tests failed", passed ? Theme.working : Theme.failed)
                            }
                            if turn.commits > 0 { badge("\(turn.commits) commit\(turn.commits == 1 ? "" : "s")", Theme.secondary) }
                            if turn.tokens > 0 { badge("\(UsageSummary.format(turn.tokens)) tokens", Theme.secondary) }
                        }
                    }
                }
                if session.verification.analyze != nil || session.verification.test != nil {
                    section("Checks") { VerificationBadges(verification: session.verification) }
                }
                if !session.subagents.isEmpty {
                    section("Subagents") { SubagentPills(agents: session.subagents) }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// How full the conversation is, with /compact when it's nearly full.
    private func contextMeter(_ percent: Double) -> some View {
        let high = percent >= 80
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Context").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
                Text("\(Int(percent))%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(high ? Theme.limit : Theme.primary)
            }
            ProgressView(value: min(100, percent), total: 100).tint(high ? Theme.limit : Theme.working)
            if high, session.host.canSend, !store.hasPendingPrompt(session.id) {
                Button("Run /compact") { Task { store.pageNote = await store.reply("/compact", to: session.id) ?? "Sent: /compact" } }
                    .buttonStyle(.link).font(.system(size: 12))
                    .help("Claude summarises the conversation so far to make room")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.faint)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.white.opacity(0.06), in: Capsule())
    }
}
