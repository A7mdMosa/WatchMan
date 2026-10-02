import AppKit
import WatchManCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private var server: HookServer?
    private var notch: NotchController?
    private var menuBar: MenuBarController?
    private var alerts: AlertCenter?
    private let settingsWindow = SettingsWindowController()
    private var mainWindow: MainWindowController?
    private var cloud: CloudPublisher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        HookInstaller.installBinary()
        Log.info("Accessibility \(MenuBarSpace.canReadMenus ? "on" : "off")")

        let notch = NotchController(store: store)
        let alerts = AlertCenter(notch: notch)
        store.onTransition = { session, previous in alerts.sessionChanged(session, from: previous) }
        store.onStuck = { session in alerts.sessionStuck(session) }
        store.onNews = { [weak notch] moment in notch?.tell(moment) }
        self.notch = notch
        self.alerts = alerts
        let menuBar = MenuBarController(store: store, openSettings: { [weak self] in self?.settingsWindow.show() },
                                        openPanel: { [weak notch] in notch?.togglePanel() })
        notch.menuBarLeftEdge = { [weak menuBar] in menuBar?.iconLeftEdge }
        notch.openSettings = { [weak self] in self?.settingsWindow.show() }
        self.menuBar = menuBar

        let store = self.store
        let server = HookServer(handler: { event, responder in store.handle(event, responder: responder) },
                                statusLine: { info in store.applyStatusLine(info) })
        store.seedPlanUsage()
        store.restoreContinues()
        do {
            try server.start()
        } catch {
            Log.info("couldn't open the hook socket: \(error)")
            AppHealth.shared.socketFailed = true
        }
        self.server = server

        ObsidianIndex.shared.refreshIfNeeded()
        store.discover()
        DigestWriter.startSchedule()
        PhoneBridge.shared.store = store
        PhoneBridge.shared.activate()
        Task { await HookInstaller.updateIfOutdated() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.store.releasePrompts(forApp: bundle) }
        }
        // The window: from the panel, the menu bar, the Dock
        let mainWindow = MainWindowController(store: store)
        mainWindow.openSettings = { [weak self] pane in self?.settingsWindow.show(pane: pane) }
        self.mainWindow = mainWindow
        mainWindow.applyDockPolicy(windowOpen: false)
        NotificationCenter.default.addObserver(forName: .watchManOpenWindow, object: nil, queue: .main) { [weak self] note in
            let id = note.object as? String
            MainActor.assumeIsolated {
                NotificationCenter.default.post(name: .watchManCollapse, object: nil)
                self?.mainWindow?.show(session: id)
            }
        }
        NotificationCenter.default.addObserver(forName: .watchManDockPolicyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mainWindow?.applyDockPolicy() }
        }

        if !HookInstaller.hooksInstalled { settingsWindow.show() }
        Task { await UpdateCheck.shared.check() }
        // The link to WatchMan for iPhone, through your private iCloud database
        let cloud = CloudPublisher(store: store)
        CloudPublisher.current = cloud
        self.cloud = cloud
        Task { await cloud.start() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.cloud?.fetchCommands() } }
        }
    }

    /// Clicking the Dock icon opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        mainWindow?.show()
        return false
    }

    /// iCloud's push when you answered something on the phone.
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await cloud?.fetchCommands() }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.info("push registration failed: \(error)")
    }

    /// Right-click on the Dock icon: the sessions that wait or have a new result.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        mainWindow?.dockMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unlink(WatchManPaths.socketPath)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
