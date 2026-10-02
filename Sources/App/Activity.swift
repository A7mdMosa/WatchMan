import Foundation
import WatchManCore

/// The timeline's file in Application Support, so the last two days survive a restart.
enum ActivityFile {
    static var url: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchMan", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("activity.json")
    }

    static func load() -> ActivityLog {
        guard let data = try? Data(contentsOf: url), var log = try? JSONDecoder().decode(ActivityLog.self, from: data) else {
            return ActivityLog()
        }
        log.prune(now: Date())
        return log
    }

    static func save(_ log: ActivityLog) {
        guard let data = try? JSONEncoder().encode(log) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension SessionStore {
    /// Adds an event to the timeline and saves it a moment later (several events in a burst make one write).
    func record(_ kind: ActivityEntry.Kind, _ text: String, for session: Session) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        activity.add(ActivityEntry(at: Date(), sessionId: session.id, name: session.label, colorKey: session.colorKey,
                                   kind: kind, text: line.isEmpty ? kind.rawValue.capitalized : line))
        activitySave?.cancel()
        activitySave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            ActivityFile.save(self.activity)
        }
    }

    /// A turn ended: what Claude said, or why it stopped.
    func recordFinish(_ session: Session) {
        if session.rateLimited {
            record(.limited, session.limitReset.map { "Usage limit · resets \($0)" } ?? "Usage limit reached", for: session)
        } else if session.failed {
            record(.failed, session.errorText.map(Session.firstSentence) ?? "Stopped with an error", for: session)
        } else {
            record(.finished, session.lastReply.map(Session.firstSentence) ?? "Finished", for: session)
        }
    }
}

/// One-click answers under a finished session's chat: the answers to Claude's closing question, next steps from
/// what the last turn did, then the project's quick replies. ⌘1–3 send them.
struct AnswerChip: Equatable {
    var label: String
    var text: String
    var isAnswer: Bool
}

extension SessionStore {
    /// Up to three, in order: Retry after an error, the closing question's answers, next steps, quick replies.
    func answerChips(for session: Session) -> [AnswerChip] {
        // Claude's own question: its choices (the hook answers it, no typing needed)
        if hasPendingPrompt(session.id), let question = session.pendingApproval?.simpleQuestion {
            return question.options.prefix(4).map { AnswerChip(label: $0.label, text: $0.label, isAnswer: true) }
        }
        guard session.host.canSend, !hasPendingPrompt(session.id) else { return [] }
        var list: [AnswerChip] = []
        if session.failed { list.append(AnswerChip(label: "Retry", text: "continue", isAnswer: true)) }
        // The question is in Claude's last message, or (waiting on you) in why it waits
        var asked = session.lastReply
        if case .needsYou(let reason) = session.status, reason.hasSuffix("?") {
            asked = (asked.flatMap { ClosingQuestion.find(in: $0)?.answers.isEmpty == false ? $0 : nil }) ?? reason
        }
        if session.status != .working, let reply = asked, let ask = ClosingQuestion.find(in: reply) {
            list += ask.answers.map { AnswerChip(label: $0.label, text: $0.text, isAnswer: true) }
        }
        if session.status != .working { list += nextSteps(for: session) }
        list += ProjectSettings.shared.quickReplies(for: session.projectRoot).map { AnswerChip(label: $0, text: $0, isAnswer: false) }
        var seen = Set<String>()
        return Array(list.filter { seen.insert($0.text.lowercased()).inserted }.prefix(3))
    }

    /// Files changed but not tested: run the tests; tested but not committed: commit; the note is behind: sync it.
    private func nextSteps(for session: Session) -> [AnswerChip] {
        guard let turn = session.lastTurn else { return [] }
        var steps: [AnswerChip] = []
        let kind = session.projectRoot.map { ProjectSettings.shared.kind(of: $0) } ?? .other
        if !turn.filesEdited.isEmpty, turn.testsPassed == nil {
            let tests = kind == .flutter ? "run flutter analyze and flutter test" : "run the tests"
            steps.append(AnswerChip(label: "Run tests", text: tests, isAnswer: false))
        }
        if !turn.filesEdited.isEmpty, turn.testsPassed != false, turn.commits == 0 {
            steps.append(AnswerChip(label: "Commit", text: "commit the changes", isAnswer: false))
        }
        if session.editedAfterSync {
            steps.append(AnswerChip(label: "/project-sync", text: "/project-sync", isAnswer: false))
        }
        return steps
    }

    /// Sends chip number `index` (0-based); while Claude works it waits in the queue. Returns the line to show.
    @discardableResult
    func sendAnswer(_ index: Int, for id: String) -> Bool {
        if pickOption(index, for: id) { return true }
        guard let session = sessions[id] else { return false }
        let chips = answerChips(for: session)
        guard chips.indices.contains(index) else { return false }
        let text = chips[index].text
        if session.status == .working {
            enqueueFollowUp(text, for: id)
            pageNote = "Queued: sent when \(session.label) finishes"
            return true
        }
        pageNote = "Sending…"
        Task {
            let error = await reply(text, to: id)
            pageNote = error ?? "Sent: \(text)"
        }
        return true
    }
}
