import AppKit
import WatchManCore

/// What happens when a session finishes or starts needing you.
@MainActor
final class AlertCenter {
    private let notch: NotchController

    init(notch: NotchController) {
        self.notch = notch
    }

    func sessionChanged(_ session: Session, from previous: SessionStatus) {
        // A muted project tells you nothing (the notch still shows it)
        if ProjectSettings.shared.isMuted(session.projectRoot) { return }
        Task {
            // You're already looking at that session: nothing to tell you. Another tab of the same app still gets told
            let looking = await Hosts.isInFront(session)
            // Changed again meanwhile: that change brings its own alert
            guard let now = notch.session(session.id), now.status.sameKind(as: session.status) else { return }
            alert(now, looking: looking)
        }
    }

    private func alert(_ session: Session, looking: Bool) {
        let settings = AppSettings.shared
        let needsYou = session.status.isNeedsYou
        // Quiet hours keep sounds and messages off
        if !looking, !Quiet.isOn {
            let event: SoundEvent = session.rateLimited ? .limit : session.failed ? .error
                : session.asksPermission ? .permission : needsYou ? .question : .finished
            Sounds.play(event, project: session.projectRoot)
            if settings.notchPopEnabled {
                // A message below the notch says what happened; the notch itself doesn't open
                if session.rateLimited {
                    notch.tell(.limit(session))
                } else if session.failed {
                    notch.tell(.error(session))
                } else if let approval = session.pendingApproval {
                    notch.showToast(.permission(approval: approval), for: session, seconds: 20)
                } else if case .needsYou(let reason) = session.status {
                    let answers = session.lastReply.flatMap { ClosingQuestion.find(in: $0) }?.answers ?? []
                    notch.showToast(.question(text: reason, answers: answers), for: session, seconds: 20)
                } else {
                    // Finished needs nothing from you: by default the ball celebrates and the text beside the notch
                    // says so; the result waits in the list as New
                    notch.tell(.finished(session))
                }
            }
        }
        PhoneAlerts.route(session: session)
    }

    /// A session started looking stuck.
    func sessionStuck(_ session: Session) {
        if ProjectSettings.shared.isMuted(session.projectRoot) { return }
        Task {
            let looking = await Hosts.isInFront(session)
            guard let now = notch.session(session.id), now.stuck != nil else { return }
            alertStuck(now, looking: looking)
        }
    }

    private func alertStuck(_ session: Session, looking: Bool) {
        let settings = AppSettings.shared
        if !looking, !Quiet.isOn {
            Sounds.play(.stuck)
            if settings.notchPopEnabled {
                notch.tell(.stuck(session))
            }
        }
        PhoneAlerts.route(session: session, title: "\(session.label) may be stuck", message: session.stuck?.text ?? "")
    }
}

/// Push to your phone through ntfy (https://ntfy.sh) when you're away from the Mac.
@MainActor
enum PhoneAlerts {
    /// To WatchMan for iPhone when it's linked (and you're away, unless set to always), else to ntfy.
    static func route(session: Session, title: String? = nil, message: String? = nil) {
        let settings = AppSettings.shared
        // Quiet for a while means the phone too, however it would get there
        guard !Quiet.silenced else { return }
        if settings.iphoneAlerts, let cloud = CloudPublisher.current, cloud.isOn {
            guard !settings.iphoneAlertsWhenAway || isAway(minutes: settings.ntfyIdleMinutes) else { return }
            // A finished turn comes unless switched off (an error or the usage limit always comes)
            let finished = title == nil && !session.status.isNeedsYou && !session.failed && !session.rateLimited
            guard !finished || settings.iphoneFinishedAlerts else { return }
            cloud.alert(session, title: title, message: message)
        } else {
            sendIfAway(session: session, title: title, message: message)
        }
    }

    static func sendIfAway(session: Session, title: String? = nil, message: String? = nil) {
        let settings = AppSettings.shared
        let topic = settings.ntfyTopic.trimmingCharacters(in: .whitespaces)
        guard !topic.isEmpty, isAway(minutes: settings.ntfyIdleMinutes) else { return }
        let defaultTitle = session.failed ? "\(session.label) stopped with an error"
            : session.status.isNeedsYou ? "\(session.label) needs you" : "\(session.label) finished"
        let text = message ?? (session.status == .finished ? session.replyPreview?.components(separatedBy: "\n").first : nil)
            ?? session.statusText
        send(topic: topic, title: title ?? defaultTitle, message: text, actions: PhoneBridge.shared.buttons(for: session))
    }

    /// Publishes through ntfy's JSON API (so action buttons need no header escaping).
    static func send(topic: String, title: String, message: String, tags: [String] = ["robot"],
                     actions: [[String: Any]] = []) {
        var payload: [String: Any] = ["topic": topic, "title": title, "message": String(message.prefix(300)), "tags": tags]
        if !actions.isEmpty { payload["actions"] = actions }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: URL(string: "https://ntfy.sh/")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request).resume()
    }

    /// No keyboard or mouse input for a while, or the screen is locked.
    static func isAway(minutes: Double) -> Bool {
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return locked || idle >= minutes * 60
    }
}
