import AppKit
import UniformTypeIdentifiers

/// Files and pictures for a session: dropped on the notch or the reply box, or a screenshot of a window.
/// They go into the reply as quoted paths Claude can open.
@MainActor
enum Attachments {
    static var folder: URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchMan/Drops", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The paths of dropped items (a dropped picture is saved as a PNG first), all at once.
    static func paths(from providers: [NSItemProvider], done: @escaping @MainActor ([String]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [String] = []
        for provider in providers {
            group.enter()
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let path = url?.path { lock.lock(); found.append(path); lock.unlock() }
                    group.leave()
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    if let image = image as? NSImage, let tiff = image.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("WatchMan/Drops/drop-\(UUID().uuidString.prefix(8)).png")
                        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if (try? png.write(to: file)) != nil { lock.lock(); found.append(file.path); lock.unlock() }
                    }
                    group.leave()
                }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { done(found) }
        }
    }

    static func quoted(_ path: String) -> String { path.contains(" ") ? "\"\(path)\"" : path }

    /// What ⌘V would attach instead of pasting text: copied files (their paths), or a copied picture with no text
    /// (a screenshot copied with ⌃⇧⌘4, an image copied in Preview or a browser), saved as a PNG first.
    /// Nil when the clipboard holds text, so the normal paste goes ahead.
    static func pastedPaths(from pasteboard: NSPasteboard = .general) -> [String]? {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty { return files.map(\.path) }
        guard pasteboard.string(forType: .string) == nil,
              pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
              let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let file = folder.appendingPathComponent("paste-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4)).png")
        guard (try? png.write(to: file)) != nil else { return nil }
        return [file.path]
    }
}

extension SessionStore {
    /// Adds paths to a session's half-typed reply.
    func appendToDraft(_ paths: [String], for id: String) {
        guard !paths.isEmpty else { return }
        let current = drafts[id] ?? ""
        let added = paths.map(Attachments.quoted).joined(separator: " ")
        drafts[id] = current.isEmpty ? added + " " : current + (current.hasSuffix(" ") ? "" : " ") + added + " "
    }

    /// ⌘V in a reply box: copied files or a copied picture go into the reply as paths. False when there's
    /// nothing to attach (plain text pastes as usual).
    func pasteAttachments(into id: String) -> Bool {
        guard let paths = Attachments.pastedPaths() else { return false }
        appendToDraft(paths, for: id)
        let names = paths.map { ($0 as NSString).lastPathComponent }
        pageNote = paths.count == 1 ? "Attached \(names[0])" : "Attached \(paths.count) files"
        return true
    }

    /// Files dropped on the notch go to this session: into its reply, and its page opens ready to type.
    func sendDrop(to id: String) {
        appendToDraft(pendingDrop, for: id)
        pendingDrop = []
        openPage(id)
        focusReplyId = id
        NotificationCenter.default.post(name: .watchManNeedsKeyboard, object: nil)
    }

    /// Lets you click a window to screenshot it (Esc cancels), then puts the picture in this session's reply and
    /// opens its page again. macOS asks once for Screen Recording permission.
    func captureWindow(for id: String) {
        let file = Attachments.folder.appendingPathComponent("window-\(Int(Date().timeIntervalSince1970)).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive, -W start on windows, -o no shadow, -x no sound
        process.arguments = ["-i", "-W", "-o", "-x", file.path]
        process.terminationHandler = { _ in
            Task { @MainActor [weak self] in
                guard let self, FileManager.default.fileExists(atPath: file.path) else { return }   // cancelled
                self.appendToDraft([file.path], for: id)
                NotificationCenter.default.post(name: .watchManOpenSession, object: id)
            }
        }
        try? process.run()
    }
}

extension Notification.Name {
    /// Opens a session's page ready to type (the object is its id).
    static let watchManOpenSession = Notification.Name("watchManOpenSession")
}
