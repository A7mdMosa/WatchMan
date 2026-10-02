import Foundation
import Observation
import WatchManCore

/// Two-way phone alerts through ntfy: alerts carry Allow / Deny / Continue buttons that post
/// `kind:session:code` to a secret reply topic, which WatchMan listens to. A code works once,
/// for 10 minutes, and only for the exact prompt or finished state its alert was about.
@MainActor
final class PhoneBridge {
    static let shared = PhoneBridge()

    weak var store: SessionStore?
    private var codes = PhoneCodes(lifetime: 600)
    private var listener: Task<Void, Never>?
    private var restart: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 150      // ntfy sends a keepalive every 45 s
        config.timeoutIntervalForResource = .infinity
        return URLSession(configuration: config)
    }()

    private var settings: AppSettings { AppSettings.shared }

    var enabled: Bool { settings.phoneActionsEnabled && !settings.ntfyTopic.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The secret topic the phone's buttons post to ("" until phone buttons first start).
    var replyTopic: String { settings.ntfyReplyTopic }

    private static func newReplyTopic(base: String) -> String {
        "\(base.isEmpty ? "watchman" : base)-reply-\(PhoneCodes.randomCode().prefix(16))"
    }

    func regenerateReplyTopic() {
        settings.ntfyReplyTopic = Self.newReplyTopic(base: settings.ntfyTopic.trimmingCharacters(in: .whitespaces))
        start()
    }

    /// Starts listening, and restarts by itself whenever the topic or the switch changes in Settings.
    func activate() {
        start()
        observeSettings()
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.ntfyTopic
            _ = settings.phoneActionsEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Typing a topic changes it on every key: restart once it settles
                self.restart?.cancel()
                self.restart = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    self?.start()
                }
                self.observeSettings()
            }
        }
    }

    /// (Re)starts the one listener for button presses, if phone buttons are on.
    func start() {
        listener?.cancel()
        listener = nil
        guard enabled else { return }
        if settings.ntfyReplyTopic.isEmpty {
            settings.ntfyReplyTopic = Self.newReplyTopic(base: settings.ntfyTopic.trimmingCharacters(in: .whitespaces))
        }
        guard let url = URL(string: "https://ntfy.sh/\(replyTopic)/json") else { return }
        listener = Task { [weak self] in
            var delay = 2.0
            while !Task.isCancelled {
                do {
                    guard let session = self?.session else { return }
                    let (bytes, _) = try await session.bytes(from: url)
                    delay = 2
                    for try await line in bytes.lines {
                        if Task.isCancelled { return }
                        self?.handle(line)
                    }
                } catch {
                    if Task.isCancelled { return }
                }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 60)
            }
        }
    }

    /// Buttons for this session's alert: Allow/Deny while WatchMan holds its permission prompt,
    /// Continue when it finished or looks stuck and can be typed into.
    func buttons(for session: Session) -> [[String: Any]] {
        guard enabled, let store, !replyTopic.isEmpty else { return [] }
        let kinds: [PhoneAction.Kind]
        if store.hasPendingPrompt(session.id) {
            // Claude's questions are answered with a choice, not Allow (which Claude Code would treat as no)
            if session.pendingApproval?.isQuestion == true { return [] }
            kinds = [.allow, .deny]
        } else if store.phoneScope(for: session.id, kind: .proceed) != nil {
            kinds = [.proceed]
        } else {
            return []
        }
        guard let scope = store.phoneScope(for: session.id, kind: kinds[0]) else { return [] }
        let code = codes.issue(sessionId: session.id, kinds: Set(kinds), scope: scope, now: Date())
        let topicURL = "https://ntfy.sh/\(replyTopic)"
        return kinds.map { kind in
            [
                "action": "http",
                "label": kind == .allow ? "Allow" : kind == .deny ? "Deny" : "Continue",
                "url": topicURL,
                "method": "POST",
                "body": PhoneAction(kind: kind, sessionId: session.id, code: code).body,
                "clear": true,
            ]
        }
    }

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              event["event"] as? String == "message", let text = event["message"] as? String,
              let action = PhoneAction.parse(text), let store else { return }
        // The code must still match what the alert was about: the same held prompt, or the same finished state
        let scope = store.phoneScope(for: action.sessionId, kind: action.kind)
        let result = codes.redeem(action, currentScope: scope, now: Date())
        guard result == .accepted, let session = store.sessions[action.sessionId] else {
            // Only a genuine but outdated button gets a reply; forged or replayed ones are ignored silently
            if result == .outOfDate, let name = store.sessions[action.sessionId]?.displayName {
                confirm("\(name): that alert is out of date, nothing was done")
            }
            Log.info("ignored a phone action (\(result))")
            return
        }
        switch action.kind {
        case .allow, .deny:
            store.respond(to: session.id, with: action.kind == .allow ? .allow : .deny)
            confirm("\(action.kind == .allow ? "Allowed" : "Denied") · \(session.displayName)")
        case .proceed:
            Task {
                let error = await store.reply("continue", to: session.id)
                confirm(error.map { "\(session.displayName): \($0)" } ?? "Sent \"continue\" · \(session.displayName)")
            }
        }
    }

    /// A short, button-less note back to the phone so you know what happened.
    private func confirm(_ text: String) {
        let topic = settings.ntfyTopic.trimmingCharacters(in: .whitespaces)
        guard !topic.isEmpty else { return }
        PhoneAlerts.send(topic: topic, title: "WatchMan", message: text, tags: ["white_check_mark"])
    }
}
