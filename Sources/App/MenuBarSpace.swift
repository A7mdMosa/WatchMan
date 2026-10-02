import AppKit
import ApplicationServices

/// How much menu bar space is free on each side of the notch.
/// Left: up to where the frontmost app's menus end (needs Accessibility permission to read them).
@MainActor
enum MenuBarSpace {
    private static var cachedMenusEdge: (pid: pid_t, edge: CGFloat?)?

    static var canReadMenus: Bool { AXIsProcessTrusted() }

    /// Shows macOS's Accessibility prompt for WatchMan.
    static func requestAccess() {
        // The value of kAXTrustedCheckOptionPrompt (the constant itself isn't concurrency-safe in Swift 6)
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Forget the measurement, e.g. when another app comes to the front.
    static func invalidate() { cachedMenusEdge = nil }

    // MARK: - Menu bar icons (status items) of every app

    /// Left edges of all menu bar icons, Live Activities included. Nil until measured or without permission.
    static var statusItemEdges: [CGFloat]? { iconEdges.map { ($0 + liveActivities.map(\.minX)).sorted() } }
    /// Left edges of every app's menu bar icons, measured off the main thread.
    private static var iconEdges: [CGFloat]?
    /// Where macOS shows an iPhone's Live Activity in the menu bar (a pill beside the notch). Nothing goes over it.
    private(set) static var liveActivities: [CGRect] = []
    private static var measuring = false
    private static var measuringPills = false

    /// macOS draws the menu bar's own items, and an iPhone's Live Activity, in this process.
    static let menuBarAgent = "com.apple.MenuBarAgent"

    /// The nearest menu bar icon to the right of `x` (screen coordinates), if known.
    static func firstStatusItem(rightOf x: CGFloat) -> CGFloat? {
        statusItemEdges?.filter { $0 > x }.min()
    }

    /// The right edge of a Live Activity shown left of `x` (screen coordinates), if any.
    static func liveActivityEdge(leftOf x: CGFloat) -> CGFloat? {
        liveActivities.filter { $0.maxX <= x }.map(\.maxX).max()
    }

    /// Re-reads where every app's menu bar icons are (needs Accessibility). Calls back when it changed.
    static func refreshStatusItems(then changed: @escaping @MainActor () -> Void) {
        guard canReadMenus, !measuring else { return }
        measuring = true
        // WatchMan's own icon is measured directly; asking ourselves through Accessibility could stall
        let me = ProcessInfo.processInfo.processIdentifier
        let pids = NSWorkspace.shared.runningApplications.map(\.processIdentifier).filter { $0 != me }
        let agent = agentPid
        Task.detached(priority: .utility) {
            let edges = measureStatusItems(pids: pids)
            let pills = agent.map(measureLiveActivities) ?? []
            await MainActor.run {
                measuring = false
                if edges != iconEdges || pills != liveActivities {
                    Log.info("measured \(edges.count) menu bar icons, \(pills.count) Live Activities")
                    iconEdges = edges
                    liveActivities = pills
                    changed()
                }
            }
        }
    }

    /// Re-reads only the Live Activities: cheap, for when the menu bar changes on its own.
    static func refreshLiveActivities(then changed: @escaping @MainActor () -> Void) {
        guard canReadMenus, !measuringPills, let agent = agentPid else { return }
        measuringPills = true
        Task.detached(priority: .utility) {
            let pills = measureLiveActivities(pid: agent)
            await MainActor.run {
                measuringPills = false
                if pills != liveActivities {
                    Log.info("Live Activities in the menu bar: \(pills.map { Int($0.minX) })")
                    liveActivities = pills
                    changed()
                }
            }
        }
    }

    private static var agentPid: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: menuBarAgent).first?.processIdentifier
    }

    // MARK: - Live Activities

    private static var observer: AXObserver?
    private static var observedPid: pid_t?
    private static var onMenuBarChange: (@MainActor () -> Void)?
    private static var pending: Task<Void, Never>?

    /// Tells `changed` when a Live Activity appears, goes or changes size. MenuBarAgent reports its items being
    /// created, destroyed and moved; the clock's every-second ticks are other notifications, not asked for.
    static func watchLiveActivities(_ changed: @escaping @MainActor () -> Void) {
        onMenuBarChange = changed
        guard canReadMenus, let pid = agentPid, pid != observedPid else { return }
        observer = nil
        observedPid = nil
        var made: AXObserver?
        let callback: AXObserverCallback = { _, _, _, _ in
            MainActor.assumeIsolated { MenuBarSpace.menuBarChanged() }
        }
        guard AXObserverCreate(pid, callback, &made) == .success, let made else { return }
        let application = AXUIElementCreateApplication(pid)
        for name in [kAXCreatedNotification, kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification] {
            AXObserverAddNotification(made, application, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .defaultMode)
        observer = made
        observedPid = pid
    }

    /// A burst of changes is measured once, a moment after it settles.
    private static func menuBarChanged() {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let onMenuBarChange else { return }
            refreshLiveActivities(then: onMenuBarChange)
        }
    }

    /// Blocking: the frames of the Live Activity pills macOS shows in the menu bar. They aren't in the menu
    /// bar's list of icons; they're items in MenuBarAgent's menu bar window ("live-activity-pill-…").
    nonisolated private static func measureLiveActivities(pid: pid_t) -> [CGRect] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return [] }
        var pills: [CGRect] = []
        for window in windows {
            guard let frame = frameBlocking(of: window), frame.minY < 60, frame.height < 60 else { continue }
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let items = childrenValue as? [AXUIElement] else { continue }
            for item in items where isLiveActivity(item) {
                if let pill = frameBlocking(of: item), pill.width > 0 { pills.append(pill) }
            }
        }
        return pills.sorted { $0.minX < $1.minX }
    }

    nonisolated private static func isLiveActivity(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &value) == .success,
           let identifier = value as? String, identifier.hasPrefix("live-activity") { return true }
        if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &value) == .success,
           let description = value as? String, description == "Live Activity" { return true }
        return false
    }

    /// Blocking: the left edge of every menu bar extra of these apps, top of the screen only.
    nonisolated private static func measureStatusItems(pids: [pid_t]) -> [CGFloat] {
        var edges: [CGFloat] = []
        for pid in pids {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.1)
            var extrasValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, "AXExtrasMenuBar" as CFString, &extrasValue) == .success,
                  let extrasValue, CFGetTypeID(extrasValue) == AXUIElementGetTypeID() else { continue }
            let extras = unsafeDowncast(extrasValue, to: AXUIElement.self)
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(extras, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let items = childrenValue as? [AXUIElement] else { continue }
            for item in items {
                guard let frame = frameBlocking(of: item), frame.width > 0, frame.minY < 60 else { continue }
                edges.append(frame.minX)
            }
        }
        return edges.sorted()
    }

    nonisolated private static func frameBlocking(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position)
        AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    /// Right edge (screen x) of the frontmost app's menus, or nil if it can't be read.
    static func appMenusRightEdge() -> CGFloat? {
        guard canReadMenus, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if let cached = cachedMenusEdge, cached.pid == app.processIdentifier { return cached.edge }
        let edge = measure(pid: app.processIdentifier)
        cachedMenusEdge = (app.processIdentifier, edge)
        return edge
    }

    private static func measure(pid: pid_t) -> CGFloat? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)   // never hang on a busy app
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBarValue, CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else { return nil }
        let menuBar = unsafeDowncast(menuBarValue, to: AXUIElement.self)
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let items = childrenValue as? [AXUIElement] else { return nil }
        var right: CGFloat = 0
        for item in items {
            guard let frame = frame(of: item), frame.width > 0 else { continue }
            right = max(right, frame.maxX)
        }
        return right > 0 ? right : nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position)
        AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}
