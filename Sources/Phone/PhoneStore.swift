import Foundation
import Observation
import UIKit
import WatchManCore

/// How the phone talks to the Mac: what it reads (sessions, chats, usage) and what it sends (your answers).
/// The iCloud link implements it.
@MainActor
protocol PhoneLink {
    func fetch() async throws -> PhoneState
    func chat(for sessionId: String) async throws -> ChatSnapshot?
    func send(_ command: PhoneCommand) async throws
    /// What the link knew last time, shown at once while it catches up.
    func cachedState() -> PhoneState?
}

extension PhoneLink {
    func cachedState() -> PhoneState? { nil }
}

/// Everything the Mac shares at once.
struct PhoneState: Equatable, Sendable {
    var sessions: [SessionSnapshot]
    var usage: PlanUsage?
    var macName: String
    var updated: Date
    /// The Mac's settings and the lists the phone asked for (Settings, Resume, System, Not saved yet).
    var extras: MacExtras? = nil
    /// Chats that changed since the last read (the store keeps them; this only carries them over).
    var chats: [String: ChatSnapshot] = [:]
}

/// The phone's copy of what's going on, and the way to answer it.
@MainActor @Observable
final class PhoneStore {
    private(set) var state = PhoneState(sessions: [], usage: nil, macName: "", updated: .distantPast)
    private(set) var chats: [String: ChatSnapshot] = [:]
    private(set) var loading = false
    /// The last thing that went wrong talking to the Mac, shown in the Overview.
    private(set) var problem: String?
    /// Commands sent but not yet reflected by the Mac, so their buttons show "Sent".
    private(set) var sent: [String: PhoneCommand.Kind] = [:]
    /// Your messages on their way, by session, until the chat (or the queue for when it finishes) shows them.
    private(set) var pending: [String: [PendingReply]] = [:]
    /// The Sessions tab's open pages (a tapped alert opens its session here).
    var path: [String] = []
    var tab = 0

    private let link: PhoneLink

    /// The store the app shows, for iCloud's pushes and the alerts (which arrive outside any page).
    static weak var current: PhoneStore?

    init(link: PhoneLink) {
        self.link = link
        // Open on the sessions the app knew last time; the first refresh catches up
        if let cached = link.cachedState() { state = cached }
        Self.current = self
    }

    /// Needs you first, then working, done and idle; within each, the longest waiting or newest first.
    var grouped: [(state: SessionSnapshot.State, sessions: [SessionSnapshot])] {
        let order: [SessionSnapshot.State] = [.needsYou, .limited, .failed, .working, .done, .idle]
        return order.compactMap { state in
            let sessions = self.state.sessions.filter { $0.state == state }.sorted { $0.since > $1.since }
            return sessions.isEmpty ? nil : (state, sessions)
        }
    }

    var waiting: [SessionSnapshot] { state.sessions.filter { [.needsYou, .limited, .failed].contains($0.state) } }

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            var fetched = try await link.fetch()
            // New messages reach an open chat with every refresh, not only when its page opens
            for (id, chat) in fetched.chats where chats[id] != chat { chats[id] = chat }
            fetched.chats = [:]
            state = fetched
            problem = nil
            clearDelivered()
            // A prompt the Mac no longer shows was answered: its "Sent" is done
            sent = sent.filter { id, _ in state.sessions.first { $0.id == id }?.prompt != nil }
        } catch {
            problem = error.localizedDescription
            return
        }
        await PhoneGlance.update(state)
    }

    /// A message you sent, shown in its chat until it arrives.
    @discardableResult
    func addPending(_ text: String, to sessionId: String) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let reply = PendingReply(text: trimmed)
        pending[sessionId, default: []].append(reply)
        return reply.id
    }

    /// It never left the phone: why, in place of "Sending…".
    func failPending(_ id: UUID?, in sessionId: String, because reason: String?) {
        guard let id, let index = pending[sessionId]?.firstIndex(where: { $0.id == id }) else { return }
        pending[sessionId]?[index].failure = reason ?? "Couldn't send it."
    }

    /// Sends a message, showing it in the chat until it arrives (or why it couldn't leave).
    func sendReply(_ text: String, to sessionId: String) async {
        let id = addPending(text, to: sessionId)
        if !(await send(.reply(text), to: sessionId)) { failPending(id, in: sessionId, because: problem) }
    }

    func removePending(_ id: UUID, from sessionId: String) {
        pending[sessionId]?.removeAll { $0.id == id }
    }

    /// Takes off the messages the chat now has, or the Mac queued for when the session finishes.
    private func clearDelivered() {
        for (sessionId, replies) in pending {
            let said = (chats[sessionId]?.items ?? []).filter { $0.role == .you }.suffix(10).map(\.text)
            let queued = state.sessions.first { $0.id == sessionId }?.extras?.followUps ?? []
            let left = replies.filter { reply in
                reply.failure != nil || !said.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(reply.text) }
                    && !queued.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(reply.text) }
            }
            pending[sessionId] = left.isEmpty ? nil : left
        }
    }

    /// That session's page is on screen, so its alert would say nothing new.
    func isShowing(_ sessionId: String) -> Bool {
        UIApplication.shared.applicationState == .active && tab == 0 && path.last == sessionId
    }

    func loadChat(_ sessionId: String) async {
        if let chat = try? await link.chat(for: sessionId) { chats[sessionId] = chat }
    }

    /// Sends a command; false (with `problem` saying why) when it couldn't reach iCloud.
    @discardableResult
    func send(_ kind: PhoneCommand.Kind, to sessionId: String) async -> Bool {
        do {
            // An answer names the prompt it answers, in case the Mac has moved on to another
            let asked = kind.answersPrompt ? state.sessions.first { $0.id == sessionId }?.prompt?.asked : nil
            try await link.send(PhoneCommand(sessionId: sessionId, kind: kind, prompt: asked))
            // Only an answer to the prompt shows "Sent" on it (and on the Live Activity)
            if case .mac = kind {} else {
                sent[sessionId] = kind
                await WatchManActivity.markSent(sessionId)
            }
            return true
        } catch {
            problem = "Couldn't send: \(error.localizedDescription)"
            return false
        }
    }
}

/// A message on its way to the Mac.
struct PendingReply: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let at = Date()
    /// Why it couldn't be sent (iCloud said no); nil while it's on its way.
    var failure: String?

    /// The Mac drops commands it reads after ten minutes.
    var lost: Bool { Date().timeIntervalSince(at) > PhoneCommand.maxAge }
}

