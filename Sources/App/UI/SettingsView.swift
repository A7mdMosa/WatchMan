import AppKit
import ServiceManagement
import SwiftUI
import WatchManCore

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    /// Opens Settings, on `pane` when given (Help → Keyboard Shortcuts).
    func show(pane: SettingsView.Pane? = nil) {
        if let pane, let window {
            window.contentViewController = NSHostingController(rootView: SettingsView(pane: pane))
        }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsView.size.width, height: SettingsView.size.height),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "WatchMan Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(pane: pane ?? .general))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var hooksInstalled = HookInstaller.hooksInstalled
    @State private var hookMessage: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var usageConnected = StatusLineRelay.connected
    @State private var repliesText = AppSettings.shared.quickReplies.joined(separator: "\n")
    @State private var menusReadable = MenuBarSpace.canReadMenus
    @State private var showingShortcuts: Bool

    static let size = CGSize(width: 760, height: 580)

    /// The panes, in the sidebar's order, each with its icon and colour (like System Settings). `keyboard` isn't in
    /// the sidebar: it opens General with the list of keyboard shortcuts (Help → Keyboard Shortcuts).
    enum Pane: String, CaseIterable, Identifiable {
        case general = "General", notch = "Notch", notifications = "Notifications", claudeCode = "Claude Code"
        case iPhone = "iPhone", projects = "Projects", obsidian = "Obsidian"
        case keyboard = "Keyboard"
        var id: Self { self }

        static var sidebar: [Pane] { allCases.filter { $0 != .keyboard } }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .notch: "rectangle.topthird.inset.filled"
            case .notifications: "bell.badge.fill"
            case .claudeCode: "terminal.fill"
            case .iPhone: "iphone"
            case .projects: "folder.fill"
            case .obsidian: "book.pages.fill"
            case .keyboard: "keyboard.fill"
            }
        }

        var color: Color {
            switch self {
            case .general: .gray
            case .notch: .blue
            case .notifications: .red
            case .claudeCode: .orange
            case .iPhone: .green
            case .projects: .indigo
            case .obsidian: .purple
            case .keyboard: Color(white: 0.45)
            }
        }

        var subtitle: String {
            switch self {
            case .general, .keyboard: "Setup, startup and updates"
            case .notch: "How the island opens, and what sits beside the notch"
            case .notifications: "Messages, sounds, quiet hours and stuck sessions"
            case .claudeCode: "Permission prompts, usage limits and hooks"
            case .iPhone: "Your sessions and alerts on your iPhone"
            case .projects: "Colours, sounds, mute and quick replies per project"
            case .obsidian: "The daily Dev Log note"
            }
        }
    }
    @State private var pane: Pane

    init(pane: Pane = .general) {
        _pane = State(initialValue: pane == .keyboard ? .general : pane)
        _showingShortcuts = State(initialValue: pane == .keyboard)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                paneHeader
                Group {
                    switch pane {
                    case .general, .keyboard: general
                    case .notch: notch
                    case .notifications: notifications
                    case .claudeCode: claudeCode
                    case .iPhone: iPhone
                    case .projects: projects
                    case .obsidian: obsidian
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .sheet(isPresented: $showingShortcuts) { ShortcutsSheet() }
        // The permission can change in System Settings at any time: re-check while this window is open
        .task {
            while !Task.isCancelled {
                menusReadable = MenuBarSpace.canReadMenus
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    // MARK: - Sidebar

    private var setupDone: Bool { hooksInstalled && menusReadable }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("WatchMan").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 4) {
                        Circle().fill(setupDone ? Color.green : Color.orange).frame(width: 6, height: 6)
                        Text(setupDone ? "Connected" : "Setup needed").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 34)
            .padding(.bottom, 12)
            ForEach(Pane.sidebar) { item in
                Button { pane = item } label: {
                    HStack(spacing: 9) {
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .fill(item.color.gradient)
                            .frame(width: 22, height: 22)
                            .overlay(Image(systemName: item.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
                        Text(item.rawValue).font(.system(size: 13))
                            .foregroundStyle(pane == item ? Color.white : Color.primary)
                        Spacer(minLength: 0)
                        if item == .general, !setupDone {
                            Circle().fill(Color.orange).frame(width: 7, height: 7)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(pane == item ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(pane == item ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 200)
        .background(.regularMaterial)
    }

    private var paneHeader: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(pane.color.gradient)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: pane.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.rawValue).font(.system(size: 20, weight: .bold))
                Text(pane.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 2)
    }

    // MARK: - General

    /// Wraps or restores the status line command in ~/.claude/settings.json.
    private func setUsageRelay(_ on: Bool) {
        Task {
            let result = await StatusLineRelay.set(on)
            usageConnected = StatusLineRelay.connected
            hookMessage = result.status == 0 ? nil : result.output
        }
    }

    private var general: some View {
        Form {
            if !hooksInstalled {
                // First run: what WatchMan is and the one step it can't work without
                Section {
                    HStack(spacing: 14) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Welcome to WatchMan").font(.title2.weight(.semibold))
                            Text("It watches every Claude Code session on this Mac from the notch, the menu bar and its window. Connect it to Claude Code to start.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            // Setup only shows while something is left to do
            if !setupDone {
                Section("Setup") {
                    SetupStep(done: hooksInstalled, title: "Connect to Claude Code",
                              detail: "Adds WatchMan's hook to ~/.claude/settings.json, after a dated backup.") {
                        Button("Install") { runInstaller(remove: false) }
                    }
                    SetupStep(done: menusReadable, title: "Allow Accessibility",
                              detail: "So the notch can use the menu bar beside it without covering menus or icons.") {
                        Button("Allow…") { MenuBarSpace.requestAccess() }
                    }
                    if !menusReadable {
                        Text("Already on in Privacy & Security → Accessibility but still not allowed? That entry belongs to an older WatchMan: remove it with −, then add Applications → WatchMan with + and switch it on.")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Open Accessibility Settings") { MenuBarSpace.openAccessibilitySettings() }
                    }
                    if let hookMessage {
                        Text(hookMessage).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            hookMessage = "Launch at login: \(error.localizedDescription)"
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Show WatchMan in the menu bar", isOn: $settings.showMenuBarIcon)
                Picker("Show in the Dock", selection: $settings.dockIcon) {
                    ForEach(AppSettings.DockIcon.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Follow the screen I'm working on", isOn: $settings.followActiveScreen)
            }
            Section("Keyboard") {
                LabeledContent("Open WatchMan, or go through what's waiting") { ShortcutRecorder() }
                Button("All Keyboard Shortcuts…") { showingShortcuts = true }
            }
            Section("Updates") {
                LabeledContent("Version \(UpdateCheck.shared.current)") {
                    if let update = UpdateCheck.shared.available {
                        Button("Download \(update.version)") { UpdateCheck.shared.openDownload() }
                    } else {
                        Button(UpdateCheck.shared.checking ? "Checking…" : "Check for Updates") { Task { await UpdateCheck.shared.check() } }
                            .disabled(UpdateCheck.shared.checking)
                    }
                }
                if let result = UpdateCheck.shared.lastResult, UpdateCheck.shared.available == nil {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Text("WatchMan stops watching your sessions until you open it again.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit WatchMan", role: .destructive) { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func soundBinding(_ event: SoundEvent) -> Binding<String> {
        Binding(get: { Sounds.name(for: event) }, set: { name in
            settings.eventSounds[event.rawValue] = name
            Sounds.preview(name)
        })
    }

    // MARK: - Notch

    private var notch: some View {
        Form {
            Section("Opening and closing") {
                Toggle("Preview what needs you when I hover the notch", isOn: $settings.hoverPreview)
                if settings.hoverPreview {
                    Stepper("Up to \(settings.hoverRows) session\(settings.hoverRows == 1 ? "" : "s") in the preview",
                            value: $settings.hoverRows, in: 1...20)
                }
                Toggle("Close when I click outside it", isOn: $settings.closeOnClickOutside)
                Toggle("Close when the mouse leaves it", isOn: $settings.closeOnMouseLeave)
            }
            Section {
                Picker("Panel width", selection: $settings.panelWidth) {
                    ForEach(AppSettings.widthPresets, id: \.name) { preset in
                        Text(Self.sizeName(preset.name)).tag(preset.width)
                    }
                }
            } footer: {
                Text("Pin keeps it open. Drag its bottom edge to make it taller.")
            }
            Section {
                Picker("Left of the notch", selection: $settings.notchLeft) {
                    ForEach(AppSettings.LeftContent.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Right of the notch", selection: $settings.notchRight) {
                    ForEach(AppSettings.RightContent.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } header: {
                Text("Beside the notch")
            } footer: {
                Text("Left shows WatchMan's ball and what's happening; right shows the counts. A side with no room hands its content to the other.")
            }
        }
        .formStyle(.grouped)
    }

    static func sizeName(_ preset: String) -> String {
        switch preset {
        case "S": "Small"
        case "M": "Medium"
        case "L": "Large"
        default: "Extra large"
        }
    }

    // MARK: - Notifications

    private var notifications: some View {
        Form {
            Section {
                Toggle("Show messages under the notch", isOn: $settings.notchPopEnabled)
                if settings.notchPopEnabled {
                    Picker("When something happens", selection: $settings.newsStyle) {
                        ForEach(AppSettings.NewsStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if settings.newsStyle == .full {
                        Stepper("Keep a finished message for \(Int(settings.popDuration)) s", value: $settings.popDuration, in: 2...30, step: 1)
                    }
                }
            } header: {
                Text("Messages")
            } footer: {
                Text("Not shown when you're already in that session's app. Mute a project in Projects. A session starting or finishing, a warning, the usage limit: the ball reacts and the line beside the notch says it. Prompts that need an answer always come with their buttons.")
            }
            Section("Sounds") {
                Toggle("Play sounds", isOn: $settings.soundEnabled)
                if settings.soundEnabled {
                    HStack(spacing: 8) {
                        Text("Volume")
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $settings.soundVolume, in: 0...1) { editing in
                            if !editing { Sounds.preview(Sounds.name(for: .finished)) }
                        }
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                    DisclosureGroup("A sound for each moment") {
                        ForEach(SoundEvent.allCases) { event in
                            HStack {
                                Picker(event.title, selection: soundBinding(event)) {
                                    Text("None").tag("None")
                                    Divider()
                                    ForEach(Sounds.names, id: \.self) { Text($0).tag($0) }
                                }
                                Button { Sounds.preview(Sounds.name(for: event)) } label: { Image(systemName: "play.fill") }
                                    .buttonStyle(.borderless)
                                    .help("Play it")
                                    .accessibilityLabel("Play the \(event.title) sound")
                            }
                        }
                    }
                }
            }
            Section {
                Toggle("Quiet while presenting", isOn: $settings.quietWhilePresenting)
                HStack {
                    if settings.quietUntil > Date().timeIntervalSince1970 {
                        Text("Quiet until \(Date(timeIntervalSince1970: settings.quietUntil).formatted(date: .omitted, time: .shortened))")
                        Spacer()
                        Button("End Quiet") { Quiet.end() }
                    } else {
                        Button("Quiet for 1 Hour") { Quiet.silence(for: 3600) }
                        Button("Quiet Until Tomorrow") { Quiet.untilTomorrow() }
                    }
                }
            } header: {
                Text("Quiet")
            } footer: {
                Text("No sounds and no messages; the notch still shows what needs you.")
            }
            Section("Stuck sessions") {
                Toggle("Warn when a session looks stuck", isOn: $settings.stuckAlertsEnabled)
                if settings.stuckAlertsEnabled {
                    DisclosureGroup("When to warn") {
                        Stepper("No activity for \(Int(settings.stuckIdleMinutes)) min", value: $settings.stuckIdleMinutes, in: 3...60)
                        Stepper("Same step failing \(settings.stuckRepeatCount) times in a row", value: $settings.stuckRepeatCount, in: 2...10)
                        Stepper("Running longer than \(Int(settings.stuckLongRunMinutes)) min", value: $settings.stuckLongRunMinutes,
                                in: 15...240, step: 15)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Claude Code

    private var claudeCode: some View {
        Form {
            Section {
                Toggle("Answer permission prompts from WatchMan", isOn: $settings.approvalsEnabled)
                if settings.approvalsEnabled {
                    Stepper("Hand back to the terminal after \(Int(settings.approvalTimeout)) s",
                            value: $settings.approvalTimeout, in: 15...110, step: 5)
                    Stepper("While I'm away, wait \(Int(settings.awayHoldMinutes)) min for my phone",
                            value: $settings.awayHoldMinutes, in: 2...9)
                }
            } header: {
                Text("Permission prompts")
            } footer: {
                Text("Risky commands, edits and long commands always open the session's page to read first.")
            }
            Section("Usage limits") {
                Toggle("Continue automatically when a usage limit resets", isOn: $settings.autoContinue)
                LabeledContent("Plan usage") {
                    HStack(spacing: 10) {
                        Text(usageConnected ? "From the status line" : "Not connected").foregroundStyle(.secondary)
                        Button(usageConnected ? "Disconnect" : "Connect") { setUsageRelay(!usageConnected) }
                    }
                }
                .help("Passes Claude Code's status line data to WatchMan; your status line keeps printing what it does now")
                if !usageConnected {
                    TextField("Token budget per 5-hour block", value: $settings.blockBudget, format: .number)
                }
            }
            Section {
                LabeledContent("Hooks") {
                    HStack(spacing: 10) {
                        Text(hooksInstalled ? "Installed" : "Not installed").foregroundStyle(hooksInstalled ? .green : .orange)
                        Button(hooksInstalled ? "Reinstall" : "Install") { runInstaller(remove: false) }
                        if hooksInstalled { Button("Remove") { runInstaller(remove: true) } }
                    }
                }
                if let hookMessage {
                    Text(hookMessage).font(.caption.monospaced()).textSelection(.enabled)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Edits ~/.claude/settings.json after a dated backup; your other hooks stay as they are.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - iPhone

    private var iPhone: some View {
        Form {
            Section {
                LabeledContent("Link through iCloud") {
                    switch CloudPublisher.current?.state ?? .starting {
                    case .starting: Text("Starting…").foregroundStyle(.secondary)
                    case .off(let why): Text(why).foregroundStyle(.orange)
                    case .on(let last):
                        Text(last.map { "On · last update \($0.formatted(date: .omitted, time: .shortened))" } ?? "On")
                            .foregroundStyle(.green)
                    }
                }
                Toggle("Send alerts to my iPhone", isOn: $settings.iphoneAlerts)
                if settings.iphoneAlerts {
                    Toggle("Only when I'm away from the Mac", isOn: $settings.iphoneAlertsWhenAway)
                    Toggle("Finished turns too", isOn: $settings.iphoneFinishedAlerts)
                }
                Button("Send Test Alert") { CloudPublisher.current?.sendTestAlert() }
                    .disabled(CloudPublisher.current?.isOn != true)
            } header: {
                Text("WatchMan for iPhone")
            } footer: {
                Text("Uses your private iCloud, chats end-to-end encrypted. Open WatchMan on an iPhone with the same Apple ID.")
            }
            Section {
                DisclosureGroup("Without the iPhone app (ntfy)") {
                    TextField("ntfy topic", text: $settings.ntfyTopic, prompt: Text("e.g. watchman-yourname-7f3k"))
                    Stepper("Only when idle for \(Int(settings.ntfyIdleMinutes)) min or locked", value: $settings.ntfyIdleMinutes, in: 1...60)
                    Toggle("Allow / Deny / Continue buttons on alerts", isOn: $settings.phoneActionsEnabled)
                    if settings.phoneActionsEnabled && !settings.ntfyTopic.isEmpty {
                        LabeledContent("Secret reply topic") {
                            HStack {
                                Text(settings.ntfyReplyTopic.isEmpty ? "made when buttons start" : settings.ntfyReplyTopic)
                                    .font(.caption.monospaced()).textSelection(.enabled)
                                Button("New") { PhoneBridge.shared.regenerateReplyTopic() }
                            }
                        }
                    }
                    Button("Send Test") {
                        PhoneAlerts.send(topic: settings.ntfyTopic, title: "WatchMan", message: "Test alert from your Mac")
                    }
                    .disabled(settings.ntfyTopic.isEmpty)
                    Text("Install the free ntfy app and subscribe to the same, hard-to-guess topic. Don't subscribe to the reply topic.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Projects

    private var projects: some View {
        Form {
            ProjectSettingsSection()
            Section("Quick replies for every project (one per line)") {
                TextEditor(text: $repliesText)
                    .font(.body.monospaced())
                    .frame(height: 100)
                    .onChange(of: repliesText) { _, text in
                        settings.quickReplies = text.split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Obsidian

    private var obsidian: some View {
        Form {
            Section {
                LabeledContent("Vault") {
                    HStack {
                        Text(ObsidianIndex.vaultName ?? "None found").foregroundStyle(.secondary)
                        Button("Choose…") { chooseVault() }
                    }
                }
                TextField("Dev Log folder", text: $settings.devLogFolder, prompt: Text(AppSettings.defaultDevLogFolder))
            } header: {
                Text("Vault")
            } footer: {
                Text("WatchMan reads project notes linked by project-sync and writes only the Dev Log, in this folder of the vault.")
            }
            Section {
                Toggle("Write a Dev Log note every evening", isOn: $settings.digestEnabled)
                    .onChange(of: settings.digestEnabled) { _, _ in DigestWriter.startSchedule() }
                if settings.digestEnabled {
                    Stepper("At \(String(format: "%02d:%02d", settings.digestMinutes / 60, settings.digestMinutes % 60))",
                            value: $settings.digestMinutes, in: 0...(24 * 60 - 30), step: 30)
                        .onChange(of: settings.digestMinutes) { _, _ in DigestWriter.startSchedule() }
                }
                Toggle("Summarize each session with Haiku", isOn: $settings.digestUsesHaiku)
            } header: {
                Text("Daily Dev Log")
            } footer: {
                Text("Saved to \(DigestWriter.folderPath)/<date>.md; written on wake if the Mac slept through the time.")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Vault"
        panel.message = "Choose your Obsidian vault's folder"
        panel.directoryURL = ObsidianIndex.vault
        if panel.runModal() == .OK, let url = panel.url { settings.obsidianVault = url.path }
    }

    private func runInstaller(remove: Bool) {
        Task {
            let result = await HookInstaller.run(remove: remove)
            hookMessage = result.output
            hooksInstalled = HookInstaller.hooksInstalled
            AppHealth.shared.refresh()
            HookInstaller.installedPermissionTimeout = HookInstaller.readPermissionTimeout()
        }
    }
}

/// One setup step: done (a check) or a button to do it.
private struct SetupStep<Action: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !done { action() }
        }
    }
}


/// Records a new system-wide shortcut: click, press keys with ⌘, ⌥ or ⌃ (Esc cancels).
private struct ShortcutRecorder: View {
    @Bindable private var settings = AppSettings.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Press a shortcut…" : settings.hotKeyLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if settings.hotKeyLabel != "⌥Space", !recording {
                Button("Reset") { save(code: 49, modifiers: 2048, label: "⌥Space") }
                    .buttonStyle(.borderless)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }   // Esc
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return nil }
            var carbon = 0
            if flags.contains(.command) { carbon |= 256 }
            if flags.contains(.shift) { carbon |= 512 }
            if flags.contains(.option) { carbon |= 2048 }
            if flags.contains(.control) { carbon |= 4096 }
            let symbols = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
                + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
            save(code: Int(event.keyCode), modifiers: carbon, label: symbols + Self.keyName(event))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func save(code: Int, modifiers: Int, label: String) {
        settings.hotKeyCode = code
        settings.hotKeyModifiers = modifiers
        settings.hotKeyLabel = label
    }

    static func keyName(_ event: NSEvent) -> String {
        switch event.keyCode {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        default: return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

/// Every key WatchMan answers to (Settings → General → All Keyboard Shortcuts, or Help → Keyboard Shortcuts).
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Anywhere") {
                    LabeledContent("Open WatchMan, or go through what's waiting", value: AppSettings.shared.hotKeyLabel)
                }
                Section("In the list") {
                    LabeledContent("Move", value: "↑ ↓")
                    LabeledContent("Open a session's chat", value: "↩  or  1–9")
                    LabeledContent("Allow or deny the selected row's prompt", value: "⌘↩  ·  ⌘⌫")
                    LabeledContent("Open its terminal or editor", value: "O  (or ⌘-click)")
                    LabeledContent("Reply", value: "R")
                    LabeledContent("Close", value: "Esc")
                }
                Section("On a session's page") {
                    LabeledContent("Allow · Deny", value: "⌘↩  ·  ⌘⌫")
                    LabeledContent("Next waiting session · previous", value: "⇥  ·  ⇧⇥")
                    LabeledContent("Open its terminal or editor", value: "O")
                    LabeledContent("Reply", value: "R")
                    LabeledContent("Send now, stopping Claude", value: "⌘↩ in the reply box")
                    LabeledContent("Back to the list", value: "Esc")
                }
                Section("On the island") {
                    LabeledContent("Dismiss a message or the preview", value: "Two-finger swipe up")
                    LabeledContent("Open the panel", value: "Two-finger swipe down")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 520, height: 540)
    }
}
