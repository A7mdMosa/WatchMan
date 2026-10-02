import AppKit
import Carbon.HIToolbox
import SwiftUI
import WatchManCore

@MainActor @Observable
final class NotchModel {
    enum Mode { case collapsed, peek, expanded }

    var mode: Mode = .collapsed
    var notchWidth: CGFloat = 185
    var notchHeight: CGFloat = 32
    var hasNotch = true
    var expandedContentHeight: CGFloat = 200
    /// The newest message, drawn inside the island below the notch row (0: none).
    var messageHeight: CGFloat = 0
    /// A two-finger swipe stretching the island like a rubber band (up to −10 pt).
    var stretch: CGFloat = 0
    /// The tallest the open island may be (three quarters of the screen).
    var maxIslandHeight: CGFloat = 700
    /// A session's page is open: the island widens for the chat.
    var pageOpen = false
    /// What fits on each side of the notch.
    var ears = NotchEars.Layout()
    /// Width of the closed strip: ears + notch + shoulders.
    var barWidth: CGFloat = 200
    /// The black island inside the fixed, transparent panel. SwiftUI animates these, so the
    /// island morphs smoothly instead of the window resizing.
    var islandX: CGFloat = 0
    var islandWidth: CGFloat = 200
    var islandHeight: CGFloat = 32
    /// Where the ears row starts inside the island.
    var barOffset: CGFloat = 0
    var panelWidth: CGFloat = 960
    /// Pinned: stays open until you close it yourself.
    var pinned = false
    /// The pointer is over the closed strip: it grows a little at once, before the preview opens.
    var hovered = false
    /// The island's outline, animated with its size.
    var shapeShoulder: CGFloat = NotchModel.shoulder
    var shapeRadius: CGFloat = NotchModel.stripRadius

    /// What the island feels like (drives the dots and the light on its edge).
    var mood = NotchMood.asleep
    /// Animating. Off while asleep, and a while after things went quiet, so an idle WatchMan uses no CPU.
    var lively = false

    /// Click on the strip's centre (or the island): the full list.
    @ObservationIgnored var onTap: () -> Void = {}
    /// Click on the left side: the session it talks about.
    @ObservationIgnored var onTapLeft: () -> Void = {}
    /// Click on the right side: only what needs you and what's new.
    @ObservationIgnored var onTapRight: () -> Void = {}
    /// Open the list at one session's details (true: ready to type a reply).
    @ObservationIgnored var onShowSession: (String, Bool) -> Void = { _, _ in }
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onSettings: () -> Void = {}
    @ObservationIgnored var onContentHeight: () -> Void = {}
    /// Files dropped on the island.
    @ObservationIgnored var onDropFiles: ([String]) -> Void = { _ in }

    var expandedWidth: CGFloat { CGFloat(AppSettings.shared.panelWidth) }
    /// A session's page is at least this wide, so the chat reads comfortably.
    static let pageWidth: CGFloat = 880
    static let peekWidth: CGFloat = 460
    /// Concave curve joining the strip to the menu bar.
    static let shoulder: CGFloat = 7
    /// Bottom corner radius of the closed strip, close to the hardware notch's.
    static let stripRadius: CGFloat = 10
    static let pillWidth: CGFloat = 320
    /// The island while a message grows out of it.
    static let messageWidth: CGFloat = 480
    /// Open, how far the orb's centre sits from the island's left edge.
    static let openOrbInset: CGFloat = 30
    static let pillHeight: CGFloat = 26
    /// The messages below the notch.
    static let toastWidth: CGFloat = 420
    static let toastSpacing: CGFloat = 6
    static let toastTop: CGFloat = 8
    /// Opening springs a little, like the Dynamic Island; closing is quick and settles without a bounce.
    /// With Reduce Motion neither bounces.
    @MainActor static var open: Animation {
        Motion.reduced ? .smooth(duration: 0.22) : .spring(response: 0.42, dampingFraction: 0.8)
    }
    @MainActor static var close: Animation {
        Motion.reduced ? .smooth(duration: 0.16) : .spring(response: 0.32, dampingFraction: 1)
    }
    /// Small adjustments (content height, counts, the strip's width, hover).
    static let adjustDuration = 0.15
    static let adjust = Animation.smooth(duration: adjustDuration)
    /// Content fading in and out.
    static let fade = Animation.smooth(duration: 0.1)
    /// How much the strip grows under the pointer.
    static let hoverGrow: CGFloat = 4

    struct IslandRect: Equatable {
        var left: CGFloat
        var right: CGFloat
        var height: CGFloat
        var barLeft: CGFloat
    }

    /// The island's extent for a mode, in the same horizontal coordinates as `midX` (the notch centre).
    func islandRect(midX: CGFloat, peekRows: CGFloat, maxHeight: CGFloat,
                    ears: NotchEars.Layout, barWidth: CGFloat) -> IslandRect {
        let notchLeft = midX - notchWidth / 2
        let barLeft = notchLeft - ears.left.width - NotchModel.shoulder
        let barRight = barLeft + barWidth
        switch mode {
        case .collapsed:
            if messageHeight > 0 {
                let half = max(NotchModel.messageWidth / 2, midX - barLeft, barRight - midX)
                return IslandRect(left: midX - half, right: midX + half, height: notchHeight + messageHeight + stretch, barLeft: barLeft)
            }
            let grow = hovered ? NotchModel.hoverGrow : 0
            return IslandRect(left: barLeft - grow, right: barRight + grow, height: notchHeight + grow / 2, barLeft: barLeft)
        case .peek:
            let half = max(NotchModel.peekWidth / 2, midX - barLeft, barRight - midX)
            let height = notchHeight + 6 + peekRows + 10 + stretch
            return IslandRect(left: midX - half, right: midX + half, height: height, barLeft: barLeft)
        case .expanded:
            let height = min(notchHeight + expandedContentHeight + 8, maxHeight)
            let width = pageOpen ? max(expandedWidth, NotchModel.pageWidth) : expandedWidth
            return IslandRect(left: midX - width / 2, right: midX + width / 2, height: height, barLeft: barLeft)
        }
    }
}

/// Borderless panel hugging the notch. It never activates WatchMan, and only
/// becomes key while you type or use the keyboard shortcut.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosting view that accepts the first click (no need to focus WatchMan first).
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The parts of a key event the notch needs (NSEvent itself isn't Sendable).
struct KeyPress: Sendable {
    var code: Int
    var flags: NSEvent.ModifierFlags
    var windowNumber: Int
}

@MainActor
final class NotchController {
    let model = NotchModel()
    private let store: SessionStore
    private let panel: NotchPanel
    private let islandBack = IslandBackView(frame: .zero)
    private let orbView = OrbView(frame: .zero)
    private let activityView = ActivityTextView(frame: .zero)
    private var collapseTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var hovering = false
    private var menuOpen = false
    /// Where the island is on screen; outside it the panel lets every click through.
    private var islandScreenRect = NSRect.zero
    /// Where the messages below the notch are (they take clicks too, but hovering them doesn't open the notch).
    private var toastsScreenRect = NSRect.zero
    private var keyMonitor: Any?
    /// The last reaction the ball played, so each plays once.
    private var lastReaction: UUID?
    private var scrollMonitor: Any?
    /// Two-finger travel over the island in this gesture (fingers up is positive).
    private var swipe: CGFloat = 0
    private var swipeArmed = false
    private var swipeEnd: Task<Void, Never>?
    static let swipeThreshold: CGFloat = 36
    private var clickMonitor: Any?
    private var moveMonitors: [Any] = []
    private var hotKey: HotKey?
    /// Sessions waiting on you, to notice a new one (it gets the full attention again).
    private var waitingIds: Set<String> = []
    /// Several sessions working: the left line moves to the next one every few seconds.
    private var rotation = 0
    private var rotationTask: Task<Void, Never>?
    /// Re-lays out when the left line's moment is over (a new result stops being new) or the island falls asleep.
    private var expiryTask: Task<Void, Never>?
    /// Quiet: keep breathing until then, then hold still.
    private var awakeUntil = Date()
    private var livelyTask: Task<Void, Never>?
    private var lastFeedback: NotchActivity?
    private var settings: AppSettings { AppSettings.shared }

    /// Reads where every menu bar icon is, and re-lays out if they moved.
    private func remeasureStatusItems() {
        MenuBarSpace.refreshStatusItems { [weak self] in self?.layout(animated: true) }
        // An iPhone's Live Activity comes and goes in the menu bar by itself: make room for it when it does
        MenuBarSpace.watchLiveActivities { [weak self] in self?.layout(animated: true) }
    }
    /// Left edge of WatchMan's own menu bar icon: everything right of the notch up to it is free.
    var openSettings: () -> Void = {}
    var menuBarLeftEdge: () -> CGFloat? = { nil } {
        didSet { layout(animated: false) }
    }

    init(store: SessionStore) {
        self.store = store
        panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        // Clicking buttons must not steal the keyboard; only text fields take it
        panel.becomesKeyOnlyIfNeeded = true
        // The panel is large and transparent; it only takes the mouse while it's over the island
        panel.ignoresMouseEvents = true

        let hosting = NotchHostingView(rootView: NotchView(model: model, store: store))
        hosting.sizingOptions = []
        // The living part of the island runs in Core Animation: behind the SwiftUI island its glow and the part
        // that breathes, in front of it the orb
        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        for view in [islandBack, hosting, orbView, activityView] as [NSView] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        panel.contentView = container

        model.onTap = { [weak self] in
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            self?.expand()
        }
        model.onTapLeft = { [weak self] in
            guard let self else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            if self.model.ears.left.activity?.kind == .problem {
                self.openSettings()
            } else if let id = self.model.ears.left.activity?.sessionId, self.store.sessions[id] != nil {
                self.showSession(id, reply: false)
            } else {
                self.expand()
            }
        }
        model.onTapRight = { [weak self] in
            guard let self else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            self.expand(attentionOnly: self.store.waitingCount + self.store.unseenCount > 0)
        }
        model.onShowSession = { [weak self] id, reply in self?.showSession(id, reply: reply) }
        model.onClose = { [weak self] in self?.collapse(force: true) }
        model.onSettings = { [weak self] in
            self?.collapse(force: true)
            self?.openSettings()
        }
        model.onDropFiles = { [weak self] paths in
            guard let self, !paths.isEmpty else { return }
            // On a session's page they go to that session; otherwise you pick one
            if let id = self.store.pageId, self.model.mode == .expanded {
                self.store.appendToDraft(paths, for: id)
                self.store.focusReplyId = id
                self.panel.makeKey()
                return
            }
            self.store.pendingDrop = paths
            self.expand()
            self.panel.makeKey()
        }
        model.onContentHeight = { [weak self] in
            guard let self, self.model.mode == .expanded else { return }
            self.layout(animated: true)
        }

        let center = NotificationCenter.default
        center.addObserver(forName: .watchManCollapse, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }
        center.addObserver(forName: .watchManOpenSession, object: nil, queue: .main) { [weak self] note in
            guard let id = note.object as? String else { return }
            MainActor.assumeIsolated { self?.showSession(id, reply: true) }
        }
        center.addObserver(forName: .watchManNeedsKeyboard, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.makeKey() }
        }
        // Key hints (⌘↩ Allow) only show while the keys work
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.panelHasKeyboard = true }
        }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.panelHasKeyboard = false }
        }
        // A new session's tab didn't open: say why beside the notch
        center.addObserver(forName: .watchManStartFailed, object: nil, queue: .main) { [weak self] note in
            let text = note.object as? String ?? "Couldn't open a terminal tab"
            MainActor.assumeIsolated {
                self?.store.announce(text, short: "Couldn't start Claude", tone: .error, seconds: 8, reaction: .error)
            }
        }
        center.addObserver(forName: .watchManStartInbox, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.expand()
                self.panel.makeKey()
                self.startInbox()
            }
        }
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.placePanel()
                self?.layout(animated: false)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Another app's menus and icons: measure again (on events, never on a timer)
                MenuBarSpace.invalidate()
                self?.remeasureStatusItems()
                self?.layout(animated: true)
            }
        }
        // Reduce Motion turned on or off: the living layers hold still or move again
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.islandBack.motionSettingChanged()
                self?.orbView.motionSettingChanged()
                self?.activityView.motionSettingChanged()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(animated: false) }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.remeasureStatusItems() }
            }
        }
        center.addObserver(forName: .watchManMenuBarMoved, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(animated: true) }
        }
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = false }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let key = KeyPress(code: Int(event.keyCode), flags: event.modifierFlags, windowNumber: event.windowNumber)
            let handled = MainActor.assumeIsolated { self.handleKey(key) }
            return handled ? nil : event
        }
        // Two fingers over the island: up dismisses the message or the preview, down opens the panel
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handleScroll(event) }
            return handled ? nil : event
        }
        hotKey = HotKey(keyCode: UInt32(settings.hotKeyCode), modifiers: UInt32(settings.hotKeyModifiers)) { [weak self] in
            self?.toggleFromShortcut()
        }
        observeHotKey()
        // Clicks in other apps (a global monitor never sees clicks in WatchMan itself)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }

        // Hover without polling: mouse moves outside WatchMan (global) and over it (local)
        moveMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        } as Any)
        moveMonitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.trackMouse() }
            return event
        } as Any)

        observeStore()
        observeReactions()
        placePanel()
        layout(animated: false)
        remeasureStatusItems()
        panel.orderFrontRegardless()
    }

    // MARK: - Modes

    func expand(attentionOnly: Bool = false) {
        collapseTask?.cancel()
        hoverTask?.cancel()
        store.attentionOnly = attentionOnly
        if model.mode != .expanded {
            store.pruneDeadSessions()
            store.discover()
            store.freezeOrder(true)
            ObsidianIndex.shared.refreshIfNeeded()
        }
        setMode(.expanded)
    }

    /// Closes unless pinned; `force` (× button, Esc, ⌥Space) closes even when pinned.
    func collapse(force: Bool = false) {
        guard force || !model.pinned else { return }
        collapseTask?.cancel()
        hoverTask?.cancel()
        model.pinned = false
        store.isEditing = false
        store.selectedId = nil
        store.attentionOnly = false
        store.pageId = nil
        store.otherPage = nil
        store.inbox = false
        store.pendingDrop = []
        store.freezeOrder(false)
        if panel.isKeyWindow {
            // Give the keyboard back to the app you were in
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        setMode(.collapsed)
    }

    /// Opens one session's page; `reply` puts the keyboard in its reply box.
    func showSession(_ id: String, reply: Bool) {
        expand()
        store.openPage(id)
        if reply, store.sessions[id]?.host.canSend == true {
            panel.makeKey()
            store.focusReplyId = id
        }
    }

    /// The session as it is now (an alert is decided a moment after the change it's about).
    func session(_ id: String) -> Session? { store.sessions[id] }

    /// A message below the notch (not while the panel is open: you're looking at it already).
    func showToast(_ kind: SessionStore.Toast.Kind, for session: Session, seconds: Double) {
        guard model.mode != .expanded else { return }
        store.showToast(kind, for: session, seconds: seconds)
    }

    /// ⌥Space: go through what's waiting (longest waiting first), or open the list; again to close.
    func toggleFromShortcut() {
        if model.mode == .expanded {
            collapse(force: true)
            return
        }
        expand()
        panel.makeKey()
        if !startInbox() {
            store.selectedId = store.visibleOrdered.first?.id
        }
    }

    /// Opens the session that has waited longest, ready to answer: Allow if it asks permission, else the reply box.
    @discardableResult
    private func startInbox() -> Bool {
        guard store.startInbox(), let id = store.pageId, let session = store.sessions[id] else { return false }
        if !store.hasPendingPrompt(id), session.host.canSend { store.focusReplyId = id }
        return true
    }

    /// The menu bar icon: open the list, or close it (going through what's waiting is in its menu and on ⌥Space).
    func togglePanel() {
        if model.mode == .expanded {
            collapse(force: true)
        } else {
            expand()
            store.selectedId = store.visibleOrdered.first?.id
        }
    }

    private func clickedOutside() {
        guard model.mode != .collapsed, settings.closeOnClickOutside || model.mode == .peek else { return }
        collapse()
    }

    /// The last time you moved the mouse: a long gap means you were away.
    private var lastInput = Date()
    static let awayAfter: TimeInterval = 10 * 60

    /// Back after 10+ minutes: one message with what finished, what waits and what may be stuck meanwhile.
    private func noteInput() {
        let now = Date()
        defer { lastInput = now }
        guard now.timeIntervalSince(lastInput) > Self.awayAfter, !Quiet.isOn else { return }
        let since = lastInput
        let sessions = store.ordered
        let finished = sessions.filter { $0.isUnseenResult && $0.statusSince > since }.count
        let waiting = sessions.filter { $0.status.isNeedsYou }.count
        let stuck = sessions.filter { $0.stuck != nil }.count
        guard finished + waiting + stuck > 0, model.mode != .expanded else { return }
        tell(.back(finished: finished, waiting: waiting, stuck: stuck))
    }

    /// A moment that needs nothing from you, told the way Settings → Notifications says: the ball reacts and the
    /// line beside the notch says it (default), plus a short line, or the full message as before.
    func tell(_ moment: NewsMoment) {
        let style = settings.newsStyle
        let text: String?, tone: NotchActivity.Tone, reaction: OrbReaction?, seconds: Double
        let full: () -> Void
        switch moment {
        case .started(let session, let prompt):
            (text, tone, reaction, seconds) = ("\(session.label) started", .started, .started, 4)
            full = { self.showToast(.started(prompt: prompt), for: session, seconds: 2.5) }
        case .finished(let session):
            // The line says it by itself while the result is new, and the ball hops with confetti
            (text, tone, reaction, seconds) = (nil, .finished, nil, 0)
            full = { self.showToast(.finished(text: SessionStore.resultLine(session)), for: session, seconds: self.settings.popDuration) }
        case .stuck(let session):
            (text, tone, reaction, seconds) = ("\(session.label) may be stuck", .warning, .stuck, 6)
            full = { self.showToast(.stuck(text: session.stuck?.text ?? "It may be stuck"), for: session, seconds: 12) }
        case .error(let session):
            // The line keeps saying it while it's stopped
            (text, tone, reaction, seconds) = (nil, .error, .error, 0)
            full = { self.showToast(.failed(text: session.errorText ?? "Claude Code stopped with an error"), for: session, seconds: 20) }
        case .limit(let session):
            (text, tone, reaction, seconds) = (nil, .limit, .limit, 0)
            full = { self.showToast(.limit(resets: session.limitReset), for: session, seconds: 30) }
        case .usage(let window, let percent, let resets):
            (text, tone, reaction, seconds) = ("\(window) usage at \(percent)%", .limit, .usage(Double(percent) / 100), 6)
            full = { self.store.showToast(.usage(window: window, percent: percent, resets: resets), id: "usage-\(window)", seconds: 20) }
        case .back(let finished, let waiting, let stuck):
            let parts = [finished > 0 ? "\(finished) finished" : nil, waiting > 0 ? "\(waiting) need\(waiting == 1 ? "s" : "") you" : nil,
                         stuck > 0 ? "\(stuck) may be stuck" : nil].compactMap { $0 }
            (text, tone, reaction, seconds) = ("While you were away: " + parts.joined(separator: " · "), .info, .back, 8)
            full = { self.store.showToast(.away(finished: finished, waiting: waiting, stuck: stuck), id: SessionStore.awayId, seconds: 30) }
        }
        if style == .full {
            full()
            return
        }
        if let reaction {
            wake(for: 4)
            store.announce(text, short: text ?? "", tone: tone, seconds: seconds, reaction: reaction)
        }
        if style == .brief {
            let line: String = switch moment {
            case .finished(let session): "\(session.label) finished"
            case .error(let session): "\(session.label) stopped with an error"
            case .limit(let session): "\(session.label) hit the usage limit"
            default: text ?? ""
            }
            guard !line.isEmpty, model.mode != .expanded else { return }
            store.showToast(.brief(text: line, tone: tone), id: "brief", seconds: 3)
        }
    }

    /// Called on every mouse move: is the pointer over the island?
    private func trackMouse() {
        noteInput()
        // Focus can move to a window on another display within the same app: follow it while closed
        if model.mode == .collapsed, settings.followActiveScreen, let main = NSScreen.main, main.frame != placedOn {
            layout(animated: false)
            return
        }
        let mouse = NSEvent.mouseLocation
        let inside = islandScreenRect.insetBy(dx: -2, dy: -2).contains(mouse)
        let onToasts = toastsScreenRect.contains(mouse) || (inside && model.messageHeight > 0)
        if panel.ignoresMouseEvents == (inside || onToasts) { panel.ignoresMouseEvents = !(inside || onToasts) }
        if store.holdToasts != onToasts { store.holdToasts = onToasts }
        guard inside != hovering else { return }
        hover(inside)
    }

    /// Keeps the island animating for a while (it stays lively anyway while something is going on).
    private func wake(for seconds: Double) {
        awakeUntil = max(awakeUntil, Date().addingTimeInterval(seconds))
        updateLively()
    }

    private func updateLively() {
        let busy = [.working, .needsYou, .done, .worried].contains(model.mood)
        let lively = model.mode != .expanded && (busy || Date() < awakeUntil)
        if model.lively != lively {
            model.lively = lively
            islandBack.setRunning(lively)
            activityView.setRunning(lively)
        }
        // Open, the ball stays alive in the corner (it's on screen; its motion runs in Core Animation)
        orbView.setRunning(lively || model.mode == .expanded)
        livelyTask?.cancel()
        guard lively, !busy else { return }
        let wait = awakeUntil.timeIntervalSinceNow
        livelyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.1, wait)))
            guard !Task.isCancelled else { return }
            self?.updateLively()
        }
    }

    private func hover(_ inside: Bool) {
        hovering = inside
        hoverTask?.cancel()
        if inside, model.mode == .collapsed {
            // Icons may have moved since the last event; and something waiting gets one nudge
            remeasureStatusItems()
            if model.mood == .needsYou { islandBack.poke() }
        }
        // The strip answers the pointer at once: it grows a little, and shrinks back when it leaves
        let grow = inside && model.mode == .collapsed
        if model.hovered != grow {
            withAnimation(NotchModel.adjust) {
                model.hovered = grow
                layout(animated: false)
            }
        }
        switch (model.mode, inside) {
        case (.collapsed, true):
            // Over a message you're reading it, not asking for the preview
            guard settings.hoverPreview, model.messageHeight == 0 else { return }
            // Wait a moment so a mouse passing by doesn't open it
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.settings.hoverDelay ?? 0.25))
                guard let self, !Task.isCancelled, self.hovering, NSEvent.pressedMouseButtons == 0,
                      self.model.mode == .collapsed else { return }
                self.setMode(.peek)
            }
        case (.peek, false):
            // Short grace period so leaving by a pixel doesn't flicker
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled, !self.hovering, self.model.mode == .peek else { return }
                self.setMode(.collapsed)
            }
        case (.expanded, true):
            collapseTask?.cancel()
        case (.expanded, false):
            if settings.closeOnMouseLeave, !model.pinned, !panel.isKeyWindow {
                scheduleCollapse(after: settings.mouseLeaveDelay)
            }
        default:
            break
        }
    }

    private func scheduleCollapse(after seconds: Double) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, !self.hovering, !self.store.isEditing, !self.model.pinned else { return }
            if self.menuOpen {
                self.scheduleCollapse(after: 1.0)
                return
            }
            self.collapse()
        }
    }

    private func setMode(_ mode: NotchModel.Mode) {
        guard model.mode != mode else { return }
        func size(_ m: NotchModel.Mode) -> Int { m == .collapsed ? 0 : m == .peek ? 1 : 2 }
        let growing = size(mode) > size(model.mode)
        if mode != .collapsed { model.hovered = false }
        if growing {
            withAnimation(NotchModel.open) {
                model.mode = mode
                layout(animated: false)
            }
        } else {
            // Closing: the content fades out first (0.12 s), then the island shrinks
            withAnimation(.easeOut(duration: 0.12)) { model.mode = mode }
            withAnimation(NotchModel.close.delay(0.06)) { layout(animated: false) }
        }
        updateLively()
    }

    /// The shortcut changed in Settings: register the new one.
    private func observeHotKey() {
        withObservationTracking {
            _ = settings.hotKeyCode
            _ = settings.hotKeyModifiers
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hotKey?.register(keyCode: UInt32(self.settings.hotKeyCode), modifiers: UInt32(self.settings.hotKeyModifiers))
                self.observeHotKey()
            }
        }
    }

    // MARK: - Swipes

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard model.mode != .expanded, islandScreenRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) else { return false }
        // The fling after the fingers lift isn't a new swipe
        if !event.momentumPhase.isEmpty { return true }
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { dx *= 8; dy *= 8 }
        guard abs(dy) > 1.5 * abs(dx) else { return false }
        swipe += event.isDirectionInvertedFromDevice ? -dy : dy
        // Stretches like a rubber band while it would dismiss something
        if swipe > 0, model.messageHeight > 0 || model.mode == .peek, !Motion.reduced {
            withAnimation(.interactiveSpring) {
                model.stretch = -min(10, swipe * 0.25)
                layout(animated: false)
            }
        }
        let crossed = abs(swipe) > Self.swipeThreshold
        if crossed != swipeArmed {
            swipeArmed = crossed
            if crossed { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        swipeEnd?.cancel()
        if event.phase == .ended || event.phase == .cancelled {
            finishSwipe()
        } else {
            // A mouse wheel has no phases: the gesture ends after 300 ms without events
            swipeEnd = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.finishSwipe()
            }
        }
        return true
    }

    private func finishSwipe() {
        swipeEnd?.cancel()
        let travel = swipe
        swipe = 0
        swipeArmed = false
        if travel > Self.swipeThreshold {
            if model.mode == .peek {
                setMode(.collapsed)
            } else if let top = store.toasts.first {
                withAnimation(.easeOut(duration: 0.12)) { store.dismissToast(top.id) }
            }
        } else if travel < -Self.swipeThreshold {
            expand()
        }
        withAnimation(NotchModel.close) {
            model.stretch = 0
            layout(animated: false)
        }
    }

    // MARK: - Keyboard

    /// The next waiting session (⇧⇥ the one before), going round the queue.
    private func goToNextWaiting(from id: String, back: Bool) -> Bool {
        let queue = store.waitingQueue
        guard let index = queue.firstIndex(where: { $0.id == id }) ?? (queue.isEmpty ? nil : -1) else { return true }
        store.inbox = true
        let step = back ? -1 : 1
        store.openPage(queue[((index + step) % queue.count + queue.count) % queue.count].id)
        return true
    }

    /// List: arrows move, Enter or 1–9 open a session's page, O opens its terminal, R replies.
    /// Page: ⌘↩ allows, ⌘⌫ denies, Tab goes to the next waiting session, O opens the terminal, R replies,
    /// Esc goes back. Esc on the list closes.
    private func handleKey(_ event: KeyPress) -> Bool {
        guard model.mode == .expanded, event.windowNumber == panel.windowNumber else { return false }
        let typing = panel.firstResponder is NSText
        let code = event.code
        if code == kVK_Escape {
            // An empty reply box goes straight back to the list; with a draft, Esc first leaves the box
            let emptyDraft = store.pageId.map { (store.drafts[$0] ?? "").isEmpty } ?? false
            if typing && !emptyDraft {
                panel.makeFirstResponder(nil)
            } else if store.pageId != nil || store.otherPage != nil {
                if typing { panel.makeFirstResponder(nil) }
                store.pageId = nil
                store.otherPage = nil
                store.inbox = false
            } else {
                collapse(force: true)
            }
            return true
        }
        // On a page these work while you type too: ⌘1–3 send an answer, ⌘V attaches a copied picture or file,
        // ⇥ goes on to the next waiting session (the page opens with the reply box ready)
        if let id = store.pageId, store.sessions[id] != nil {
            let command = event.flags.contains(.command) && event.flags.intersection([.control, .option]).isEmpty
            if command, let digit = [kVK_ANSI_1: 0, kVK_ANSI_2: 1, kVK_ANSI_3: 2, kVK_ANSI_4: 3][code] {
                return store.sendAnswer(digit, for: id)
            }
            if typing, command, code == kVK_ANSI_V, store.pasteAttachments(into: id) { return true }
            if typing, code == kVK_Tab { return goToNextWaiting(from: id, back: event.flags.contains(.shift)) }
        }
        guard !typing else { return false }
        if let id = store.pageId, let session = store.sessions[id] {
            let command = event.flags.contains(.command)
            switch code {
            case kVK_Return where command && store.hasPendingPrompt(id):
                store.respond(to: id, with: .allow)
            case kVK_Delete where command && store.hasPendingPrompt(id):
                store.respond(to: id, with: .deny)
            case kVK_Tab:
                return goToNextWaiting(from: id, back: event.flags.contains(.shift))
            case kVK_ANSI_O where !command: store.open(session)
            case kVK_ANSI_R where !command && session.host.canSend:
                panel.makeKey()
                store.focusReplyId = id
            default: return false
            }
            return true
        }
        let ordered = store.visibleOrdered
        let selected = ordered.first { $0.id == store.selectedId }
        // ⌘↩ / ⌘⌫ answer the selected row's prompt right in the list
        if store.otherPage == nil, event.flags.contains(.command), let selected, store.hasPendingPrompt(selected.id) {
            if code == kVK_Return { store.respond(to: selected.id, with: .allow); return true }
            if code == kVK_Delete { store.respond(to: selected.id, with: .deny); return true }
        }
        guard store.otherPage == nil, event.flags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch code {
        case kVK_DownArrow:
            store.moveSelection(by: 1)
        case kVK_UpArrow:
            store.moveSelection(by: -1)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            if let selected { store.openPage(selected.id) }
        case kVK_ANSI_O:
            if let selected { store.open(selected) }
        case kVK_ANSI_R:
            guard let selected, selected.host.canSend else { return true }
            showSession(selected.id, reply: true)
        default:
            let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                          kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            guard let index = digits.firstIndex(of: code) else { return false }
            if index < ordered.count { store.openPage(ordered[index].id) }
        }
        return true
    }

    // MARK: - Geometry

    /// Plays the ball's one-off reactions (a session started, an error…) as the store asks for them.
    private func observeReactions() {
        withObservationTracking {
            _ = store.reaction
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let event = self.store.reaction, event.id != self.lastReaction {
                    self.lastReaction = event.id
                    self.orbView.react(event.kind)
                }
                self.observeReactions()
            }
        }
    }

    /// Re-lays out when what the closed notch shows changes.
    private func observeStore() {
        withObservationTracking {
            _ = store.ordered.count
            _ = store.waitingCount
            _ = store.unseenCount
            _ = store.workingCount
            _ = store.ticker
            _ = store.feedback
            _ = store.subagentCount
            _ = store.ordered.map(\.tasks.count)
            _ = store.ordered.map(\.failed)
            _ = store.toasts
            _ = store.pageOpen
            _ = AppHealth.shared.problem
            _ = store.ordered.map(\.status)
            _ = store.ordered.map(\.lastStep)
            _ = store.ordered.map(\.displayName)
            _ = settings.panelWidth
            _ = settings.showMenuBarIcon
            _ = settings.notchLeft
            _ = settings.notchRight
            _ = settings.followActiveScreen
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.layout(animated: true)
                self?.observeStore()
            }
        }
    }

    /// The screen you're working on (its menu bar is active), or the built-in display with the notch.
    /// While the island is open it stays where it is, so it never jumps away under the pointer.
    private var screen: NSScreen? {
        if model.mode != .collapsed, let placed = NSScreen.screens.first(where: { $0.frame == placedOn }) {
            return placed
        }
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        return settings.followActiveScreen ? (NSScreen.main ?? notched) : (notched ?? NSScreen.main)
    }
    private var placedOn: CGRect = .zero

    private func layout(animated: Bool) {
        guard let screen else { return }
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notchWidth = frame.width - left.width - right.width
            model.notchHeight = screen.safeAreaInsets.top
            model.hasNotch = true
        } else {
            // No notch: a small pill centred in the menu bar
            model.notchWidth = 24
            model.notchHeight = max(24, frame.maxY - screen.visibleFrame.maxY)
            model.hasNotch = false
        }
        if frame != placedOn { placePanel() }
        // Only use the menu bar space that's actually free: from the notch to the first icon
        let shoulder = NotchModel.shoulder
        let notchLeft = frame.midX - model.notchWidth / 2
        let notchRight = notchLeft + model.notchWidth
        let available: CGFloat
        let ownIcon = menuBarLeftEdge().flatMap { $0 > notchRight && $0 < frame.maxX ? $0 : nil }
        if let edge = [MenuBarSpace.firstStatusItem(rightOf: notchRight), ownIcon].compactMap({ $0 }).min(),
           MenuBarSpace.statusItemEdges != nil {
            // Every app's menu bar icons are known (Accessibility): stop before the nearest one
            available = edge - notchRight - shoulder - 6
        } else if let edge = menuBarLeftEdge(), edge > notchRight, edge < frame.maxX {
            available = edge - notchRight - shoulder - 4
        } else if !settings.showMenuBarIcon {
            available = 64      // can't measure without our icon: stay compact
        } else {
            available = 0       // our icon is hidden behind the notch: the menu bar is full
        }
        // Left: up to where the frontmost app's menus end (nil if they can't be measured), or a Live Activity
        // shown on that side
        let leftEdge = [MenuBarSpace.appMenusRightEdge(), MenuBarSpace.liveActivityEdge(leftOf: notchLeft)].compactMap { $0 }.max()
        let leftSpace = MenuBarSpace.appMenusRightEdge() == nil ? nil : leftEdge.map { max(0, notchLeft - shoulder - 10 - $0) }
        let ears = NotchEars.layout(store, leftSpace: leftSpace.map { min($0, 320) }, rightSpace: min(available, 320),
                                    rotation: rotation, problem: AppHealth.shared.problem,
                                    left: settings.notchLeft, right: settings.notchRight)
        scheduleRefreshes(for: ears)
        if ears.mood != model.mood {
            model.mood = ears.mood
            wake(for: ears.mood == .asleep ? 8 : 45)
        }
        if let feedback = store.feedback, feedback != lastFeedback {
            islandBack.acknowledge()
            wake(for: 5)
        }
        lastFeedback = store.feedback
        updateLively()
        let barWidth = ears.left.width + model.notchWidth + ears.right.width + 2 * shoulder

        // The island's target shape; SwiftUI animates it inside the fixed panel
        model.maxIslandHeight = frame.height * 0.75
        model.pageOpen = store.pageOpen
        model.messageHeight = model.mode == .collapsed ? (store.toasts.first.map { $0.height + 8 } ?? 0) : 0
        let peekRows = TopSessionsView.height(for: store.ordered, room: TopSessionsView.room(in: model))
        let rect = model.islandRect(midX: frame.midX, peekRows: peekRows,
                                    maxHeight: model.maxIslandHeight,
                                    ears: ears, barWidth: barWidth)
        let origin = panel.frame.minX
        let apply = {
            self.model.ears = ears
            self.model.barWidth = barWidth
            self.model.panelWidth = self.panel.frame.width
            self.model.islandX = rect.left - origin
            self.model.islandWidth = rect.right - rect.left
            self.model.islandHeight = rect.height
            self.model.barOffset = rect.barLeft - rect.left
            switch self.model.mode {
            case .collapsed where self.model.messageHeight > 0: (self.model.shapeShoulder, self.model.shapeRadius) = (9, 20)
            case .collapsed: (self.model.shapeShoulder, self.model.shapeRadius) = (NotchModel.shoulder, NotchModel.stripRadius)
            case .peek: (self.model.shapeShoulder, self.model.shapeRadius) = (8, 18)
            case .expanded: (self.model.shapeShoulder, self.model.shapeRadius) = (10, 24)
            }
        }
        if animated { withAnimation(NotchModel.adjust) { apply() } } else { apply() }
        islandScreenRect = NSRect(x: rect.left, y: frame.maxY - rect.height, width: rect.right - rect.left, height: rect.height)
        // The messages below the island (the newest is inside it)
        let stack = store.toasts.dropFirst().reduce(0) { $0 + $1.height + NotchModel.toastSpacing }
        toastsScreenRect = stack > 0 && model.mode == .collapsed
            ? NSRect(x: frame.midX - NotchModel.toastWidth / 2, y: frame.maxY - rect.height - NotchModel.toastTop - stack,
                     width: NotchModel.toastWidth, height: stack)
            : .zero

        // The living layers, in the panel's top-left coordinates
        let barLeft = rect.barLeft - origin
        let collapsed = model.mode == .collapsed
        islandBack.update(mood: ears.mood,
                          island: CGRect(x: rect.left - origin, y: 0, width: rect.right - rect.left, height: rect.height),
                          shoulder: model.messageHeight > 0 ? 9 : NotchModel.shoulder,
                          radius: model.messageHeight > 0 ? 20 : NotchModel.stripRadius,
                          shown: collapsed && ears.mood != .asleep)
        let living = Self.livingPlacement(ears: ears, barLeft: barLeft, notchWidth: model.notchWidth,
                                          notchHeight: model.notchHeight, expanded: model.mode == .expanded,
                                          islandLeft: rect.left - origin)
        orbView.update(mood: ears.mood, center: living.orb, hovered: model.hovered || model.mode == .peek)
        // A session that starts waiting while another already waits gets the full attention again
        let waitingNow = Set(store.ordered.filter { $0.status.isNeedsYou }.map(\.id))
        if !waitingNow.subtracting(waitingIds).isEmpty {
            islandBack.renewAttention()
            orbView.renewAttention()
        }
        waitingIds = waitingNow
        activityView.update(text: living.text, origin: living.textOrigin, width: living.textWidth)
        trackMouse()
    }

    /// Rotates the left line while several sessions work, and re-picks it when a new result stops being new.
    private func scheduleRefreshes(for ears: NotchEars.Layout) {
        let rotating = ears.left.activity?.kind == .working && store.workingCount > 1
        if rotating, rotationTask == nil {
            rotationTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(4))
                    guard let self, !Task.isCancelled else { return }
                    self.rotation += 1
                    self.layout(animated: true)
                }
            }
        } else if !rotating {
            rotationTask?.cancel()
            rotationTask = nil
        }
        expiryTask?.cancel()
        let changes = [NotchActivity.expiry(of: ears.activity, in: store.ordered), NotchMood.nextChange(store.ordered, now: Date())]
        if let expiry = changes.compactMap({ $0 }).min() {
            expiryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0.1, expiry.timeIntervalSinceNow + 0.1)))
                guard !Task.isCancelled else { return }
                self?.layout(animated: true)
            }
        }
    }

    struct LivingPlacement {
        var orb: CGPoint?
        var text: NSAttributedString?
        var textOrigin: CGPoint?
        var textWidth: CGFloat = 0
    }

    /// Where the orb and the working line go, in the panel's top-left coordinates: the same slots the SwiftUI
    /// ears leave for them. `barLeft` is the closed strip's left edge.
    /// Open, the orb sits at the top left of the island (`islandLeft`), in the notch row.
    static func livingPlacement(ears: NotchEars.Layout, barLeft: CGFloat, notchWidth: CGFloat, notchHeight: CGFloat,
                                expanded: Bool, islandLeft: CGFloat? = nil) -> LivingPlacement {
        var placement = LivingPlacement()
        if expanded {
            if let islandLeft, AppSettings.shared.notchLeft != .nothing || AppSettings.shared.notchRight != .nothing {
                placement.orb = CGPoint(x: islandLeft + NotchModel.openOrbInset, y: notchHeight / 2)
            }
            return placement
        }
        let shoulder = NotchModel.shoulder
        if ears.right.orb {
            let rightEnd = barLeft + shoulder + ears.left.width + notchWidth + ears.right.width
            placement.orb = CGPoint(x: rightEnd - NotchEars.outerPadding - NotchEars.orbWidth / 2, y: notchHeight / 2)
        } else if ears.left.orb {
            placement.orb = CGPoint(x: barLeft + shoulder + NotchEars.outerPadding + NotchEars.orbWidth / 2, y: notchHeight / 2)
        }
        if let activity = ears.left.activity, activity.kind == .working {
            let start = barLeft + shoulder + NotchEars.outerPadding + (ears.left.orb ? NotchEars.orbWidth + NotchEars.gap : 0)
            let prefix = activity.name + " · "
            let detail = !ears.left.useShort && activity.text.hasPrefix(prefix) ? String(activity.text.dropFirst(prefix.count)) : nil
            placement.text = ActivityTextView.attributed(name: activity.name, detail: detail)
            placement.textOrigin = CGPoint(x: start, y: notchHeight / 2)
            placement.textWidth = max(0, barLeft + shoulder + ears.left.width - NotchEars.innerPadding - start)
        }
        return placement
    }

    /// A fixed, transparent panel across the top middle of the screen, big enough for the largest island.
    private func placePanel() {
        guard let screen else { return }
        let frame = screen.frame
        let width = min(frame.width, max(960, CGFloat(AppSettings.widthPresets.map(\.width).max() ?? 880) + 80))
        let height = min(frame.height, frame.height * 0.75 + 40)
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height), display: true)
        placedOn = frame
    }
}
