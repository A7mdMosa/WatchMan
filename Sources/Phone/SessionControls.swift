import SwiftUI
import WatchManCore

/// What a session's chat ends with, as on the Mac: an error to retry, the usage limit to continue after, a stuck
/// warning, its subagents, and the messages queued for when it finishes.
struct SessionExtrasView: View {
    let store: PhoneStore
    let session: SessionSnapshot

    private var extras: SessionExtras? { session.extras }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.state == .failed {
                banner(symbol: "xmark.octagon.fill", color: PhoneTheme.failed, title: "Stopped with an error",
                       text: extras?.error) {
                    Button("Retry") { Task { await store.ask(.retry, session: session.id) } }.buttonStyle(.borderedProminent)
                }
            }
            if session.state == .limited {
                banner(symbol: "hourglass", color: PhoneTheme.limit, title: "Usage limit reached",
                       text: session.limitReset.map { "Resets \($0.formatted(date: .omitted, time: .shortened))" }) {
                    if let at = extras?.continuesAt {
                        Label("Continues at \(at.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else if session.limitReset != nil {
                        Button("Continue when it resets") { Task { await store.send(.continueAfterLimit, to: session.id) } }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Retry") { Task { await store.ask(.retry, session: session.id) } }.buttonStyle(.bordered)
                    }
                }
            }
            if let stuck = extras?.stuck {
                banner(symbol: "exclamationmark.triangle.fill", color: PhoneTheme.needsYou, title: "It may be stuck", text: stuck) {
                    HStack {
                        if extras?.canStop == true {
                            Button("Stop", role: .destructive) { Task { await store.ask(.stop, session: session.id) } }
                                .buttonStyle(.bordered)
                        }
                        Button("It's fine") { Task { await store.ask(.dismissStuck, session: session.id) } }.buttonStyle(.bordered)
                    }
                }
            }
            if let helpers = extras?.subagents, !helpers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(helpers.count == 1 ? "1 subagent at work" : "\(helpers.count) subagents at work").font(.subheadline.weight(.semibold))
                    ForEach(Array(helpers.enumerated()), id: \.offset) { _, helper in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(PhoneTheme.working)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(helper.description.isEmpty ? helper.type : helper.description).font(.callout)
                                if let step = helper.step { Text(step).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.quaternarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if let queue = extras?.followUps, !queue.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sent when it finishes").font(.subheadline.weight(.semibold))
                    ForEach(Array(queue.enumerated()), id: \.offset) { index, message in
                        HStack(alignment: .firstTextBaseline) {
                            Text(message).font(.callout).lineLimit(3)
                            Spacer(minLength: 8)
                            Button {
                                Task { await store.ask(.removeFollowUp(index), session: session.id) }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove “\(message)”")
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PhoneTheme.unseen.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if let link = extras?.remoteURL, let url = URL(string: link) {
                Link(destination: url) {
                    Label("Open in Claude (Remote Control)", systemImage: "arrow.up.forward.app")
                        .font(.subheadline.weight(.medium))
                }
            }
            MacNoteLine(store: store)
        }
    }

    private func banner<Actions: View>(symbol: String, color: Color, title: String, text: String?,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(color)
            if let text { Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(6) }
            actions()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Stop in the session page's toolbar while Claude works (Esc in its terminal).
struct StopButton: View {
    let store: PhoneStore
    let session: SessionSnapshot
    @State private var confirming = false

    var body: some View {
        if session.state == .working, session.extras?.canStop == true {
            Button { confirming = true } label: { Label("Stop", systemImage: "stop.circle") }
                .confirmationDialog("Stop Claude in \(session.name)?", isPresented: $confirming, titleVisibility: .visible) {
                    Button("Stop", role: .destructive) { Task { await store.ask(.stop, session: session.id) } }
                } message: {
                    Text("Presses Esc in its terminal, as you would on the Mac.")
                }
        }
    }
}

/// Several questions, or one where several choices can be picked: pick, then Send Answers (or Skip).
struct QuestionForm: View {
    let store: PhoneStore
    let session: SessionSnapshot
    let prompt: PromptSnapshot
    @State private var picks: [String: Set<String>] = [:]

    private var allAnswered: Bool { prompt.questions.allSatisfy { !(picks[$0.question] ?? []).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(prompt.questions, id: \.question) { question in
                VStack(alignment: .leading, spacing: 8) {
                    if let header = question.header, prompt.questions.count > 1 {
                        Text(header.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    if prompt.questions.count > 1 || question.question != prompt.title {
                        Text(question.question).font(.subheadline.weight(.semibold))
                    }
                    if question.multiSelect { Text("Pick any").font(.caption).foregroundStyle(.secondary) }
                    ForEach(question.options, id: \.label) { option in
                        choice(question, option)
                    }
                }
            }
            HStack {
                Button("Send Answers") { send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!allAnswered)
                Button("Skip") { Task { await store.send(.deny(message: nil), to: session.id) } }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func choice(_ question: AskedQuestion, _ option: AskedQuestion.Option) -> some View {
        let picked = picks[question.question]?.contains(option.label) == true
        return Button {
            var set = picks[question.question] ?? []
            if question.multiSelect {
                if picked { set.remove(option.label) } else { set.insert(option.label) }
            } else {
                set = [option.label]
            }
            picks[question.question] = set
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: question.multiSelect ? (picked ? "checkmark.square.fill" : "square")
                      : (picked ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(picked ? PhoneTheme.needsYou : .secondary)
                ChoiceText(option: option)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .background(Color(picked ? .secondarySystemFill : .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// Several picks in the order Claude listed them, joined the way Claude Code writes them.
    private func send() {
        var answers: [String: String] = [:]
        for question in prompt.questions {
            let chosen = question.options.map(\.label).filter { picks[question.question]?.contains($0) == true }
            if !chosen.isEmpty { answers[question.question] = chosen.joined(separator: ", ") }
        }
        Task { await store.send(.answer(QuestionAnswers(answers: answers)), to: session.id) }
    }
}
