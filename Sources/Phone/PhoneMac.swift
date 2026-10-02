import SwiftUI
import WatchManCore

/// Asking the Mac for things beyond prompts and replies: its settings, new sessions, earlier chats, the System page.
extension PhoneStore {
    var extras: MacExtras? { state.extras }

    /// Sends a command, then reads again a few times while the Mac carries it out (in case iCloud's push is late).
    func ask(_ command: MacCommand, session: String = "", followUp: Bool = true) async {
        await send(.mac(command), to: session)
        guard followUp else { return }
        for wait in [1.5, 3.0, 6.0] {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    /// The Mac's last word on what the phone asked, while it's fresh.
    var macNote: MacNote? {
        guard let note = extras?.note, Date().timeIntervalSince(note.at) < 90 else { return nil }
        return note
    }
}

/// Where the plan is heading at today's pace, the way the Mac's Overview says it.
enum PhoneForecast {
    static func text(_ plan: PlanUsage, now: Date = Date()) -> (text: String, warn: Bool)? {
        if let session = plan.session, let out = UsageForecast.runsOut(session, length: UsageForecast.sessionLength, now: now) {
            return ("At this pace the session runs out at \(out.formatted(date: .omitted, time: .shortened))", true)
        }
        guard let week = plan.week else { return nil }
        if let out = UsageForecast.runsOut(week, length: UsageForecast.weekLength, now: now) {
            return ("At this pace the week runs out \(out.formatted(.dateTime.weekday(.wide).hour().minute()))", true)
        }
        if let end = UsageForecast.percentAtReset(week, length: UsageForecast.weekLength, now: now) {
            return ("On pace for about \(Int(min(99, end)))% of the week", false)
        }
        return nil
    }
}

/// The Mac's last word ("Started Claude in Trailmap"), under the screen that asked.
struct MacNoteLine: View {
    let store: PhoneStore

    var body: some View {
        if let note = store.macNote {
            Label(note.text, systemImage: "desktopcomputer")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .transition(.opacity)
        }
    }
}

/// "Waiting for your Mac…" while a list the phone asked for hasn't come yet.
struct WaitingForMac: View {
    var text = "Asking your Mac…"

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }
}

/// "today", "in 3 days", "2 days late", like the Mac's To-dos.
struct DueText: View {
    let due: Date

    var body: some View {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                   to: Calendar.current.startOfDay(for: due)).day ?? 0
        let text = days == 0 ? "today" : days == 1 ? "tomorrow" : days > 1 ? "in \(days) days"
            : days == -1 ? "1 day late" : "\(-days) days late"
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(days < 0 ? PhoneTheme.failed : days == 0 ? PhoneTheme.needsYou : .secondary)
    }
}
