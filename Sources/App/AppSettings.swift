import CoreGraphics
import Foundation
import Observation

/// User preferences, saved in UserDefaults.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "soundEnabled") } }
    /// 0…1, for every sound WatchMan plays.
    var soundVolume: Double { didSet { defaults.set(soundVolume, forKey: "soundVolume") } }
    /// The sound for each kind of event (a system sound's name, or "None"), by `SoundEvent.rawValue`.
    var eventSounds: [String: String] { didSet { defaults.set(eventSounds, forKey: "eventSounds") } }
    /// The shortcut that goes through what's waiting: a Carbon key code and modifier mask, and how it reads.
    var hotKeyCode: Int { didSet { defaults.set(hotKeyCode, forKey: "hotKeyCode") } }
    var hotKeyModifiers: Int { didSet { defaults.set(hotKeyModifiers, forKey: "hotKeyModifiers") } }
    var hotKeyLabel: String { didSet { defaults.set(hotKeyLabel, forKey: "hotKeyLabel") } }
    /// When WatchMan shows in the Dock (and ⌘Tab).
    enum DockIcon: String, CaseIterable { case whileOpen = "While the window is open", always = "Always", never = "Never" }
    var dockIcon: DockIcon {
        didSet {
            defaults.set(dockIcon.rawValue, forKey: "dockIcon")
            NotificationCenter.default.post(name: .watchManDockPolicyChanged, object: nil)
        }
    }
    var notchPopEnabled: Bool { didSet { defaults.set(notchPopEnabled, forKey: "notchPopEnabled") } }
    /// Hold permission prompts so they can be answered from WatchMan (only when you're not at that terminal).
    var approvalsEnabled: Bool { didSet { defaults.set(approvalsEnabled, forKey: "approvalsEnabled") } }
    var approvalTimeout: Double { didSet { defaults.set(approvalTimeout, forKey: "approvalTimeout") } }
    var quickReplies: [String] { didSet { defaults.set(quickReplies, forKey: "quickReplies") } }
    var ntfyTopic: String { didSet { defaults.set(ntfyTopic, forKey: "ntfyTopic") } }
    var ntfyIdleMinutes: Double { didSet { defaults.set(ntfyIdleMinutes, forKey: "ntfyIdleMinutes") } }
    /// Optional token budget for the 5-hour block, to show a percentage.
    var blockBudget: Int { didSet { defaults.set(blockBudget, forKey: "blockBudget") } }
    /// How moments that need nothing from you are told (a session started or finished, may be stuck, stopped,
    /// hit the limit, usage passed 80%, you're back): the ball reacts and the line beside the notch says it
    /// (default), plus a short one-line message, or the full message as before.
    enum NewsStyle: String, CaseIterable { case ball = "Just the ball", brief = "A short line", full = "The full message" }
    var newsStyle: NewsStyle { didSet { defaults.set(newsStyle.rawValue, forKey: "newsStyle") } }
    /// Alerts go to WatchMan for iPhone (through iCloud) instead of ntfy, when the iPhone link is on.
    var iphoneAlerts: Bool { didSet { defaults.set(iphoneAlerts, forKey: "iphoneAlerts") } }
    /// Only while you're away from the Mac (idle or locked), like ntfy alerts; off: every time.
    var iphoneAlertsWhenAway: Bool { didSet { defaults.set(iphoneAlertsWhenAway, forKey: "iphoneAlertsWhenAway") } }
    /// Finished turns reach the iPhone too (the default); off: only what needs you, an error or the usage limit.
    /// Work starting or going on never sends an alert: the Live Activity shows it.
    var iphoneFinishedAlerts: Bool { didSet { defaults.set(iphoneFinishedAlerts, forKey: "iphoneFinishedAlerts") } }
    /// A session the usage limit stopped types "continue" by itself once the limit resets.
    var autoContinue: Bool { didSet { defaults.set(autoContinue, forKey: "autoContinue") } }

    // Notch behaviour
    var closeOnClickOutside: Bool { didSet { defaults.set(closeOnClickOutside, forKey: "closeOnClickOutside") } }
    var closeOnMouseLeave: Bool { didSet { defaults.set(closeOnMouseLeave, forKey: "closeOnMouseLeave") } }
    var mouseLeaveDelay: Double { didSet { defaults.set(mouseLeaveDelay, forKey: "mouseLeaveDelay") } }
    var hoverPreview: Bool { didSet { defaults.set(hoverPreview, forKey: "hoverPreview") } }
    var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: "hoverDelay") } }
    /// How many sessions the hover preview lists (1–20).
    var hoverRows: Int { didSet { defaults.set(hoverRows, forKey: "hoverRows") } }
    /// How long the notch stays open after an alert opens it.
    var popDuration: Double { didSet { defaults.set(popDuration, forKey: "popDuration") } }
    /// No sounds or messages until then (seconds since 1970; 0: not quiet).
    var quietUntil: Double { didSet { defaults.set(quietUntil, forKey: "quietUntil") } }
    /// Quiet while a display is mirrored (presenting on a projector).
    var quietWhilePresenting: Bool { didSet { defaults.set(quietWhilePresenting, forKey: "quietWhilePresenting") } }
    var panelWidth: Double { didSet { defaults.set(panelWidth, forKey: "panelWidth") } }
    /// Height of the session list before it scrolls.
    var listHeight: Double { didSet { defaults.set(listHeight, forKey: "listHeight") } }
    // What the closed notch shows
    /// Left of the notch: the orb and what's happening, or only the orb, or nothing.
    enum LeftContent: String, CaseIterable { case automatic = "Activity", ring = "Orb only", nothing = "Nothing" }
    /// Right of the notch: the counts, or nothing.
    enum RightContent: String, CaseIterable { case automatic = "Status", nothing = "Nothing" }
    var notchLeft: LeftContent { didSet { defaults.set(notchLeft.rawValue, forKey: "notchLeft") } }
    var notchRight: RightContent { didSet { defaults.set(notchRight.rawValue, forKey: "notchRight") } }
    /// Show the island on the screen you're working on (else always on the built-in display).
    var followActiveScreen: Bool { didSet { defaults.set(followActiveScreen, forKey: "followActiveScreen") } }

    // Phone buttons
    var phoneActionsEnabled: Bool { didSet { defaults.set(phoneActionsEnabled, forKey: "phoneActionsEnabled") } }
    var ntfyReplyTopic: String { didSet { defaults.set(ntfyReplyTopic, forKey: "ntfyReplyTopic") } }
    /// How long a permission prompt waits for your phone while you're away from the Mac.
    var awayHoldMinutes: Double { didSet { defaults.set(awayHoldMinutes, forKey: "awayHoldMinutes") } }

    // Daily digest
    var digestEnabled: Bool { didSet { defaults.set(digestEnabled, forKey: "digestEnabled") } }
    /// Minutes after midnight.
    var digestMinutes: Int { didSet { defaults.set(digestMinutes, forKey: "digestMinutes") } }
    var digestUsesHaiku: Bool { didSet { defaults.set(digestUsesHaiku, forKey: "digestUsesHaiku") } }
    /// The Obsidian vault's folder; empty: the first vault found in iCloud Drive.
    var obsidianVault: String { didSet { defaults.set(obsidianVault, forKey: "obsidianVault") } }
    /// Where the Dev Log notes go inside the vault.
    var devLogFolder: String { didSet { defaults.set(devLogFolder, forKey: "devLogFolder") } }
    static let defaultDevLogFolder = "00 Journal/Dev Log"

    // Stuck alerts
    var stuckAlertsEnabled: Bool { didSet { defaults.set(stuckAlertsEnabled, forKey: "stuckAlertsEnabled") } }
    var stuckIdleMinutes: Double { didSet { defaults.set(stuckIdleMinutes, forKey: "stuckIdleMinutes") } }
    var stuckRepeatCount: Int { didSet { defaults.set(stuckRepeatCount, forKey: "stuckRepeatCount") } }
    var stuckLongRunMinutes: Double { didSet { defaults.set(stuckLongRunMinutes, forKey: "stuckLongRunMinutes") } }

    /// Hiding it frees menu bar space next to the notch; Settings stays reachable from the notch.
    var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }

    static let widthPresets: [(name: String, width: Double)] = [("S", 500), ("M", 580), ("L", 720), ("XL", 880)]

    /// For projects of no known kind (Flutter, web and Swift projects get their own).
    static let defaultQuickReplies = [
        "continue",
        "yes, go ahead",
        "run the tests",
        "/project-sync",
        "stop and summarize what you did",
    ]

    private init() {
        defaults.register(defaults: [
            "soundEnabled": true,
            "soundVolume": 0.6,
            "eventSounds": [String: String](),
            "hotKeyCode": 49,          // kVK_Space
            "hotKeyModifiers": 2048,   // optionKey
            "hotKeyLabel": "⌥Space",
            "dockIcon": DockIcon.whileOpen.rawValue,
            "notchPopEnabled": true,
            "approvalsEnabled": true,
            "approvalTimeout": 90.0,
            "quickReplies": AppSettings.defaultQuickReplies,
            "ntfyTopic": "",
            "ntfyIdleMinutes": 5.0,
            "blockBudget": 0,
            "iphoneAlerts": true,
            "iphoneAlertsWhenAway": true,
            "iphoneFinishedAlerts": true,
            "closeOnClickOutside": true,
            "closeOnMouseLeave": true,
            "mouseLeaveDelay": 0.8,
            "hoverPreview": true,
            "hoverDelay": 0.25,
            "hoverRows": 3,
            "popDuration": 6.0,
            "quietUntil": 0.0,
            "quietWhilePresenting": true,
            "panelWidth": 580.0,
            "listHeight": 440.0,
            "showMenuBarIcon": true,
            "notchLeft": LeftContent.automatic.rawValue,
            "notchRight": RightContent.automatic.rawValue,
            "followActiveScreen": true,
            "phoneActionsEnabled": true,
            "ntfyReplyTopic": "",
            "awayHoldMinutes": 9.0,
            "digestEnabled": true,
            "digestMinutes": 23 * 60,
            "digestUsesHaiku": true,
            "stuckAlertsEnabled": true,
            "stuckIdleMinutes": 10.0,
            "stuckRepeatCount": 3,
            "stuckLongRunMinutes": 45.0,
        ])
        soundEnabled = defaults.bool(forKey: "soundEnabled")
        soundVolume = defaults.double(forKey: "soundVolume")
        eventSounds = defaults.dictionary(forKey: "eventSounds") as? [String: String] ?? [:]
        hotKeyCode = defaults.integer(forKey: "hotKeyCode")
        hotKeyModifiers = defaults.integer(forKey: "hotKeyModifiers")
        hotKeyLabel = defaults.string(forKey: "hotKeyLabel") ?? "⌥Space"
        dockIcon = DockIcon(rawValue: defaults.string(forKey: "dockIcon") ?? "") ?? .whileOpen
        notchPopEnabled = defaults.bool(forKey: "notchPopEnabled")
        approvalsEnabled = defaults.bool(forKey: "approvalsEnabled")
        approvalTimeout = defaults.double(forKey: "approvalTimeout")
        quickReplies = defaults.stringArray(forKey: "quickReplies") ?? AppSettings.defaultQuickReplies
        ntfyTopic = defaults.string(forKey: "ntfyTopic") ?? ""
        ntfyIdleMinutes = defaults.double(forKey: "ntfyIdleMinutes")
        blockBudget = defaults.integer(forKey: "blockBudget")
        autoContinue = defaults.bool(forKey: "autoContinue")
        newsStyle = NewsStyle(rawValue: defaults.string(forKey: "newsStyle") ?? "") ?? .ball
        iphoneAlerts = defaults.bool(forKey: "iphoneAlerts")
        iphoneAlertsWhenAway = defaults.bool(forKey: "iphoneAlertsWhenAway")
        iphoneFinishedAlerts = defaults.bool(forKey: "iphoneFinishedAlerts")
        closeOnClickOutside = defaults.bool(forKey: "closeOnClickOutside")
        closeOnMouseLeave = defaults.bool(forKey: "closeOnMouseLeave")
        mouseLeaveDelay = defaults.double(forKey: "mouseLeaveDelay")
        hoverPreview = defaults.bool(forKey: "hoverPreview")
        hoverDelay = defaults.double(forKey: "hoverDelay")
        hoverRows = defaults.integer(forKey: "hoverRows")
        popDuration = defaults.double(forKey: "popDuration")
        quietUntil = defaults.double(forKey: "quietUntil")
        quietWhilePresenting = defaults.bool(forKey: "quietWhilePresenting")
        panelWidth = defaults.double(forKey: "panelWidth")
        listHeight = defaults.double(forKey: "listHeight")
        showMenuBarIcon = defaults.bool(forKey: "showMenuBarIcon")
        notchLeft = LeftContent(rawValue: defaults.string(forKey: "notchLeft") ?? "") ?? .automatic
        notchRight = RightContent(rawValue: defaults.string(forKey: "notchRight") ?? "") ?? .automatic
        followActiveScreen = defaults.bool(forKey: "followActiveScreen")
        phoneActionsEnabled = defaults.bool(forKey: "phoneActionsEnabled")
        ntfyReplyTopic = defaults.string(forKey: "ntfyReplyTopic") ?? ""
        awayHoldMinutes = defaults.double(forKey: "awayHoldMinutes")
        digestEnabled = defaults.bool(forKey: "digestEnabled")
        digestMinutes = defaults.integer(forKey: "digestMinutes")
        digestUsesHaiku = defaults.bool(forKey: "digestUsesHaiku")
        obsidianVault = defaults.string(forKey: "obsidianVault") ?? ""
        devLogFolder = defaults.string(forKey: "devLogFolder") ?? AppSettings.defaultDevLogFolder
        stuckAlertsEnabled = defaults.bool(forKey: "stuckAlertsEnabled")
        stuckIdleMinutes = defaults.double(forKey: "stuckIdleMinutes")
        stuckRepeatCount = defaults.integer(forKey: "stuckRepeatCount")
        stuckLongRunMinutes = defaults.double(forKey: "stuckLongRunMinutes")
    }
}

/// Quiet: no sounds and no messages under the notch (the notch itself still shows what needs you).
@MainActor
enum Quiet {
    static var isOn: Bool {
        let settings = AppSettings.shared
        if silenced { return true }
        return settings.quietWhilePresenting && presenting
    }

    /// Quiet for a while (an hour, until morning), which keeps the iPhone quiet too. Presenting keeps only the
    /// Mac quiet: then the phone is where alerts belong.
    static var silenced: Bool { AppSettings.shared.quietUntil > Date().timeIntervalSince1970 }

    /// A display is mirroring another: usually a projector or a screen share in class.
    static var presenting: Bool {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        guard CGGetActiveDisplayList(8, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsInMirrorSet($0) != 0 }
    }

    static func silence(for seconds: Double) {
        AppSettings.shared.quietUntil = Date().addingTimeInterval(seconds).timeIntervalSince1970
    }

    static func untilTomorrow() {
        let tomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(24 * 3600)).addingTimeInterval(8 * 3600)
        AppSettings.shared.quietUntil = tomorrow.timeIntervalSince1970
    }

    static func end() { AppSettings.shared.quietUntil = 0 }
}

extension Notification.Name {
    static let watchManDockPolicyChanged = Notification.Name("watchManDockPolicyChanged")
}
