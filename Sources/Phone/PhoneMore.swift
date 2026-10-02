import CloudKit
import PhotosUI
import SwiftUI
import UIKit
import WatchManCore

// MARK: - Is the Mac there?

/// When the phone last asked the Mac whether it's there. The Mac answers by publishing the time it heard,
/// so a missing answer means it's asleep, offline, or WatchMan isn't running.
@MainActor @Observable
final class MacReach {
    static let shared = MacReach()
    private(set) var askedAt: Date?

    func ping(_ store: PhoneStore) async {
        askedAt = Date()
        await store.ask(.ping)
    }

    /// Asked a while ago and the Mac hasn't answered since.
    func silent(_ store: PhoneStore, now: Date = Date()) -> Bool {
        guard let askedAt, now.timeIntervalSince(askedAt) > 15, store.problem == nil else { return false }
        return (store.extras?.answeredAt ?? .distantPast) < askedAt
    }
}

/// "Your Mac isn't answering", above the sessions, when the ping went unanswered.
struct MacReachBanner: View {
    let store: PhoneStore
    @Environment(\.scenePhase) private var phase
    private var reach: MacReach { .shared }

    var body: some View {
        VStack(spacing: 8) {
            reachBanner
        }
    }

    private var reachBanner: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if reach.silent(store, now: context.date) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Your Mac isn't answering", systemImage: "moon.zzz.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PhoneTheme.limit)
                    Text("It may be asleep, offline, or WatchMan isn't open. What you see is from \(lastHeard.formatted(.relative(presentation: .named))).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try again") { Task { await reach.ping(store) } }
                        .font(.caption.weight(.semibold))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PhoneTheme.limit.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        // Each time the app comes to the front
        .task(id: phase) { if phase == .active { await reach.ping(store) } }
    }

    /// The newest thing the Mac wrote.
    private var lastHeard: Date {
        ([store.state.updated, store.extras?.answeredAt ?? .distantPast] + store.state.sessions.map(\.updated)).max() ?? .distantPast
    }
}

// MARK: - Photos in a reply

extension PhoneStore {
    /// A reply with photos: the photos travel as files with the command, and the Mac puts their paths after your
    /// words, the way its own attachments go. Returns why it failed, or nil.
    func reply(_ text: String, photos: [Data], to sessionId: String) async -> String? {
        let command = PhoneCommand(sessionId: sessionId, kind: .reply(text))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WatchManPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [URL] = []
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        do {
            let record = try CloudRecords.record(CloudRecords.Kind.command, name: command.id.uuidString, command)
            for (index, data) in photos.enumerated() {
                let file = folder.appendingPathComponent("\(command.id.uuidString)-\(index).jpg")
                try data.write(to: file)
                files.append(file)
            }
            record["photos"] = files.map { CKAsset(fileURL: $0) }
            _ = try await CloudRecords.container.privateCloudDatabase.save(record)
            return nil
        } catch {
            return "Couldn't send the photos: \(error.localizedDescription)"
        }
    }
}

/// Photos picked for a reply, as JPEGs small enough to send quickly (2048 px at most on the long side).
enum PhonePhotos {
    static func jpeg(from item: PhotosPickerItem) async -> Data? {
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return nil }
        return jpeg(image)
    }

    /// An image pasted from the clipboard (a screenshot, a copied photo), the same way.
    static func jpeg(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 2048 / max(longest, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.75)
    }
}

/// The photos waiting to go with a reply, with a × on each.
struct PhotoStrip: View {
    @Binding var photos: [Data]

    var body: some View {
        if !photos.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { index, data in
                        if let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button { photos.remove(at: index) } label: {
                                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .offset(x: 6, y: -6)
                                    .accessibilityLabel("Remove photo")
                                }
                        }
                    }
                }
                .padding(.top, 6)
                .padding(.horizontal, 2)
            }
        }
    }
}

// MARK: - Earlier messages

/// Above the chat when it has more than the phone holds: asks the Mac for a hundred more.
struct EarlierMessagesButton: View {
    let store: PhoneStore
    let sessionId: String
    @State private var asking = false

    var body: some View {
        if let chat = store.chats[sessionId], let total = chat.total, total > chat.items.count {
            Button {
                asking = true
                Task {
                    await store.ask(.chat(limit: chat.items.count + 100), session: sessionId, followUp: false)
                    for wait in [2.0, 3.0, 5.0] {
                        try? await Task.sleep(for: .seconds(wait))
                        await store.loadChat(sessionId)
                        if (store.chats[sessionId]?.items.count ?? 0) > chat.items.count { break }
                    }
                    asking = false
                }
            } label: {
                HStack(spacing: 6) {
                    if asking { ProgressView().controlSize(.small) }
                    Text(asking ? "Loading earlier messages…" : "Load earlier messages (\(total - chat.items.count) more)")
                }
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(asking || chat.items.count >= ChatSnapshot.largestLimit)
        }
    }
}

/// A chat the Mac hasn't shared yet (an older session): ask for it once the page opens.
extension PhoneStore {
    func loadChatAsking(_ sessionId: String) async {
        await loadChat(sessionId)
        guard chats[sessionId] == nil else { return }
        await send(.mac(.chat(limit: ChatSnapshot.maxItems)), to: sessionId)
        for wait in [2.0, 3.0, 5.0] {
            try? await Task.sleep(for: .seconds(wait))
            await loadChat(sessionId)
            if chats[sessionId] != nil { return }
        }
    }
}

// MARK: - Uncommitted changes

/// The project's uncommitted changes, as the Mac's Changes tab shows them: each file with its diff.
struct ProjectChangesSection: View {
    let store: PhoneStore
    let session: SessionSnapshot

    private var changes: ProjectChanges? {
        guard let changes = store.extras?.changes, changes.sessionId == session.id else { return nil }
        return changes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Not committed").font(.headline)
                Spacer()
                Button { Task { await store.ask(.changes, session: session.id) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh changes")
            }
            if let changes {
                if changes.root.isEmpty {
                    Text("WatchMan doesn't know this session's project yet.").font(.callout).foregroundStyle(.secondary)
                } else if changes.files.isEmpty {
                    Text("No uncommitted changes.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(changes.files) { file in
                        DisclosureGroup {
                            DiffLines(file: file)
                        } label: {
                            HStack(spacing: 8) {
                                Text(file.status).font(.caption.monospaced().weight(.bold))
                                    .foregroundStyle(file.status == "D" ? PhoneTheme.failed : file.status == "??" || file.status == "A" ? PhoneTheme.working : PhoneTheme.needsYou)
                                    .frame(width: 22, alignment: .leading)
                                Text(file.path).font(.caption.monospaced()).lineLimit(2).foregroundStyle(.primary)
                                Spacer(minLength: 4)
                                if let added = file.added { Text("+\(added)").font(.caption2.monospaced()).foregroundStyle(PhoneTheme.working) }
                                if let removed = file.removed { Text("−\(removed)").font(.caption2.monospaced()).foregroundStyle(PhoneTheme.failed) }
                            }
                        }
                    }
                }
            } else {
                WaitingForMac(text: "Reading the changes…")
            }
        }
        .task(id: session.id) { await store.ask(.changes, session: session.id) }
    }
}

/// A file's diff, coloured like the terminal's.
struct DiffLines: View {
    let file: ProjectChanges.File

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.diff.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.caption2.monospaced())
                        .foregroundStyle(line.hasPrefix("+") ? PhoneTheme.working : line.hasPrefix("-") ? PhoneTheme.failed
                                         : line.hasPrefix("@@") ? PhoneTheme.unseen : .secondary)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.hasPrefix("+") ? PhoneTheme.working.opacity(0.08)
                                    : line.hasPrefix("-") ? PhoneTheme.failed.opacity(0.08) : .clear)
                }
                if file.cut {
                    Text("…the rest is on the Mac").font(.caption2).foregroundStyle(.secondary).padding(6)
                }
            }
        }
        .background(Color(.quaternarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }
}
