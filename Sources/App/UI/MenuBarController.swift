import AppKit
import SwiftUI
import WatchManCore

/// Menu bar icon with a count of what waits. Click: the notch panel (what's waiting first). Right-click: quiet
/// hours, Settings and Quit.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: SessionStore
    private let openSettings: () -> Void
    private let openPanel: () -> Void
    private var quietEnd: Task<Void, Never>?

    init(store: SessionStore, openSettings: @escaping () -> Void, openPanel: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        self.openPanel = openPanel
        super.init()
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        item.isVisible = AppSettings.shared.showMenuBarIcon
        if let window = item.button?.window {
            // The notch uses this icon's position to know how much menu bar space is free
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { _ in
                NotificationCenter.default.post(name: .watchManMenuBarMoved, object: nil)
            }
        }
        observeStore()
    }

    @objc private func openWindow() {
        NotificationCenter.default.post(name: .watchManOpenWindow, object: nil)
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            openPanel()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        if let plan = store.planUsage {
            // Your plan's usage, at a glance
            let line = NSMenuItem(title: PlanUsage.summary(plan), action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
            menu.addItem(.separator())
        }
        if let update = UpdateCheck.shared.available {
            menu.addItem(withTitle: "Update Available: WatchMan \(update.version)…", action: #selector(openUpdate), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Open WatchMan", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open the WatchMan Window", action: #selector(openWindow), keyEquivalent: "").target = self
        if store.waitingCount > 0 {
            menu.addItem(withTitle: "Go Through What's Waiting (\(store.waitingCount))", action: #selector(inbox), keyEquivalent: "")
                .target = self
        }
        menu.addItem(.separator())
        if Quiet.isOn {
            let until = AppSettings.shared.quietUntil > Date().timeIntervalSince1970
                ? Date(timeIntervalSince1970: AppSettings.shared.quietUntil).formatted(date: .omitted, time: .shortened)
                : nil
            let state = NSMenuItem(title: until.map { "Quiet until \($0)" } ?? "Quiet while presenting", action: nil, keyEquivalent: "")
            state.isEnabled = false
            menu.addItem(state)
            if until != nil { menu.addItem(withTitle: "End Quiet", action: #selector(endQuiet), keyEquivalent: "").target = self }
        } else {
            menu.addItem(withTitle: "Quiet for 1 Hour", action: #selector(quietHour), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Quiet Until Tomorrow", action: #selector(quietTomorrow), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit WatchMan", action: #selector(quit), keyEquivalent: "q").target = self
        menu.delegate = self
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Back to plain clicks opening the panel
        item.menu = nil
    }

    @objc private func open() { openPanel() }
    @objc private func openUpdate() { UpdateCheck.shared.openDownload() }
    @objc private func inbox() { store.startInboxRequest() }
    @objc private func quietHour() { Quiet.silence(for: 3600); refresh() }
    @objc private func quietTomorrow() { Quiet.untilTomorrow(); refresh() }
    @objc private func endQuiet() { Quiet.end(); refresh() }
    @objc private func settings() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Left edge of the icon on screen, if macOS is showing it.
    var iconLeftEdge: CGFloat? {
        guard item.isVisible, let window = item.button?.window, window.isVisible, window.frame.width > 0 else { return nil }
        return window.frame.minX
    }

    /// WatchMan's ball with its eyes glancing up and to the right (like the app icon), drawn as a template so it
    /// suits the menu bar.
    static let face: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            // The eyes are cut out of the ball
            NSGraphicsContext.current?.compositingOperation = .clear
            for x in [7.15, 10.4] {
                NSBezierPath(ovalIn: NSRect(x: x, y: 8.7, width: 2.2, height: 3.8)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "WatchMan"
        return image
    }()

    /// The ball, or a moon while quiet; "2" next to it while sessions wait for you.
    private func refresh() {
        item.isVisible = AppSettings.shared.showMenuBarIcon
        let quiet = Quiet.isOn
        item.button?.image = quiet ? NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "WatchMan, quiet") : Self.face
        let waiting = store.waitingCount
        item.button?.title = waiting > 0 ? " \(waiting)" : ""
        item.button?.contentTintColor = waiting > 0 ? .systemOrange : nil
        // Quiet ends on its own: look again then
        quietEnd?.cancel()
        let until = AppSettings.shared.quietUntil - Date().timeIntervalSince1970
        if until > 0 {
            quietEnd = Task { [weak self] in
                try? await Task.sleep(for: .seconds(until + 1))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    private func observeStore() {
        withObservationTracking {
            _ = AppSettings.shared.showMenuBarIcon
            _ = AppSettings.shared.quietUntil
            _ = store.waitingCount
            refresh()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStore() }
        }
    }
}

extension Notification.Name {
    static let watchManMenuBarMoved = Notification.Name("watchManMenuBarMoved")
}
