import Foundation
import WatchManCore

/// Answers one waiting PermissionRequest hook, exactly once.
final class PermissionResponder: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var answered = false

    init(fd: Int32) { self.fd = fd }

    /// `extras`: answers to Claude's questions, a plan approval's mode, a message for Claude.
    func answer(_ decision: PermissionDecision, extras: ReplyExtras? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !answered else { return }
        answered = true
        SocketIO.writeAll(fd, Data(PermissionDecision.socketLine(decision, extras: extras).utf8))
        close(fd)
    }

    deinit {
        if !answered { close(fd) }
    }
}

/// Listens on WatchMan's Unix socket for events from watchman-hook.
/// Events are handed to the main thread in the order they arrive.
final class HookServer: @unchecked Sendable {
    typealias Handler = @MainActor (HookEvent, PermissionResponder?) -> Void

    private let path: String
    private let handler: Handler
    /// Status line data (plan usage, context), which isn't a session event.
    private let statusHandler: @MainActor (StatusLineInfo) -> Void
    private var listenFD: Int32 = -1

    init(path: String = WatchManPaths.socketPath, handler: @escaping Handler,
         statusLine: @escaping @MainActor (StatusLineInfo) -> Void = { _ in }) {
        self.path = path
        self.handler = handler
        self.statusHandler = statusLine
    }

    func start() throws {
        try FileManager.default.createDirectory(at: WatchManPaths.supportDirectory, withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = SocketIO.makeAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 32) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        chmod(path, 0o600)
        listenFD = fd
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "WatchMan hook server"
        thread.start()
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            SocketIO.setTimeout(client, 2)
            // Hooks write their line immediately, so reading here keeps events in order
            guard let line = SocketIO.readLine(client),
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                close(client)
                continue
            }
            if object["hook_event_name"] as? String == StatusLineInfo.eventName {
                close(client)
                let info = StatusLineInfo.parse(object)
                let statusHandler = self.statusHandler
                DispatchQueue.main.async { MainActor.assumeIsolated { statusHandler(info) } }
                continue
            }
            guard let event = HookEvent.parse(object) else {
                close(client)
                continue
            }
            let responder: PermissionResponder?
            if event.name == "PermissionRequest" {
                responder = PermissionResponder(fd: client)
            } else {
                close(client)
                responder = nil
            }
            let handler = self.handler
            DispatchQueue.main.async {
                MainActor.assumeIsolated { handler(event, responder) }
            }
        }
    }
}
