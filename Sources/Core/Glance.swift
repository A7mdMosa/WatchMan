import Foundation

/// What the iPhone's widgets, Live Activity and alert badge show: a small copy of the sessions and the usage,
/// which the app keeps in its shared app group each time it hears from the Mac.
public struct Glance: Codable, Equatable, Sendable {
    public struct Session: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var colorKey: String
        public var state: SessionSnapshot.State
        /// Why it waits, or the step it's on.
        public var detail: String
        public var since: Date
        public var updated: Date
        public var unseen: Bool
        public var prompt: Prompt?
        /// Claude's plan for the work: how many of its tasks are done (0 of 0 without a plan).
        public var tasksDone: Int
        public var tasksTotal: Int
        /// When the usage limit that stopped it resets.
        public var resets: Date?

        public init(id: String, name: String, colorKey: String, state: SessionSnapshot.State, detail: String,
                    since: Date, updated: Date, unseen: Bool, prompt: Prompt?, tasksDone: Int, tasksTotal: Int,
                    resets: Date? = nil) {
            self.id = id
            self.name = name
            self.colorKey = colorKey
            self.state = state
            self.detail = detail
            self.since = since
            self.updated = updated
            self.unseen = unseen
            self.prompt = prompt
            self.tasksDone = tasksDone
            self.tasksTotal = tasksTotal
            self.resets = resets
        }

        public init(_ snapshot: SessionSnapshot) {
            let tasks = snapshot.tasks ?? []
            // Kept short: the Live Activity's whole content has to fit in 4 KB
            self.init(id: snapshot.id, name: String(snapshot.name.prefix(60)), colorKey: snapshot.colorKey,
                      state: snapshot.state, detail: String(snapshot.detail.prefix(120)), since: snapshot.since,
                      updated: snapshot.updated, unseen: snapshot.unseen,
                      prompt: snapshot.prompt.map { Prompt($0, session: snapshot.name) },
                      tasksDone: tasks.filter { $0.state == .done }.count, tasksTotal: tasks.count,
                      resets: snapshot.limitReset)
        }

        public var waiting: Bool { Glance.waitingStates.contains(state) }
    }

    /// A prompt as one line and, when it's a single question with a few choices, those choices as buttons.
    public struct Prompt: Codable, Hashable, Sendable {
        public var kind: PromptSnapshot.Kind
        /// "Lumen wants to run", "Harbor Web asks", "Trailmap's plan is ready".
        public var heading: String
        /// The command, the question, or the prompt's title.
        public var text: String
        /// One question's choices, to tap; empty for several questions or one where several can be picked.
        public var choices: [String]
        /// When it came (`PromptSnapshot.asked`), sent with an answer so it can't reach the next prompt.
        public var asked: Date?

        public init(kind: PromptSnapshot.Kind, heading: String, text: String, choices: [String], asked: Date? = nil) {
            self.kind = kind
            self.heading = heading
            self.text = text
            self.choices = choices
            self.asked = asked
        }

        /// Tells it from the next prompt, even one with the same words (to the millisecond, which survives the
        /// Live Activity's own encoding).
        public var key: String { asked.map { String(Int(($0.timeIntervalSince1970 * 1000).rounded())) } ?? text }

        public init(_ prompt: PromptSnapshot, session name: String) {
            kind = prompt.kind
            switch prompt.kind {
            case .permission:
                heading = prompt.command != nil ? "\(name) wants to run" : prompt.file != nil ? "\(name) wants to edit"
                    : "\(name) needs your OK"
                text = prompt.command ?? prompt.file ?? prompt.title
            case .question:
                heading = "\(name) asks"
                text = prompt.questions.count == 1 ? prompt.questions[0].question : prompt.title
            case .plan:
                heading = "\(name)'s plan is ready"
                text = prompt.title
            }
            let single = prompt.questions.count == 1 && !prompt.questions[0].multiSelect
            choices = prompt.kind == .question && single && prompt.questions[0].options.count <= Glance.maxChoices
                ? prompt.questions[0].options.map { String($0.label.prefix(40)) } : []
            asked = prompt.asked
            // A heredoc or an inline script can run to pages: the start says enough
            heading = String(heading.prefix(80))
            text = text.count > 200 ? String(text.prefix(200)) + "…" : text
        }
    }

    /// Needs you first (the longest waiting first), then working (the latest step first), done and idle.
    public var sessions: [Session]
    public var sessionPercent: Double?
    public var weekPercent: Double?
    public var macName: String
    /// When the Mac last said anything.
    public var updated: Date

    public static let waitingStates: Set<SessionSnapshot.State> = [.needsYou, .limited, .failed]
    /// The most choices shown as buttons; more open the app.
    public static let maxChoices = 4

    public init(sessions: [Session], sessionPercent: Double?, weekPercent: Double?, macName: String, updated: Date) {
        self.sessions = sessions
        self.sessionPercent = sessionPercent
        self.weekPercent = weekPercent
        self.macName = macName
        self.updated = updated
    }

    public init(sessions snapshots: [SessionSnapshot], usage: PlanUsage?, macName: String, updated: Date) {
        let order: [SessionSnapshot.State] = [.needsYou, .limited, .failed, .working, .done, .idle]
        let sorted = snapshots.sorted { a, b in
            let rankA = order.firstIndex(of: a.state) ?? order.count
            let rankB = order.firstIndex(of: b.state) ?? order.count
            if rankA != rankB { return rankA < rankB }
            if a.state == .working { return a.updated > b.updated }
            if Self.waitingStates.contains(a.state) { return a.since < b.since }
            return a.since > b.since
        }
        self.init(sessions: sorted.map(Session.init), sessionPercent: usage?.session?.percent,
                  weekPercent: usage?.week?.percent, macName: macName, updated: updated)
    }

    /// The same without when the Mac last wrote each session, which changes with every step: what a widget shows.
    public var withoutTimes: Glance {
        var copy = self
        copy.updated = .distantPast
        for index in copy.sessions.indices { copy.sessions[index].updated = .distantPast }
        return copy
    }

    public var waiting: [Session] { sessions.filter(\.waiting) }
    public var working: [Session] { sessions.filter { $0.state == .working } }
    public var newResults: [Session] { sessions.filter { $0.state == .done && $0.unseen } }
    /// Something is going on: a session works or waits on you.
    public var busy: Bool { sessions.contains { $0.waiting || $0.state == .working } }

    /// The one session to show on its own: a prompt to answer first, then anything else waiting, then the
    /// session that worked last.
    public var focus: Session? {
        waiting.first { $0.prompt != nil } ?? waiting.first ?? working.first
    }
}
