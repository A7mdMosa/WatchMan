import ActivityKit
import SwiftUI
import UserNotifications
import WatchManCore

/// Settings: this iPhone's alerts, and WatchMan's settings on the Mac, changed from here.
/// A change shows at once and goes to the Mac; what the Mac reports back takes over a few seconds later.
struct SettingsScreen: View {
    let store: PhoneStore
    /// Your changes, until the Mac's own copy catches up.
    @State private var edited: MacSettings?
    @State private var editedAt = Date.distantPast
    @State private var notifications: UNAuthorizationStatus?
    @State private var newReply = ""
    @State private var liveActivity = PhoneSettings.liveActivity
    @State private var dynamicIsland = PhoneSettings.dynamicIsland
    /// Live Activities allowed for WatchMan in iOS Settings.
    @State private var activitiesAllowed = true
    @Environment(\.scenePhase) private var phase
    /// Changes wait a moment before going to the Mac, so a slider or a few stepper taps send one.
    @State private var sending: [String: Task<Void, Never>] = [:]
    @Environment(\.openURL) private var openURL

    private var remote: MacSettings? { store.extras?.settings }
    private var settings: MacSettings? { edited ?? remote }

    var body: some View {
        NavigationStack {
            Form {
                linkSection
                iphoneSection
                if let settings {
                    answeringSection(settings)
                    alertsSection(settings)
                    macSection(settings)
                    quietSection(settings)
                    stuckSection(settings)
                    devLogSection(settings)
                    repliesSection(settings)
                    projectsSection
                } else if store.problem == nil {
                    Section { WaitingForMac(text: "Reading your Mac's settings…") }
                }
                aboutSection
            }
            .navigationTitle("Settings")
            .refreshable { await store.refresh() }
        }
        .task {
            notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            await store.ask(.refresh(.projects))
        }
        // Back from iOS Settings: Live Activities may have been allowed there
        .task(id: phase) { activitiesAllowed = ActivityAuthorizationInfo().areActivitiesEnabled }
        // The Mac's copy wins once your last change has had time to reach it
        .onChange(of: remote) { _, _ in
            if Date().timeIntervalSince(editedAt) > 8 { edited = nil }
        }
    }

    /// Shows the change at once and sends it to the Mac a moment later (the latest of the same kind wins).
    private func change(_ change: MacSettingChange) {
        guard let current = settings else { return }
        edited = current.applying(change)
        editedAt = Date()
        let kind = String(String(describing: change).prefix { $0 != "(" })
        sending[kind]?.cancel()
        sending[kind] = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            editedAt = Date()
            await store.ask(.setting(change), followUp: false)
        }
    }

    private func binding<T>(_ key: KeyPath<MacSettings, T>, _ make: @escaping (T) -> MacSettingChange) -> Binding<T> {
        Binding(get: { settings![keyPath: key] }, set: { change(make($0)) })
    }

    // MARK: Sections

    private var linkSection: some View {
        Section {
            HStack(spacing: 12) {
                FaceView(mood: store.problem == nil ? .calm : .worried, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.problem == nil ? "Linked to \(store.state.macName)" : "Not linked").font(.headline)
                    if let problem = store.problem {
                        Text(problem).font(.caption).foregroundStyle(PhoneTheme.failed)
                    } else if store.state.updated > .distantPast {
                        Text("Updated \(store.state.updated, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            switch notifications {
            case .denied:
                Button("Turn on notifications in iOS Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            case .notDetermined:
                Button("Allow notifications") {
                    Task {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                    }
                }
            default:
                Button("Send a test notification") { Task { await store.ask(.testAlert, followUp: false) } }
                    .disabled(store.problem != nil)
            }
        } footer: {
            Text("WatchMan on your Mac shares its sessions through your private iCloud. Both need the same Apple ID.")
        }
    }

    /// This iPhone's own choices: the Live Activity and its place in the Dynamic Island.
    private var iphoneSection: some View {
        Section {
            Toggle("Live Activity", isOn: $liveActivity)
                .onChange(of: liveActivity) { _, on in
                    PhoneSettings.liveActivity = on
                    Task { await applyLiveActivity() }
                }
            if liveActivity {
                Toggle("Dynamic Island", isOn: $dynamicIsland)
                    .onChange(of: dynamicIsland) { _, on in
                        PhoneSettings.dynamicIsland = on
                        Task { await applyLiveActivity() }
                    }
                if !activitiesAllowed {
                    Button("Allow Live Activities in iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
        } header: {
            Text("This iPhone")
        } footer: {
            Text("The Live Activity shows what needs you and what's working on the Lock Screen and in the Dynamic Island while sessions work or wait. It starts when you open WatchMan. With Dynamic Island off, the island stays plain and only the Lock Screen shows the details; iOS doesn't let an app leave the island out entirely.")
        }
    }

    /// The Live Activity follows the switches at once, from the last thing the Mac said.
    private func applyLiveActivity() async {
        if let glance = GlanceStore.load() {
            await LiveActivity.update(glance)
        } else if !liveActivity {
            await LiveActivity.endAll()
        }
    }

    private func answeringSection(_ s: MacSettings) -> some View {
        Section {
            Toggle("Answer prompts from WatchMan", isOn: binding(\.approvalsEnabled, MacSettingChange.approvals))
            if s.approvalsEnabled {
                Stepper(value: binding(\.handBackSeconds, MacSettingChange.handBackSeconds), in: MacSettings.Range.handBackSeconds, step: 5) {
                    LabeledContent("Hand permissions back after", value: "\(Int(s.handBackSeconds)) s")
                }
                Stepper(value: binding(\.awayHoldMinutes, MacSettingChange.awayHoldMinutes), in: MacSettings.Range.awayHoldMinutes) {
                    LabeledContent("While you're away, wait", value: "\(Int(s.awayHoldMinutes)) min")
                }
            }
        } header: {
            Text("Prompts")
        } footer: {
            Text("WatchMan holds Claude's permission prompts, questions and plans so you can answer them here or on the Mac. Questions wait as long as Claude Code allows.")
        }
    }

    private func alertsSection(_ s: MacSettings) -> some View {
        Section {
            Toggle("Alerts on this iPhone", isOn: binding(\.iphoneAlerts, MacSettingChange.iphoneAlerts))
            if s.iphoneAlerts {
                Toggle("Only when I'm away from the Mac", isOn: binding(\.iphoneAlertsWhenAway, MacSettingChange.iphoneAlertsWhenAway))
                Toggle("Finished turns too", isOn: Binding(get: { s.iphoneFinishedAlerts ?? true },
                                                          set: { change(.iphoneFinishedAlerts($0)) }))
            }
            Stepper(value: binding(\.awayAfterMinutes, MacSettingChange.awayAfterMinutes), in: MacSettings.Range.awayAfterMinutes) {
                LabeledContent("Away after", value: "\(Int(s.awayAfterMinutes)) min idle")
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text("Alerts come for what needs you, an error, the usage limit and finished turns; work starting or going on shows only in the Live Activity. Away means the Mac has been idle that long, or is locked.")
        }
    }

    private func macSection(_ s: MacSettings) -> some View {
        Section("On the Mac") {
            Toggle("Messages under the notch", isOn: binding(\.notchMessages, MacSettingChange.notchMessages))
            Toggle("Sounds", isOn: binding(\.sounds, MacSettingChange.sounds))
            if s.sounds {
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: binding(\.volume, MacSettingChange.volume), in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Volume")
            }
            Toggle("Continue by itself when a usage limit resets", isOn: binding(\.autoContinue, MacSettingChange.autoContinue))
        }
    }

    private func quietSection(_ s: MacSettings) -> some View {
        Section {
            if let until = s.quietUntil, until > Date() {
                LabeledContent("Quiet until", value: until.formatted(date: .omitted, time: .shortened))
                Button("End quiet now") { change(.quietUntil(nil)) }
            } else {
                Button("Quiet for an hour") { change(.quietUntil(Date().addingTimeInterval(3600))) }
                Button("Quiet until tomorrow morning") { change(.quietUntil(Self.tomorrowMorning)) }
            }
            Toggle("Quiet while presenting", isOn: binding(\.quietWhilePresenting, MacSettingChange.quietWhilePresenting))
        } header: {
            Text("Quiet")
        } footer: {
            Text("No sounds or messages on the Mac; the notch still shows what needs you.")
        }
    }

    private static var tomorrowMorning: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private func stuckSection(_ s: MacSettings) -> some View {
        Section("Stuck sessions") {
            Toggle("Warn when a session looks stuck", isOn: binding(\.stuckAlerts, MacSettingChange.stuckAlerts))
            if s.stuckAlerts {
                Stepper(value: binding(\.stuckIdleMinutes, MacSettingChange.stuckIdleMinutes), in: MacSettings.Range.stuckIdleMinutes) {
                    LabeledContent("No activity for", value: "\(Int(s.stuckIdleMinutes)) min")
                }
                Stepper(value: binding(\.stuckRepeatCount, MacSettingChange.stuckRepeatCount), in: MacSettings.Range.stuckRepeatCount) {
                    LabeledContent("Same step failing", value: "\(s.stuckRepeatCount) times")
                }
                Stepper(value: binding(\.stuckLongRunMinutes, MacSettingChange.stuckLongRunMinutes),
                        in: MacSettings.Range.stuckLongRunMinutes, step: 5) {
                    LabeledContent("Running longer than", value: "\(Int(s.stuckLongRunMinutes)) min")
                }
            }
        }
    }

    private func devLogSection(_ s: MacSettings) -> some View {
        Section {
            Toggle("Write a Dev Log note every evening", isOn: binding(\.devLog, MacSettingChange.devLog))
            if s.devLog {
                DatePicker("At", selection: Binding(get: {
                    Calendar.current.date(bySettingHour: s.devLogMinutes / 60, minute: s.devLogMinutes % 60, second: 0, of: Date()) ?? Date()
                }, set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    change(.devLogMinutes((parts.hour ?? 23) * 60 + (parts.minute ?? 0)))
                }), displayedComponents: .hourAndMinute)
                Toggle("Summarize each session with Haiku", isOn: binding(\.devLogHaiku, MacSettingChange.devLogHaiku))
            }
        } header: {
            Text("Daily Dev Log")
        } footer: {
            Text("A note in Obsidian with what every session did that day.")
        }
    }

    private func repliesSection(_ s: MacSettings) -> some View {
        Section {
            ForEach(Array(s.quickReplies.enumerated()), id: \.offset) { _, reply in
                Text(reply)
            }
            .onDelete { offsets in
                var replies = s.quickReplies
                replies.remove(atOffsets: offsets)
                change(.quickReplies(replies))
            }
            .onMove { from, to in
                var replies = s.quickReplies
                replies.move(fromOffsets: from, toOffset: to)
                change(.quickReplies(replies))
            }
            HStack {
                TextField("Add a quick reply", text: $newReply)
                    .onSubmit(addReply)
                Button("Add", action: addReply)
                    .disabled(newReply.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Quick replies")
        } footer: {
            Text("For projects without their own. Swipe to remove.")
        }
    }

    private func addReply() {
        let text = newReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let current = settings else { return }
        newReply = ""
        change(.quickReplies(current.quickReplies + [text]))
    }

    @ViewBuilder
    private var projectsSection: some View {
        Section {
            if let projects = store.extras?.projects {
                if projects.isEmpty {
                    Text("No projects yet.").foregroundStyle(.secondary)
                }
                ForEach(projects) { project in
                    Toggle(isOn: Binding(get: { mutedOverride[project.root] ?? project.muted }, set: { on in
                        mutedOverride[project.root] = on
                        Task { await store.ask(.setting(.muted(project: project.root, on))) }
                    })) {
                        HStack(spacing: 10) {
                            ProjectBadge(name: project.name, key: project.root, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.name)
                                Text(project.group).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                WaitingForMac()
            }
        } header: {
            Text("Muted projects")
        } footer: {
            Text("A muted project makes no sounds, messages or phone alerts.")
        }
        .onChange(of: store.extras?.projects) { _, _ in mutedOverride = [:] }
    }

    @State private var mutedOverride: [String: Bool] = [:]

    private var aboutSection: some View {
        Section {
            Link("Privacy Policy", destination: WatchManWeb.privacy)
            Link("Help and Support", destination: WatchManWeb.support)
            Link("WatchMan for Mac", destination: WatchManWeb.macDownload)
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            MacNoteLine(store: store)
        }
    }
}

/// WatchMan's pages on the web: the privacy policy, help, and the Mac app's download.
enum WatchManWeb {
    static let privacy = URL(string: "https://github.com/A7mdMosa/WatchMan/blob/main/PRIVACY.md")!
    static let support = URL(string: "https://github.com/A7mdMosa/WatchMan/blob/main/SUPPORT.md")!
    static let macDownload = URL(string: "https://github.com/A7mdMosa/WatchMan/releases/latest")!
}
