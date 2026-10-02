import ActivityKit
import UIKit
import UserNotifications
import WatchManCore
import WidgetKit

/// Everything outside the app's pages that shows the sessions: the widgets, the Live Activity, the app icon's
/// count, and the alerts already on the lock screen. Brought up to date each time the app hears from the Mac.
@MainActor
enum PhoneGlance {
    /// What the widgets showed last, and when the Mac said it.
    private static var shown: (glance: Glance, updated: Date)?

    static func update(_ state: PhoneState) async {
        // When the Mac last said anything: a session's change, or the status (which changes only with the usage)
        let updated = ([state.updated] + state.sessions.map(\.updated)).max() ?? state.updated
        let glance = Glance(sessions: state.sessions, usage: state.usage, macName: state.macName, updated: updated)
        GlanceStore.save(glance)
        // iOS gives the widgets a few dozen reloads a day: only when what they show changed, or to say how old it is
        let visible = glance.withoutTimes
        if visible != shown?.glance || glance.updated.timeIntervalSince(shown?.updated ?? .distantPast) > 10 * 60 {
            shown = (visible, glance.updated)
            WidgetCenter.shared.reloadAllTimelines()
        }
        await LiveActivity.update(glance)
        try? await UNUserNotificationCenter.current().setBadgeCount(glance.waiting.count)
        await StaleAlerts.remove(glance)
    }
}

/// The one Live Activity for all sessions. It starts when the app is open while something works or waits (the
/// Mac can't start it remotely without Apple's push service), follows every change the app hears about, and ends
/// once nothing works or waits, its last word staying on the lock screen for ten minutes.
@MainActor
enum LiveActivity {
    static let quietEnd: TimeInterval = 10 * 60

    static func update(_ glance: Glance) async {
        guard PhoneSettings.liveActivity, ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endAll()
            return
        }
        // Ended ones stay in the list a while (iOS also ends them after eight hours): only a live one counts
        var live: [Activity<WatchManActivity>] = []
        for activity in Activity<WatchManActivity>.activities where [.active, .stale].contains(activity.activityState) {
            live.append(activity)
        }
        for extra in live.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
        let current = live.first
        let previous = current?.content.state
        var state = LiveGlance(glance, sentFor: previous?.sentFor, sentPrompt: previous?.sentPrompt,
                               quietSince: glance.busy ? nil : Date())
        state.plainIsland = PhoneSettings.dynamicIsland ? nil : true
        let content = ActivityContent(state: state, staleDate: nil)
        if let current {
            if !glance.busy {
                await current.end(content, dismissalPolicy: .after(Date().addingTimeInterval(quietEnd)))
            } else if state != previous {
                await current.update(content)
            }
        } else if glance.busy, UIApplication.shared.applicationState == .active {
            // A finished one still showing makes way for the new one
            for ended in Activity<WatchManActivity>.activities { await ended.end(nil, dismissalPolicy: .immediate) }
            _ = try? Activity.request(attributes: WatchManActivity(), content: content)
        }
    }

    static func endAll() async {
        for activity in Activity<WatchManActivity>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}

/// Takes alerts off the lock screen once they're out of date: a prompt answered (here or on the Mac), a result
/// you've seen, a session that has moved on or ended.
@MainActor
enum StaleAlerts {
    static func remove(_ glance: Glance) async {
        let center = UNUserNotificationCenter.current()
        let sessions = Dictionary(glance.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stale = await center.deliveredNotifications().filter { alert in
            let content = alert.request.content
            guard let id = PhoneAlertCategory.sessionId(of: content), id != "test" else { return false }
            // Gone: ended (a brand-new session's record can come a little after its first alert)
            guard let session = sessions[id] else { return Date().timeIntervalSince(alert.date) > 120 }
            // Only what the Mac said after the alert counts: the alert can arrive before the session's change
            guard session.updated > alert.date else { return false }
            if PhoneAlertCategory.prompts.contains(content.categoryIdentifier) {
                // Answered, or replaced by another prompt (which may have come without an alert)
                guard let prompt = session.prompt else { return true }
                guard let asked = PhoneAlertCategory.asked(of: content), let current = prompt.asked else { return false }
                return abs(current.timeIntervalSince(asked)) > 0.5
            }
            // A note: the session changed since it came (unless it still waits on you), or its result was seen
            if session.state == .done, !session.unseen { return true }
            return alert.date < session.since && !session.waiting
        }
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale.map(\.request.identifier)) }
    }

    /// A session's alerts, once its page is open.
    static func clear(_ sessionId: String) async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.deliveredNotifications()
            .filter { PhoneAlertCategory.sessionId(of: $0.request.content) == sessionId }
            .map(\.request.identifier)
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }
}

