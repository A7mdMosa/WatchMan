#if os(iOS)
import AppIntents
import CloudKit
import WatchManCore

/// Allow a permission or approve a plan from the Live Activity. Face ID first, as on the alert, so nobody runs a
/// command from your lock screen.
struct AllowIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Allow"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Session") var sessionId: String
    /// When the prompt came (seconds since 1970; 0 when unknown), so Allow can't reach the next prompt.
    @Parameter(title: "Prompt") var asked: Double

    init() {}
    init(sessionId: String, asked: Date?) {
        self.sessionId = sessionId
        self.asked = asked?.timeIntervalSince1970 ?? 0
    }

    func perform() async throws -> some IntentResult {
        try await PromptAnswer.send(.allow, to: sessionId, asked: asked > 0 ? Date(timeIntervalSince1970: asked) : nil)
        return .result()
    }
}

/// Deny, Keep Planning, or one of a question's choices, from the Live Activity.
struct AnswerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer"
    static let isDiscoverable = false

    @Parameter(title: "Session") var sessionId: String
    /// The choice's place in the question; -1 for Deny or Keep Planning.
    @Parameter(title: "Choice") var choice: Int
    /// When the prompt came (seconds since 1970; 0 when unknown).
    @Parameter(title: "Prompt") var asked: Double

    init() {}
    init(sessionId: String, choice: Int, asked: Date?) {
        self.sessionId = sessionId
        self.choice = choice
        self.asked = asked?.timeIntervalSince1970 ?? 0
    }

    func perform() async throws -> some IntentResult {
        try await PromptAnswer.send(choice >= 0 ? .pick(choice) : .deny(message: nil), to: sessionId,
                                    asked: asked > 0 ? Date(timeIntervalSince1970: asked) : nil)
        return .result()
    }
}

/// Continue after the usage limit, or retry after an error, from the Live Activity.
struct SessionActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Session Action"
    static let isDiscoverable = false

    @Parameter(title: "Session") var sessionId: String
    /// "continue" or "retry".
    @Parameter(title: "Action") var action: String

    init() {}
    init(sessionId: String, action: String) {
        self.sessionId = sessionId
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        try await PromptAnswer.send(action == "retry" ? .mac(.retry) : .continueAfterLimit, to: sessionId, asked: nil)
        return .result()
    }
}

/// An answer from outside the app's pages: left in iCloud for the Mac, and shown as sent on the Live Activity.
/// The intents run in the app's process, which holds the iCloud link.
enum PromptAnswer {
    static func send(_ kind: PhoneCommand.Kind, to sessionId: String, asked: Date?) async throws {
        let command = PhoneCommand(sessionId: sessionId, kind: kind, prompt: asked)
        let record = try CloudRecords.record(CloudRecords.Kind.command, name: command.id.uuidString, command)
        _ = try await CloudRecords.container.privateCloudDatabase.save(record)
        await WatchManActivity.markSent(sessionId)
    }
}
#endif
