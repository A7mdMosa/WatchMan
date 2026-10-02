import AppKit
import SwiftUI
import WatchManCore

/// Settings → Projects: per-project quick replies, starter skills, colour and finish sound.
struct ProjectSettingsSection: View {
    @State private var selected: String = ""
    private var projects: ProjectSettings { ProjectSettings.shared }

    var body: some View {
        Section("Projects") {
            Picker("Project", selection: $selected) {
                Text("Choose a project…").tag("")
                ForEach(projects.knownProjects, id: \.self) { root in
                    Text((root as NSString).lastPathComponent).tag(root)
                }
            }
            if !selected.isEmpty {
                ProjectEditor(root: selected).id(selected)
            } else {
                Text("Projects get defaults from what they are: Flutter apps get \"run flutter analyze and flutter test\", web apps \"run the tests\" and \"npm run build\". Override them here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { ObsidianIndex.shared.refreshIfNeeded() }
    }
}

private struct ProjectEditor: View {
    let root: String
    @State private var replies = ""
    @State private var starters = ""
    @State private var color = Color.white
    @State private var hasColor = false
    @State private var sound = ""
    @State private var muted = false

    private var projects: ProjectSettings { ProjectSettings.shared }

    var body: some View {
        Group {
            LabeledContent("Kind", value: projects.kind(of: root).rawValue.capitalized)
            Toggle("Mute this project (no sounds, messages or phone alerts)", isOn: $muted)
                .onChange(of: muted) { _, on in projects.update(root) { $0.muted = on ? true : nil } }
            VStack(alignment: .leading, spacing: 4) {
                Text("Quick replies (one per line, empty = defaults)").font(.caption)
                TextEditor(text: $replies)
                    .font(.body.monospaced())
                    .frame(height: 80)
                    .onChange(of: replies) { _, text in projects.update(root) { $0.quickReplies = lines(text) } }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Starter skills for + New (one per line, empty = defaults)").font(.caption)
                TextEditor(text: $starters)
                    .font(.body.monospaced())
                    .frame(height: 60)
                    .onChange(of: starters) { _, text in projects.update(root) { $0.starters = lines(text) } }
            }
            HStack {
                Toggle("Own colour", isOn: $hasColor)
                    .onChange(of: hasColor) { _, on in projects.update(root) { $0.colorHex = on ? color.hexString : nil } }
                ColorPicker("", selection: $color, supportsOpacity: false)
                    .labelsHidden()
                    .disabled(!hasColor)
                    .onChange(of: color) { _, value in if hasColor { projects.update(root) { $0.colorHex = value.hexString } } }
            }
            HStack {
                Picker("Finish sound", selection: $sound) {
                    Text("Default").tag("")
                    ForEach(ProjectSettings.sounds, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: sound) { _, value in
                    projects.update(root) { $0.sound = value.isEmpty ? nil : value }
                    if !value.isEmpty { Sounds.preview(value) }
                }
            }
        }
        .onAppear {
            let prefs = projects.prefs(for: root)
            replies = prefs.quickReplies?.joined(separator: "\n") ?? ""
            starters = prefs.starters?.joined(separator: "\n") ?? ""
            hasColor = prefs.colorHex != nil
            color = prefs.colorHex.flatMap { Color(hex: $0) } ?? Theme.hashedColor(root)
            sound = prefs.sound ?? ""
            muted = prefs.muted == true
        }
    }

    private func lines(_ text: String) -> [String]? {
        let list = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return list.isEmpty ? nil : list
    }
}
