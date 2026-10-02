import Foundation
import Observation
import UIKit
import WatchManCore

/// How the phone talks to the Mac: what it reads (sessions, chats, usage) and what it sends (your answers).
/// The iCloud link implements it; until then the sample link shows how it looks.
@MainActor
protocol PhoneLink {
    func fetch() async throws -> PhoneState
    func chat(for sessionId: String) async throws -> ChatSnapshot?
    func send(_ command: PhoneCommand) async throws
}

/// Everything the Mac shares at once.
struct PhoneState: Equatable, Sendable {
    var sessions: [SessionSnapshot]
    var usage: PlanUsage?
    var macName: String
    var updated: Date
    /// The Mac's settings and the lists the phone asked for (Settings, Resume, System, Not saved yet).
    var extras: MacExtras? = nil
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
    /// The Sessions tab's open pages (a tapped alert opens its session here).
    var path: [String] = []
    var tab = 0

    private let link: PhoneLink

    /// The store the app shows, for iCloud's pushes and the alerts (which arrive outside any page).
    static weak var current: PhoneStore?

    init(link: PhoneLink) {
        self.link = link
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
            state = try await link.fetch()
            problem = nil
            // A prompt the Mac no longer shows was answered: its "Sent" is done
            sent = sent.filter { id, _ in state.sessions.first { $0.id == id }?.prompt != nil }
        } catch {
            problem = error.localizedDescription
            return
        }
        await PhoneGlance.update(state)
    }

    /// That session's page is on screen, so its alert would say nothing new.
    func isShowing(_ sessionId: String) -> Bool {
        UIApplication.shared.applicationState == .active && tab == 0 && path.last == sessionId
    }

    func loadChat(_ sessionId: String) async {
        if let chat = try? await link.chat(for: sessionId) { chats[sessionId] = chat }
    }

    func send(_ kind: PhoneCommand.Kind, to sessionId: String) async {
        do {
            // An answer names the prompt it answers, in case the Mac has moved on to another
            let asked = kind.answersPrompt ? state.sessions.first { $0.id == sessionId }?.prompt?.asked : nil
            try await link.send(PhoneCommand(sessionId: sessionId, kind: kind, prompt: asked))
            // Only an answer to the prompt shows "Sent" on it (and on the Live Activity)
            if case .mac = kind {} else {
                sent[sessionId] = kind
                await WatchManActivity.markSent(sessionId)
            }
        } catch {
            problem = "Couldn't send: \(error.localizedDescription)"
        }
    }
}

/// Sample sessions, for the first version of the app and for previews, before the iCloud link.
struct SampleLink: PhoneLink {
    func fetch() async throws -> PhoneState {
        let now = Date()
        func session(_ id: String, _ name: String, _ state: SessionSnapshot.State, _ detail: String, ago: TimeInterval,
                     prompt: PromptSnapshot? = nil, unseen: Bool = false) -> SessionSnapshot {
            SessionSnapshot(id: id, name: name, task: nil, colorKey: name, host: "Ghostty", canReply: true, state: state,
                            detail: detail, since: now.addingTimeInterval(-ago), unseen: unseen, prompt: prompt,
                            contextPercent: id == "m" ? 63 : nil, limitReset: nil, updated: now)
        }
        var allow = PendingApproval(tool: "Bash", detail: "Run · Build the release APK", requestedAt: now,
                                    description: "Build the release APK", command: "flutter build apk --release --split-per-abi")
        allow.handBackAt = now.addingTimeInterval(80)
        let ask = PendingApproval(tool: "AskUserQuestion", detail: "AskUserQuestion", requestedAt: now, questions: [
            AskedQuestion(question: "Which icon set should I use?", header: "Icons", options: [
                .init(label: "Lucide", description: "Clean outline icons, over 1,400."),
                .init(label: "Heroicons", description: "Tailwind's set, solid and outline."),
            ]),
        ])
        return PhoneState(sessions: [
            session("k", "Lumen", .needsYou, "Build the release APK", ago: 480, prompt: PromptSnapshot(approval: allow)),
            session("a", "Harbor Web", .needsYou, "Which icon set should I use?", ago: 180, prompt: PromptSnapshot(approval: ask)),
            session("m", "Trailmap", .working, "Edit · workout_screen.dart", ago: 300),
            session("w", "WatchMan", .working, "Run · xcodebuild test", ago: 120),
            session("c", "Shipyard", .done, "Build passed on Shipyard.", ago: 600, unseen: true),
        ], usage: PlanUsage(session: UsageWindow(percent: 23, resetsAt: now.addingTimeInterval(3 * 3600)),
                            week: UsageWindow(percent: 41, resetsAt: now.addingTimeInterval(3 * 86400))),
        macName: "MacBook Pro", updated: now, extras: PhoneSamples.extras(now: now))
    }

    func chat(for sessionId: String) async throws -> ChatSnapshot? {
        let now = Date()
        return ChatSnapshot(sessionId: sessionId, chat: [
            .message(.init(id: 1, at: now.addingTimeInterval(-300), fromYou: true, text: "Build the release APK and upload it")),
            .steps([.init(id: 2, at: now.addingTimeInterval(-280), kind: .tool, text: "Read · pubspec.yaml"),
                    .init(id: 3, at: now.addingTimeInterval(-270), kind: .tool, text: "Run · flutter clean")]),
            .message(.init(id: 4, at: now.addingTimeInterval(-200), fromYou: false, text: "The project is clean. I'll build the release APK split per ABI next.")),
        ])
    }

    func send(_ command: PhoneCommand) async throws {}
}
