import AppKit
import SwiftUI
import WatchManCore

/// The project's square: its first letter in its colour.
struct ProjectTile: View {
    let label: String
    let colorKey: String
    var size: CGFloat = 28

    init(session: Session, size: CGFloat = 28) {
        self.init(label: session.label, colorKey: session.colorKey, size: size)
    }

    /// For something that outlives its session (a timeline entry).
    init(label: String, colorKey: String, size: CGFloat = 28) {
        self.label = label
        self.colorKey = colorKey
        self.size = size
    }

    var body: some View {
        let color = Theme.projectColor(colorKey)
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(color.opacity(0.3), lineWidth: 1))
            .overlay(
                Text(String(label.first ?? "?").uppercased())
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A session's state as a small chip: ✋ and the wait for a permission, a bubble for a question, a green dot and
/// the time while working, ✓ New for a fresh result; a plain time otherwise.
struct StatusChip: View {
    let session: Session
    /// On a selected sidebar row the chip turns white, so it reads on the accent colour.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let time = session.timeText(now: context.date)
            let look = look(time: time)
            if prominence == .increased {
                HStack(spacing: 4) {
                    if look.dot { Circle().fill(.white).frame(width: 6, height: 6) }
                    if let symbol = look.symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
                    Text(look.text).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, look.color == nil ? 0 : 7)
                .frame(height: 20)
                .background(Color.white.opacity(look.color == nil ? 0 : 0.2), in: Capsule())
                .fixedSize()
            } else if let color = look.color {
                HStack(spacing: 4) {
                    if look.dot { Circle().fill(color).frame(width: 6, height: 6) }
                    if let symbol = look.symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
                    Text(look.text).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(color.opacity(0.15), in: Capsule())
                .fixedSize()
            } else {
                Text(time).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.faint).fixedSize()
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private func look(time: String) -> (symbol: String?, dot: Bool, text: String, color: Color?) {
        if session.rateLimited { return ("hourglass", false, session.limitReset ?? "limit", Theme.limit) }
        if session.failed { return ("xmark.octagon.fill", false, time, Theme.failed) }
        switch session.status {
        case .needsYou:
            let symbol = session.pendingApproval?.isPlan == true ? "list.bullet.clipboard.fill"
                : session.asksPermission ? "hand.raised.fill" : "questionmark.bubble.fill"
            return (symbol, false, time, Theme.needsYou)
        case .working:
            return (nil, true, time, Theme.working)
        case .finished:
            return session.seen ? (nil, false, time, nil) : ("checkmark.circle.fill", false, "New", Theme.unseen)
        case .idle, .closed:
            return (nil, false, time, nil)
        }
    }

    private var accessibilityText: String {
        if session.rateLimited { return "Usage limit reached" + (session.limitReset.map { ", resets \($0)" } ?? "") }
        if session.failed { return "Stopped with an error" }
        switch session.status {
        case .needsYou: return session.asksPermission ? "Waiting for permission" : "Waiting for an answer"
        case .working: return "Working"
        case .finished: return session.seen ? "Done" : "New result"
        case .idle, .closed: return "Idle"
        }
    }
}

/// Allow: the main answer, white. The key hint only shows where the key works.
struct AllowButton: View {
    var title = "Allow"
    var hint = false
    var height: CGFloat = 24
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                if hint { Text("⌘↩").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.black.opacity(0.5)) }
            }
            .padding(.horizontal, 11)
            .frame(height: height)
            .background(Color.white, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(hint ? "\(title) (⌘↩)" : title)
        .accessibilityLabel(title)
    }
}

/// Deny: quiet.
struct DenyButton: View {
    var hint = false
    var height: CGFloat = 24
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text("Deny").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                if hint { Text("⌘⌫").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.faint) }
            }
            .padding(.horizontal, 11)
            .frame(height: height)
            .background(Color.white.opacity(0.10), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(hint ? "Deny (⌘⌫)" : "Deny")
        .accessibilityLabel("Deny")
    }
}

/// ⋯ beside Allow and Deny: always allow (naming the rule it saves), or answer in the terminal.
struct ApprovalMoreMenu: View {
    let session: Session
    let approval: PendingApproval
    let store: SessionStore
    var height: CGFloat = 24

    var body: some View {
        Menu {
            Button(approval.rules.isEmpty ? "Always Allow" : "Always Allow \(approval.rules.joined(separator: ", "))") {
                store.respond(to: session.id, with: .always)
            }
            Button("Answer in the Terminal") {
                store.respond(to: session.id, with: .ask)
                store.open(session)
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.secondary)
        .frame(width: height + 6, height: height)
        .background(Color.white.opacity(0.08), in: Capsule())
        .help("More answers")
        .accessibilityLabel("More answers")
    }
}

/// The three answers to a permission on one line. A risky or long command offers Review instead of Allow.
struct ApprovalAnswers: View {
    let session: Session
    let approval: PendingApproval
    let store: SessionStore
    var hints = false
    var height: CGFloat = 24
    /// Review: open the session's page to read it first.
    var review: (() -> Void)?

    var body: some View {
        if let question = approval.simpleQuestion {
            QuestionChoices(session: session, question: question, store: store, height: height)
        } else if approval.isQuestion, let review {
            Button(action: review) {
                Text("Answer…").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.needsYou)
                    .padding(.horizontal, 11).frame(height: height)
                    .background(Theme.needsYou.opacity(0.16), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Several questions: answer them on the page")
        } else {
            permissionButtons
        }
    }

    private var permissionButtons: some View {
        HStack(spacing: 6) {
            DenyButton(hint: hints, height: height) { store.respond(to: session.id, with: .deny) }
            if let review, approval.needsReview {
                Button(action: review) {
                    Text("Review").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.needsYou)
                        .padding(.horizontal, 11).frame(height: height)
                        .background(Theme.needsYou.opacity(0.16), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Risky or long: read it first")
            } else {
                AllowButton(hint: hints, height: height) { store.respond(to: session.id, with: .allow) }
            }
            ApprovalMoreMenu(session: session, approval: approval, store: store, height: height)
        }
    }
}

extension PendingApproval {
    /// Too risky or too long to answer without reading it on the page (and questions with several parts).
    var needsReview: Bool {
        if isQuestion { return simpleQuestion == nil }
        if isPlan { return true }
        return isRisky || (command ?? detail).count > ToastView.fullyShown || kind == .edit || kind == .write
    }

    /// The question when there's just one, with single choices: one click on a choice answers it.
    var simpleQuestion: AskedQuestion? {
        guard questions.count == 1, let question = questions.first, !question.multiSelect, !question.options.isEmpty else { return nil }
        return question
    }
}

extension Session {
    /// Waiting on a permission (Allow / Deny), not on an answer to a question.
    var asksPermission: Bool {
        if let approval = pendingApproval { return !approval.isQuestion }
        if case .needsYou(let reason) = status { return reason.hasPrefix("Permission") }
        return false
    }
}

/// A question's choices as small buttons, in a row (the notch list, its messages, the overview).
struct QuestionChoices: View {
    let session: Session
    let question: AskedQuestion
    let store: SessionStore
    var limit = 3
    var height: CGFloat = 24
    var done: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(question.options.prefix(limit).enumerated()), id: \.offset) { index, option in
                Button {
                    _ = store.pickOption(index, for: session.id)
                    done()
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(index == 0 ? .black : Theme.primary)
                        .lineLimit(1)
                        .padding(.horizontal, 11)
                        .frame(height: height)
                        .background(index == 0 ? Theme.primary : Color.white.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(option.description ?? option.label)
            }
        }
    }
}

/// The colour of a state washing up from below a dark card.
struct Wash: View {
    let color: Color
    var radius: CGFloat = 14
    var strength: Double = 0.36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(red: 0.075, green: 0.08, blue: 0.09))
            RadialGradient(colors: [color.opacity(strength), .clear], center: UnitPoint(x: 0.5, y: 1.3), startRadius: 0, endRadius: 280)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        }
    }
}

/// Claude's plan as a short track with a dot at the current task, and "4/7".
struct PlanTrack: View {
    let tasks: [ClaudeTask]
    var width: CGFloat = 52
    var showCount = true

    var body: some View {
        let done = Double(tasks.doneCount) / Double(max(tasks.count, 1))
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10)).frame(width: width, height: 3)
                Capsule().fill(Theme.working).frame(width: max(3, width * done), height: 3)
                Circle().fill(.white).frame(width: 7, height: 7)
                    .shadow(color: Theme.working, radius: 3)
                    .offset(x: width * done - 3.5)
            }
            .frame(width: width, height: 8)
            if showCount {
                Text("\(tasks.doneCount)/\(tasks.count)").font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.faint)
            }
        }
        .help("Plan: \(tasks.doneCount) of \(tasks.count) done" + (tasks.glance.current.map { " · now: \($0.text)" } ?? ""))
        .accessibilityLabel("Plan, \(tasks.doneCount) of \(tasks.count) done")
    }
}

/// Under the pointer, in place of the time: the session's own app (Ghostty, iTerm, VS Code…) and its chat.
struct OpenButtons: View {
    let session: Session
    let store: SessionStore
    var size: CGFloat = 22
    let openChat: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button { store.open(session) } label: {
                HostIcon(host: session.host, size: size * 0.7)
                    .frame(width: size, height: size)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in \(session.host.label) (O, or ⌘-click the row)")
            .accessibilityLabel("Open in \(session.host.label)")
            Button(action: openChat) {
                Image(systemName: "bubble.left.fill").font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .frame(width: size, height: size)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the chat (↩)")
            .accessibilityLabel("Open the chat")
        }
        .fixedSize()
    }
}

/// Parts of the open panel arrive one after another: from blurred and slightly small to sharp, 35 ms apart,
/// starting 0.15 s after the island begins to grow. With Reduce Motion they only fade.
struct Arrive: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduceMotion ? 0 : 10)
            .scaleEffect(shown || reduceMotion ? 1 : 0.96, anchor: .top)
            .onAppear {
                let delay = 0.15 + 0.035 * Double(index)
                withAnimation(reduceMotion ? .easeOut(duration: 0.2).delay(delay) : .spring(response: 0.4, dampingFraction: 0.8).delay(delay)) {
                    shown = true
                }
            }
    }
}

extension View {
    func arrive(_ index: Int) -> some View { modifier(Arrive(index: index)) }
}

/// "NEEDS YOU ──── 2": a section's small caps label, a hairline and its count.
struct SectionLabel: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.faint)
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            Text("\(count)").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(.isHeader)
    }
}

/// Remote Control is on for this session: it can be used from the Claude app on the phone or the web.
struct RemoteBadge: View {
    var label = "RC"

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 8.5, weight: .bold))
            Text(label).font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(Theme.web)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Theme.web.opacity(0.14), in: Capsule())
        .fixedSize()
        .help("Remote Control is on: you can use this session from the Claude app on your phone or the web")
        .accessibilityLabel("Remote Control on")
    }
}

extension Session {
    /// The session in the Claude app, while Remote Control is on.
    var remoteURL: URL? { remoteSessionId.flatMap { URL(string: "https://claude.ai/code/\($0)") } }
}

extension EnvironmentValues {
    /// The view is in the WatchMan window rather than the notch panel.
    @Entry var inMainWindow = false
}

/// A ring that fills with a share of a limit.
struct UsageRing: View {
    let percent: Double
    var color: Color = Theme.working
    var size: CGFloat = 30
    var line: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: line)
            Circle().trim(from: 0, to: min(1, max(0, percent / 100)))
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension PlanUsage {
    /// "Session 23%, resets 3:00 PM · Week 41%, resets Sun 9:00 AM".
    static func summary(_ usage: PlanUsage) -> String {
        [("Session", usage.session), ("Week", usage.week)].compactMap { name, window -> String? in
            guard let window else { return nil }
            return "\(name) \(Int(window.percent))%" + (window.resetText.map { ", resets \($0)" } ?? "")
        }
        .joined(separator: " · ")
    }
}

/// How full a session's context is: shown from half full, orange from 80% with what to do about it.
struct ContextChip: View {
    let percent: Double

    var body: some View {
        let high = percent >= 80
        HStack(spacing: 4) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward").font(.system(size: 9.5, weight: .semibold))
            Text("Context \(Int(percent))%").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(high ? Theme.limit : Theme.secondary)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background((high ? Theme.limit : Color.white).opacity(high ? 0.15 : 0.07), in: Capsule())
        .fixedSize()
        .help(high ? "The conversation is \(Int(percent))% of what Claude can hold. /compact makes room."
              : "The conversation is \(Int(percent))% of what Claude can hold")
    }
}
