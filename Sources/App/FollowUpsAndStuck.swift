import Foundation
import WatchManCore

extension SessionStore {
    // MARK: - Queued follow-ups

    func enqueueFollowUp(_ text: String, for id: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        followUps[id, default: []].append(message)
        showFeedback("Queued", for: id)
    }

    func removeFollowUp(at index: Int, for id: String) {
        guard var queue = followUps[id], queue.indices.contains(index) else { return }
        queue.remove(at: index)
        followUps[id] = queue.isEmpty ? nil : queue
    }

    /// Types the first queued message once Claude is back at its prompt.
    func sendNextFollowUp(_ id: String) {
        Task {
            // Give Claude a moment to return to its input prompt
            try? await Task.sleep(for: .milliseconds(1200))
            guard let session = sessions[id], let message = followUps[id]?.first,
                  FollowUpRule.shouldSend(afterEvent: "Stop", status: session.status,
                                          hasPendingPrompt: session.pendingApproval != nil,
                                          canSend: session.host.canSend) else { return }
            if let error = await Hosts.send(message, to: session) {
                Log.info("queued message for \(session.displayName) not sent: \(error)")
                return
            }
            removeFollowUp(at: 0, for: id)
            showFeedback("Sent queued", for: id)
        }
    }

    // MARK: - Stuck sessions

    var stuckThresholds: StuckThresholds {
        let settings = AppSettings.shared
        return StuckThresholds(noActivityMinutes: settings.stuckIdleMinutes, repeatCount: settings.stuckRepeatCount,
                               longRunMinutes: settings.stuckLongRunMinutes)
    }

    /// Checks working sessions once a minute; stops by itself when nothing is working.
    func startStuckChecks() {
        guard AppSettings.shared.stuckAlertsEnabled, stuckTask == nil else { return }
        stuckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                if !self.checkStuck() {
                    self.stuckTask = nil
                    return
                }
            }
        }
    }

    /// Returns whether any session is still working (so checks should continue).
    @discardableResult
    func checkStuck(now: Date = Date()) -> Bool {
        var anyWorking = false
        for session in sessions.values where session.status == .working && session.continuedIn == nil {
            anyWorking = true
            let reason = StuckDetector.check(session, now: now, thresholds: stuckThresholds)
            if let dismissed = dismissedStuck[session.id], let reason, dismissed.sameKind(as: reason) { continue }
            guard reason != session.stuck else { continue }
            var updated = session
            // Alert only when it starts looking stuck, or the reason changes kind (not as minutes grow)
            let isNew = reason.map { new in !(session.stuck?.sameKind(as: new) ?? false) } ?? false
            updated.stuck = reason
            setSession(updated)
            if isNew, reason != nil { onStuck?(updated) }
        }
        return anyWorking
    }

    func dismissStuck(_ id: String) {
        guard var session = sessions[id], let reason = session.stuck else { return }
        dismissedStuck[id] = reason
        session.stuck = nil
        setSession(session)
    }
}
