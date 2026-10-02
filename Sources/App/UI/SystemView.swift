import AppKit
import SwiftUI
import WatchManCore

/// Memory, heavy leftovers and plan usage.
struct SystemView: View {
    let store: SessionStore
    @State private var memory = MemoryStatus.current()
    @State private var table = ProcessTable(entries: [])
    @State private var usage: UsageSummary?
    @State private var confirmStray: ProcessTable.Stray?
    @State private var writingDigest = false
    @State private var digestPath: String?
    @State private var digestMessage: String?

    private func writeDigest() {
        writingDigest = true
        digestMessage = AppSettings.shared.digestUsesHaiku ? "Summarizing sessions…" : nil
        Task {
            do {
                digestPath = try await DigestWriter.writeToday()
                digestMessage = "Written"
            } catch {
                digestMessage = "Couldn't write: \(error.localizedDescription)"
            }
            writingDigest = false
        }
    }

    private var budget: Int { AppSettings.shared.blockBudget }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Two numbers at a glance: memory and this block's tokens
            HStack(alignment: .top, spacing: 10) {
                card {
                    label("Memory")
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(memory.usedGB, specifier: "%.1f")").font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.primary).monospacedDigit()
                        Text("of \(memory.totalGB, specifier: "%.0f") GB").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        Spacer()
                        chip("pressure \(memory.pressureLabel)", memory.pressureColor)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(memory.pressureColor).frame(width: geo.size.width * memory.usedFraction)
                        }
                    }
                    .frame(height: 6)
                }
                card {
                    label("Claude usage")
                    if let usage {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(UsageSummary.format(usage.currentBlockTokens)).font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.primary).monospacedDigit()
                            Text("tokens this block").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            Spacer()
                            if budget > 0 {
                                chip("\(Int(Double(usage.currentBlockTokens) / Double(budget) * 100))% of budget", Theme.unseen)
                            }
                        }
                        Text([usage.currentBlockEnd.map { "resets \($0.formatted(date: .omitted, time: .shortened))" },
                              "\(UsageSummary.format(usage.lastSevenDaysTokens)) in the last 7 days"].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(Theme.faint)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            // Both cards as tall as the taller one
            .fixedSize(horizontal: false, vertical: true)

            if !sessionMemory.isEmpty {
                card {
                    label("Memory by session")
                    ForEach(sessionMemory.prefix(6), id: \.name) { item in
                        HStack {
                            Text(item.name).font(.system(size: 12)).foregroundStyle(Theme.primary).lineLimit(1)
                            Spacer()
                            Text("\(item.mb) MB").font(.system(size: 11.5, design: .rounded)).monospacedDigit().foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }

            let strays = table.strays()
            if !strays.isEmpty {
                card {
                    label("Leftovers you can close")
                    ForEach(strays) { stray in
                        HStack {
                            Text(stray.kind).font(.system(size: 12)).foregroundStyle(Theme.primary)
                            Text("\(stray.rssKB / 1024) MB").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            Spacer()
                            PillButton(title: "Quit", symbol: "xmark", tint: Theme.failed) { confirmStray = stray }
                        }
                    }
                }
            }

            card {
                label("Dev Log")
                HStack(spacing: 10) {
                    Text("Today's note in Obsidian: what every session did, with links.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let digestPath {
                        Button("Open") { ObsidianIndex.shared.openNote(path: digestPath) }
                            .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.obsidian)
                    }
                    PillButton(title: writingDigest ? "Writing…" : "Write now", symbol: "book.pages") { writeDigest() }
                        .disabled(writingDigest)
                }
                if let digestMessage {
                    Text(digestMessage).font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                }
            }
        }
        .task {
            // Refresh while the tab is on screen
            while !Task.isCancelled {
                memory = MemoryStatus.current()
                table = await ProcessSnapshot.current()
                usage = await UsageTracker.shared.summary()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .onChange(of: confirmStray) { _, stray in store.isEditing = stray != nil }
        .alert(item: $confirmStray) { stray in
            Alert(title: Text("Quit \(stray.kind)?"),
                  message: Text("Process \(stray.pid) uses \(stray.rssKB / 1024) MB. Gradle and emulators restart when needed."),
                  primaryButton: .destructive(Text("Quit")) {
                      kill(stray.pid, SIGTERM)
                      Task { table = await ProcessSnapshot.current() }
                  },
                  secondaryButton: .cancel())
        }
    }

    private var sessionMemory: [(name: String, mb: Int)] {
        store.ordered.compactMap { session in
            guard let pid = session.pid else { return nil }
            let kb = table.treeRSSKB(of: pid)
            return kb > 0 ? (session.displayName, kb / 1024) : nil
        }
        .sorted { $0.mb > $1.mb }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func label(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.faint)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).frame(height: 18)
            .background(color.opacity(0.15), in: Capsule())
            .fixedSize()
    }
}

/// Physical memory use and the kernel's pressure level.
/// Memory in one word next to the title; click for the System page (memory, leftovers, usage, Dev Log).
struct MemoryChip: View {
    let store: SessionStore
    @State private var memory = MemoryStatus.current()

    /// Only when memory is tight; the toolbar's gauge opens the System page otherwise.
    var body: some View {
        if memory.pressureLevel >= 2 { chip } else { Color.clear.frame(width: 0, height: 0).task { await watch() } }
    }

    private func watch() async {
        while !Task.isCancelled {
            memory = MemoryStatus.current()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private var chip: some View {
        Button { store.otherPage = .system } label: {
            HStack(spacing: 4) {
                Circle().fill(memory.pressureColor).frame(width: 6, height: 6)
                Text("Memory \(memory.pressureLabel)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(memory.pressureLevel >= 2 ? memory.pressureColor : Theme.secondary)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Memory, leftover processes, token usage and the Dev Log")
        .task { await watch() }
    }
}

struct MemoryStatus {
    var usedBytes: UInt64
    var totalBytes: UInt64
    var pressureLevel: Int   // 1 normal, 2 warning, 4 critical

    var usedGB: Double { Double(usedBytes) / 1_073_741_824 }
    var totalGB: Double { Double(totalBytes) / 1_073_741_824 }
    var usedFraction: Double { totalBytes == 0 ? 0 : min(1, Double(usedBytes) / Double(totalBytes)) }
    var pressureLabel: String { pressureLevel >= 4 ? "critical" : pressureLevel >= 2 ? "high" : "normal" }
    var pressureColor: Color { pressureLevel >= 4 ? Theme.failed : pressureLevel >= 2 ? Theme.needsYou : Theme.working }

    static func current() -> MemoryStatus {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let page = UInt64(getpagesize())
        let used = result == KERN_SUCCESS
            ? (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
            : 0
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return MemoryStatus(usedBytes: used, totalBytes: ProcessInfo.processInfo.physicalMemory, pressureLevel: Int(level))
    }
}

/// Token usage across every transcript touched this week, read incrementally.
actor UsageTracker {
    static let shared = UsageTracker()
    private var files: [String: (offset: UInt64, state: TranscriptState)] = [:]

    func summary() -> UsageSummary {
        let fm = FileManager.default
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        var all: [TranscriptState.UsageEntry] = []
        let root = WatchManPaths.claudeProjectsDirectory
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified > weekAgo else { continue }
                all += entries(for: file)
            }
        }
        return UsageSummary.compute(entries: all, now: Date())
    }

    /// Tokens by project since `since` (the week's start), most first. A project is the folder its sessions run in.
    func projectTotals(since: Date) -> [(name: String, tokens: Int)] {
        let fm = FileManager.default
        var totals: [String: Int] = [:]
        let root = WatchManPaths.claudeProjectsDirectory
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified > since else { continue }
                let tokens = entries(for: file).filter { $0.at > since }.reduce(0) { $0 + $1.tokens }
                guard tokens > 0 else { continue }
                // The folder from the transcript; the encoded folder name when it doesn't say
                let name = files[file.path]?.state.cwd.map { ($0 as NSString).lastPathComponent }
                    ?? dir.lastPathComponent.split(separator: "-").last.map(String.init) ?? dir.lastPathComponent
                totals[name, default: 0] += tokens
            }
        }
        return totals.map { (name: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }
    }

    /// Reads only what was appended since last time; one parser per file keeps message ids deduplicated.
    private func entries(for url: URL) -> [TranscriptState.UsageEntry] {
        var known = files[url.path] ?? (0, TranscriptState())
        guard let handle = try? FileHandle(forReadingFrom: url) else { return known.state.usage }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < known.offset { known = (0, TranscriptState()) }
        guard size > known.offset else { return known.state.usage }
        try? handle.seek(toOffset: known.offset)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return known.state.usage }
        let complete = data[data.startIndex...lastNewline]
        for line in complete.split(separator: 0x0A) { known.state.consume(line: Data(line)) }
        known.offset += UInt64(complete.count)
        files[url.path] = known
        return known.state.usage
    }
}
