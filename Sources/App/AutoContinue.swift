import SwiftUI
import WatchManCore

extension SessionStore {
    /// When the limit that stopped a session resets: the plan's exact time when it agrees with what Claude Code
    /// said, else Claude Code's own "resets 9pm", else the plan's session reset.
    func limitResetDate(for session: Session) -> Date? {
        let said = RateLimit.resetDate(session.limitReset)
        let windows = [planUsage?.session, planUsage?.week].compactMap { $0?.resetsAt }.filter { $0 > Date() }
        if let said {
            return windows.first { abs($0.timeIntervalSince(said)) < 2 * 3600 } ?? said
        }
        if let week = planUsage?.week, week.percent >= 100, let resets = week.resetsAt, resets > Date() { return resets }
        return planUsage?.session?.resetsAt.flatMap { $0 > Date() ? $0 : nil }
    }

    /// Types "continue" into the session a minute after its limit resets.
    func scheduleContinue(_ id: String) {
        guard let session = sessions[id], session.host.canSend, let reset = limitResetDate(for: session) else { return }
        let at = reset.addingTimeInterval(60)
        scheduledContinues[id] = at
        armContinue(id, at: at)
        pageNote = "Continues at \(at.formatted(date: .omitted, time: .shortened))"
    }

    func cancelContinue(_ id: String) {
        scheduledContinues[id] = nil
        continueTasks.removeValue(forKey: id)?.cancel()
    }

    /// After a restart: the continues still to come.
    func restoreContinues() {
        for (id, at) in scheduledContinues { armContinue(id, at: at) }
    }

    /// One sleep to the moment (on the clock that keeps counting while the Mac sleeps), no polling.
    private func armContinue(_ id: String, at: Date) {
        continueTasks[id]?.cancel()
        continueTasks[id] = Task { [weak self] in
            let wait = max(0, at.timeIntervalSinceNow)
            try? await Task.sleep(until: ContinuousClock.now + .seconds(wait), clock: .continuous)
            guard let self, !Task.isCancelled, self.scheduledContinues[id] != nil else { return }
            self.scheduledContinues[id] = nil
            self.continueTasks[id] = nil
            guard let session = self.sessions[id], session.status != .working else { return }
            if await self.reply("continue", to: id) == nil {
                self.record(.started, "Continued after the usage limit reset", for: session)
            }
        }
    }
}

/// After the usage limit: Continue at the reset time (or Cancel once it's set), Retry when the time isn't known.
struct ContinueAtButton: View {
    let session: Session
    let store: SessionStore
    var tint: Color = Theme.limit

    var body: some View {
        if let at = store.scheduledContinues[session.id] {
            HStack(spacing: 8) {
                Label("Continues at \(at.formatted(date: .omitted, time: .shortened))", systemImage: "clock.badge.checkmark")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(tint)
                Button("Cancel") { store.cancelContinue(session.id) }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.secondary)
            }
        } else if let reset = store.limitResetDate(for: session) {
            PillButton(title: "Continue at \(reset.addingTimeInterval(60).formatted(date: .omitted, time: .shortened))",
                       symbol: "clock.arrow.circlepath", tint: tint) { store.scheduleContinue(session.id) }
                .help("WatchMan types \"continue\" into the session a minute after the limit resets")
        } else {
            PillButton(title: "Retry", symbol: "arrow.clockwise", tint: tint) { store.retry(session.id) }
        }
    }
}
