import Foundation

// MARK: - Queued follow-ups

/// When a message queued with "Send when done" may be typed into its session.
public enum FollowUpRule {
    /// Only right after a normal finish: never after an error stop, never while a permission prompt waits.
    public static func shouldSend(afterEvent event: String, status: SessionStatus, hasPendingPrompt: Bool,
                                  canSend: Bool) -> Bool {
        event == "Stop" && status == .finished && !hasPendingPrompt && canSend
    }
}

// MARK: - Stuck sessions

public enum StuckReason: Equatable, Sendable {
    case repeatingFailure(String)     // the same tool call keeps failing
    case noActivity(minutes: Int)     // working, but no hook event for a while
    case longRun(minutes: Int)        // working for a long time

    public var text: String {
        switch self {
        case .repeatingFailure(let step): "Repeating a failing step: \(step)"
        case .noActivity(let minutes): "No activity for \(minutes) min"
        case .longRun(let minutes): "Running for \(minutes) min"
        }
    }

    /// Same kind, ignoring the numbers (so a dismissal holds while the minutes grow).
    public func sameKind(as other: StuckReason) -> Bool {
        switch (self, other) {
        case (.repeatingFailure, .repeatingFailure), (.noActivity, .noActivity), (.longRun, .longRun): true
        default: false
        }
    }
}

public struct StuckThresholds: Sendable, Equatable {
    public var noActivityMinutes: Double
    public var repeatCount: Int
    public var longRunMinutes: Double

    public init(noActivityMinutes: Double = 10, repeatCount: Int = 3, longRunMinutes: Double = 45) {
        self.noActivityMinutes = noActivityMinutes
        self.repeatCount = repeatCount
        self.longRunMinutes = longRunMinutes
    }
}

public enum StuckDetector {
    /// The most serious reason a working session looks stuck, or nil.
    public static func check(_ session: Session, now: Date, thresholds: StuckThresholds) -> StuckReason? {
        guard session.status == .working else { return nil }
        if session.failureCount >= thresholds.repeatCount, let step = session.failureStep {
            return .repeatingFailure(step)
        }
        let idle = now.timeIntervalSince(session.lastActivity) / 60
        if idle >= thresholds.noActivityMinutes { return .noActivity(minutes: Int(idle)) }
        let running = now.timeIntervalSince(session.statusSince) / 60
        if running >= thresholds.longRunMinutes { return .longRun(minutes: Int(running)) }
        return nil
    }
}

// MARK: - Project kinds

/// What a project is, for sensible defaults (quick replies, starters).
public enum ProjectKind: String, Sendable {
    case flutter, web, swift, other

    public static func detect(root: String, fileExists: (String) -> Bool) -> ProjectKind {
        func has(_ name: String) -> Bool { fileExists((root as NSString).appendingPathComponent(name)) }
        if has("pubspec.yaml") { return .flutter }
        if has("package.json") { return .web }
        if has("Package.swift") || has("project.yml") { return .swift }
        return .other
    }

    public var defaultQuickReplies: [String]? {
        switch self {
        case .flutter: ["continue", "yes, go ahead", "run flutter analyze and flutter test", "/project-sync",
                        "stop and summarize what you did"]
        case .web: ["continue", "yes, go ahead", "run the tests", "npm run build", "/project-sync"]
        case .swift: ["continue", "yes, go ahead", "build and run the tests", "commit and push", "/project-sync"]
        case .other: nil
        }
    }

    public var defaultStarters: [String]? {
        switch self {
        case .flutter: ["/app-audit", "/project-sync", "/code-review", "/flutter-improve-design"]
        case .web: ["/project-sync", "/code-review", "/web-design-guidelines"]
        case .swift: ["/code-review", "/project-sync", "/simplify"]
        case .other: nil
        }
    }
}
