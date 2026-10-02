#if os(iOS)
import ActivityKit
import Foundation
import WatchManCore

/// The Live Activity: one for all sessions, on the lock screen and in the Dynamic Island.
struct WatchManActivity: ActivityAttributes, Sendable {
    typealias ContentState = LiveGlance
}

extension WatchManActivity {
    /// Shows "Sent to your Mac" in place of the buttons once you answer a session's prompt (from the activity, an
    /// alert or the app), until the Mac catches up.
    static func markSent(_ sessionId: String) async {
        for activity in Activity<WatchManActivity>.activities {
            var state = activity.content.state
            guard state.focus?.id == sessionId, let prompt = state.focus?.prompt, !state.answered else { continue }
            state.sentFor = sessionId
            state.sentPrompt = prompt.key
            await activity.update(ActivityContent(state: state, staleDate: activity.content.staleDate))
        }
    }
}
#endif
