import SwiftUI
import WatchManCore

// The widgets' and the Live Activity's faces, as plain views (the Mac's design snapshots render them too).

/// "now", "8m", "2h", "3d": how long a session has been in its state.
enum Elapsed {
    static func short(_ since: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
}

/// "2 need you · 3 working · 1 new", or "Nothing running".
enum GlanceText {
    static func counts(waiting: Int, working: Int, new: Int) -> String {
        var parts: [String] = []
        if waiting > 0 { parts.append(waiting == 1 ? "1 needs you" : "\(waiting) need you") }
        if working > 0 { parts.append("\(working) working") }
        if new > 0 { parts.append("\(new) new") }
        return parts.isEmpty ? "Nothing running" : parts.joined(separator: " · ")
    }

    static func counts(_ glance: Glance) -> String {
        counts(waiting: glance.waiting.count, working: glance.working.count, new: glance.newResults.count)
    }
}

/// A session's state in a word or two: its symbol and how long, or "New" for a result not read yet.
struct SessionMark: View {
    let session: Glance.Session
    let now: Date

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(session.state == .done && session.unseen ? "New" : Elapsed.short(session.since, now: now))
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(session.state == .done && !session.unseen ? .secondary : PhoneTheme.color(session.state))
    }

    private var symbol: String {
        switch session.state {
        case .needsYou:
            session.prompt?.kind == .question ? "questionmark.bubble.fill"
                : session.prompt?.kind == .plan ? "list.bullet.clipboard.fill" : "hand.raised.fill"
        case .working: "circle.fill"
        case .done: session.unseen ? "circle.fill" : "checkmark"
        case .idle: "moon.fill"
        case .limited: "hourglass"
        case .failed: "xmark.octagon.fill"
        }
    }
}

/// The usage windows' own colours, the same in every widget: blue for the session, green for the week.
enum UsageColor {
    static let session = PhoneTheme.unseen
    static let week = PhoneTheme.working
}

/// A usage window as a ring in its colour, with its percent inside and its name below.
struct GlanceRing: View {
    let label: String
    let percent: Double?
    let color: Color
    var size: CGFloat = 40

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: size * 0.1)
                Circle().trim(from: 0, to: min(1, (percent ?? 0) / 100))
                    .stroke(color, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(percent.map { "\(Int($0))" } ?? "–")
                    .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
            }
            .frame(width: size, height: size)
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) usage \(percent.map { "\(Int($0)) percent" } ?? "unknown")")
    }
}

/// Both usage windows as one ring inside another, without words: the week outside in green, the session inside in
/// blue (the small widget).
struct UsageRings: View {
    let session: Double?
    let week: Double?
    var size: CGFloat = 46

    var body: some View {
        let line = size * 0.12
        ZStack {
            ring(week, color: UsageColor.week, line: line)
            ring(session, color: UsageColor.session, line: line)
                .padding(line * 1.45)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session usage \(session.map { "\(Int($0)) percent" } ?? "unknown"), week usage \(week.map { "\(Int($0)) percent" } ?? "unknown")")
    }

    private func ring(_ percent: Double?, color: Color, line: CGFloat) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: line)
            Circle().trim(from: 0, to: min(1, (percent ?? 0) / 100))
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(line / 2)
    }
}

/// A step the way the terminal writes it: "Edit" in the state's colour, then the file or command.
struct StepLine: View {
    let text: String
    var color: Color = PhoneTheme.working

    var body: some View {
        let parts = text.components(separatedBy: " · ")
        if parts.count >= 2 {
            (Text(parts[0] + " ").foregroundStyle(color) + Text(parts.dropFirst().joined(separator: " · ")).foregroundStyle(.secondary))
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
        } else {
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// The dark card behind the home screen widgets.
struct WidgetBackdrop: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.10, green: 0.10, blue: 0.15), Color(red: 0.05, green: 0.05, blue: 0.08)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// A small action at the top right: a link (it opens the session) or an intent (it acts without opening).
struct ActionCapsule: View {
    enum Target { case link(URL), sessionAction(String, String) }
    let title: String
    let target: Target

    var body: some View {
        switch target {
        case .link(let url):
            Link(destination: url) { label }
        case .sessionAction(let sessionId, let action):
            #if os(iOS)
            Button(intent: SessionActionIntent(sessionId: sessionId, action: action)) { label }.buttonStyle(.plain)
            #else
            label
            #endif
        }
    }

    private var label: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            // Never broken onto two lines: the capsule takes the width its word needs
            .fixedSize()
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.16), in: Capsule())
    }
}

// MARK: - Home screen widgets

/// Small: the icon's face, the session and week usage, how many need you (or all clear), the session it's about,
/// and what's working.
struct SmallGlanceView: View {
    let glance: Glance?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                IconFace(size: 46)
                Spacer(minLength: 0)
                UsageRings(session: glance?.sessionPercent, week: glance?.weekPercent, size: 46)
            }
            Spacer(minLength: 6)
            if let glance {
                let waiting = glance.waiting.count
                if waiting > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(waiting)").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(PhoneTheme.needsYou)
                        Text(waiting == 1 ? "needs you" : "need you").font(.subheadline.weight(.semibold))
                    }
                } else {
                    Text("All clear").font(.system(size: 21, weight: .bold, design: .rounded)).foregroundStyle(PhoneTheme.working)
                }
                if let focus = glance.focus {
                    // "Lumen wants to run", "Trailmap · Edit"
                    let step = focus.detail.components(separatedBy: " · ").first ?? ""
                    Text(focus.prompt?.heading ?? (focus.state == .working && !step.isEmpty && step.count <= 12
                                                    ? "\(focus.name) · \(step)" : focus.name))
                        .font(.caption.weight(.medium)).lineLimit(1)
                }
                Text(GlanceText.counts(waiting: 0, working: glance.working.count, new: glance.newResults.count))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Open WatchMan").font(.subheadline.weight(.semibold))
                Text("to link your Mac").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Medium: the sessions with what each is doing (as many as fit), and the plan's usage.
struct MediumGlanceView: View {
    let glance: Glance?
    let now: Date

    var body: some View {
        HStack(spacing: 14) {
            // As many rows as fit: with what each does when there's room, else names only; larger text (Dynamic
            // Type) shows fewer, never cut off
            ViewThatFits(in: .vertical) {
                column(rows: 3, detailed: true)
                column(rows: 2, detailed: true)
                column(rows: 4, detailed: false)
                column(rows: 3, detailed: false)
                column(rows: 2, detailed: false)
                column(rows: 1, detailed: false)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            VStack(spacing: 10) {
                GlanceRing(label: "Session", percent: glance?.sessionPercent, color: UsageColor.session)
                GlanceRing(label: "Week", percent: glance?.weekPercent, color: UsageColor.week)
            }
        }
    }

    private func column(rows: Int, detailed: Bool) -> some View {
        VStack(alignment: .leading, spacing: detailed ? 6 : 7) {
            GlanceHeader(glance: glance, face: 22)
            if let glance, !glance.sessions.isEmpty {
                ForEach(glance.sessions.prefix(rows)) { session in
                    Link(destination: PhoneLinks.session(session.id)) {
                        if detailed {
                            SessionRow(session: session, now: now, badge: 20)
                        } else {
                            HStack(spacing: 7) {
                                ProjectBadge(name: session.name, key: session.colorKey, size: 18)
                                Text(session.name).font(.caption.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: 4)
                                SessionMark(session: session, now: now)
                            }
                        }
                    }
                    // Plain text, not the link colour
                    .foregroundStyle(.white)
                }
            } else {
                Text(glance == nil ? "Open WatchMan to link your Mac." : "No Claude Code sessions on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Large: the sessions with what each is doing (as many as fit), and the usage.
struct LargeGlanceView: View {
    let glance: Glance?
    let now: Date

    var body: some View {
        // As many rows as fit: larger text (Dynamic Type) shows fewer, and the header always shows
        ViewThatFits(in: .vertical) {
            content(rows: 6)
            content(rows: 5)
            content(rows: 4)
            content(rows: 3)
            content(rows: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func content(rows: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconFace(size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("WatchMan").font(.headline)
                    Text(glance.map(GlanceText.counts) ?? "Open WatchMan to link your Mac")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                GlanceRing(label: "Session", percent: glance?.sessionPercent, color: UsageColor.session, size: 34)
                GlanceRing(label: "Week", percent: glance?.weekPercent, color: UsageColor.week, size: 34)
            }
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            if let glance {
                ForEach(glance.sessions.prefix(rows)) { session in
                    Link(destination: PhoneLinks.session(session.id)) { SessionRow(session: session, now: now) }
                        .foregroundStyle(.white)
                }
                if glance.sessions.count > rows {
                    Text("+ \(glance.sessions.count - rows) more").font(.caption2).foregroundStyle(.secondary)
                }
                if glance.sessions.isEmpty {
                    Text("No Claude Code sessions on your Mac.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A session with what it's doing: its badge, name and state, then the prompt, the step or its last words.
private struct SessionRow: View {
    let session: Glance.Session
    let now: Date
    var badge: CGFloat = 24

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ProjectBadge(name: session.name, key: session.colorKey, size: badge)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(session.name).font(.caption.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    SessionMark(session: session, now: now)
                }
                if let prompt = session.prompt {
                    Text(prompt.text).font(.caption2).foregroundStyle(PhoneTheme.needsYou).lineLimit(1)
                } else if session.state == .working {
                    StepLine(text: session.detail)
                } else {
                    Text(session.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// The icon's face and "WatchMan".
private struct GlanceHeader: View {
    let glance: Glance?
    let face: CGFloat

    var body: some View {
        HStack(spacing: 7) {
            IconFace(size: face)
            Text("WatchMan").font(.subheadline.bold())
            Spacer(minLength: 4)
        }
    }
}

// MARK: - Live Activity

/// What else is going on, in a few words, with the next waiting session in its colour.
struct OthersLine: View {
    let state: LiveGlance

    var body: some View {
        if let others = state.others {
            Text(others)
                .font(.caption.weight(.medium))
                .foregroundStyle(state.next != nil ? PhoneTheme.needsYou : .secondary)
                .lineLimit(1)
        }
    }
}

/// The headline: the prompt's heading and words, the working session's step, or all done.
struct ActivityHeadline: View {
    let state: LiveGlance

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let focus = state.focus, let prompt = focus.prompt {
                HStack(spacing: 6) {
                    Text(prompt.heading).font(.subheadline.weight(.semibold)).foregroundStyle(PhoneTheme.needsYou).lineLimit(1)
                    Spacer(minLength: 0)
                }
                if prompt.kind == .permission {
                    Text(prompt.text).font(.system(.callout, design: .monospaced)).lineLimit(2)
                } else {
                    Text(prompt.text).font(.headline).lineLimit(2)
                }
            } else if let focus = state.focus {
                Text(focus.name).font(.headline).lineLimit(1)
                switch focus.state {
                case .working: StepLine(text: focus.detail)
                case .limited:
                    if let resets = focus.resets, resets > Date() {
                        Text("Usage limit · resets at \(resets.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(PhoneTheme.limit).lineLimit(1)
                    } else {
                        Text("Usage limit · \(focus.detail)").font(.caption).foregroundStyle(PhoneTheme.limit).lineLimit(1)
                    }
                case .failed:
                    Text("Stopped with an error · \(focus.detail)").font(.caption).foregroundStyle(PhoneTheme.failed).lineLimit(1)
                default: Text(focus.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("All done").font(.headline)
                Text(state.newResults > 0 ? (state.newResults == 1 ? "1 new result to read" : "\(state.newResults) new results to read")
                     : "Nothing working or waiting").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one thing to do next, top right: Reply while it works, Continue after the usage limit, Retry after an error,
/// Read a new result. (Beside a prompt, its buttons take that place.)
struct ActivityAction: View {
    let state: LiveGlance

    var body: some View {
        if let focus = state.focus, focus.prompt == nil {
            switch focus.state {
            case .limited: ActionCapsule(title: "Continue", target: .sessionAction(focus.id, "continue"))
            case .failed: ActionCapsule(title: "Retry", target: .sessionAction(focus.id, "retry"))
            default: ActionCapsule(title: "Reply", target: .link(state.link))
            }
        } else if state.focus == nil, state.newResult != nil {
            ActionCapsule(title: "Read", target: .link(state.link))
        }
    }
}

/// The focus session's plan as a bar of its tasks, and the plan's usage.
struct ActivityFooter: View {
    let state: LiveGlance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let focus = state.focus, focus.tasksTotal > 0 {
                HStack(spacing: 3) {
                    ForEach(0..<min(focus.tasksTotal, 12), id: \.self) { index in
                        Capsule().fill(index < focus.tasksDone ? PhoneTheme.working : Color.white.opacity(0.15)).frame(height: 4)
                    }
                    Text("\(focus.tasksDone) of \(focus.tasksTotal)")
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 4)
                }
            }
            HStack(spacing: 10) {
                OthersLine(state: state)
                Spacer(minLength: 0)
                // In the usage windows' own colours, as on the widgets
                if let session = state.sessionPercent { Text("Session \(Int(session))%").foregroundStyle(UsageColor.session) }
                if let week = state.weekPercent { Text("Week \(Int(week))%").foregroundStyle(UsageColor.week) }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }
}

/// The prompt's buttons: Allow and Deny, Approve and Keep Planning, or a question's choices. "Sent to your Mac"
/// once answered.
struct PromptButtons: View {
    let sessionId: String
    let prompt: Glance.Prompt
    let answered: Bool

    var body: some View {
        if answered {
            Label("Sent to your Mac", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        } else {
            switch prompt.kind {
            case .permission:
                HStack(spacing: 8) {
                    ActionButton(action: .deny, sessionId: sessionId, asked: prompt.asked, title: "Deny")
                    ActionButton(action: .allow, sessionId: sessionId, asked: prompt.asked, title: "Allow", prominent: true)
                }
            case .plan:
                HStack(spacing: 8) {
                    Link(destination: PhoneLinks.session(sessionId)) {
                        Text("Read").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    ActionButton(action: .deny, sessionId: sessionId, asked: prompt.asked, title: "Keep Planning")
                    ActionButton(action: .allow, sessionId: sessionId, asked: prompt.asked, title: "Approve", prominent: true)
                }
            case .question:
                if prompt.choices.isEmpty {
                    // Several questions, or several choices to pick: they need the app's room
                    Link(destination: PhoneLinks.session(sessionId)) {
                        Text("Answer in WatchMan").font(.subheadline.weight(.semibold)).foregroundStyle(.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                } else {
                    HStack(spacing: 8) {
                        ForEach(Array(prompt.choices.enumerated()), id: \.offset) { index, choice in
                            ActionButton(action: .choice(index), sessionId: sessionId, asked: prompt.asked, title: choice)
                        }
                    }
                }
            }
        }
    }
}

/// One of the Live Activity's buttons. It answers through an App Intent, so the app doesn't open.
struct ActionButton: View {
    enum Action { case allow, deny, choice(Int) }

    let action: Action
    let sessionId: String
    /// When the prompt came, so the answer can't reach the next one.
    let asked: Date?
    let title: String
    var prominent = false

    var body: some View {
        #if os(iOS)
        switch action {
        case .allow: Button(intent: AllowIntent(sessionId: sessionId, asked: asked)) { label }.buttonStyle(.plain)
        case .deny: Button(intent: AnswerIntent(sessionId: sessionId, choice: -1, asked: asked)) { label }.buttonStyle(.plain)
        case .choice(let index):
            Button(intent: AnswerIntent(sessionId: sessionId, choice: index, asked: asked)) { label }.buttonStyle(.plain)
        }
        #else
        label
        #endif
    }

    private var label: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(prominent ? Color.white : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The Live Activity on the lock screen.
struct ActivityLockView: View {
    let state: LiveGlance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                IconFace(size: 38)
                ActivityHeadline(state: state)
                ActivityAction(state: state)
            }
            if let focus = state.focus, let prompt = focus.prompt {
                PromptButtons(sessionId: focus.id, prompt: prompt, answered: state.answered)
                OthersLine(state: state)
            } else {
                ActivityFooter(state: state)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

/// The Dynamic Island opened up: the same, a little tighter.
struct IslandExpandedView: View {
    let state: LiveGlance

    // The island's own regions (WatchManLiveActivity): the ball on the left, the next action on the right, the
    // session in the middle, and the rest below, inside the island's rounded corners. This puts them together the
    // same way, for the design snapshots.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                IslandExpandedLeading(state: state)
                IslandExpandedCenter(state: state)
                IslandExpandedTrailing(state: state)
            }
            IslandExpandedBottom(state: state)
        }
    }
}

/// The opened island's left: the icon's face.
struct IslandExpandedLeading: View {
    let state: LiveGlance

    var body: some View {
        IconFace(size: 40)
            .padding(.leading, 4)
            .padding(.top, 2)
    }
}

/// The opened island's middle: the prompt, or the session and its step.
struct IslandExpandedCenter: View {
    let state: LiveGlance

    var body: some View {
        ActivityHeadline(state: state)
    }
}

/// The opened island's right: the next action (Reply, Continue, Retry, Read).
struct IslandExpandedTrailing: View {
    let state: LiveGlance

    var body: some View {
        ActivityAction(state: state)
            .padding(.trailing, 4)
            .padding(.top, 2)
    }
}

/// The opened island's bottom: a prompt's buttons, or the plan, what else is going on and the usage, kept clear of
/// the rounded corners.
struct IslandExpandedBottom: View {
    let state: LiveGlance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let focus = state.focus, let prompt = focus.prompt {
                PromptButtons(sessionId: focus.id, prompt: prompt, answered: state.answered)
                OthersLine(state: state)
            } else {
                ActivityFooter(state: state)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

/// The Dynamic Island's left side when closed: the icon's face.
struct IslandLeading: View {
    let state: LiveGlance

    var body: some View {
        IconFace(size: 22)
    }
}

/// The Dynamic Island's right side when closed: a dot in the state's colour (green working, amber waiting on you,
/// blue done, red stopped), so the island stays small.
struct IslandTrailing: View {
    let state: LiveGlance

    var body: some View {
        if let color = state.dot {
            Circle()
                .fill(color)
                .frame(width: 11, height: 11)
                .shadow(color: color.opacity(0.7), radius: 3)
                .padding(.trailing, 2)
                .accessibilityLabel(state.focus.map { "\($0.name), \(PhoneTheme.title($0.state).lowercased())" } ?? "Done")
        }
    }
}

extension LiveGlance {
    /// The colour of how things stand: the focus session's state, or blue for a new result.
    var dot: Color? {
        guard let focus else { return newResults > 0 ? PhoneTheme.unseen : nil }
        return focus.prompt != nil ? PhoneTheme.needsYou : PhoneTheme.color(focus.state)
    }
}
