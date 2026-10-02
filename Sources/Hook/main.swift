// watchman-hook: Claude Code runs this for every hook event.
// It adds which terminal the session runs in and forwards the event to WatchMan.
// It never blocks Claude Code: if WatchMan isn't running it exits at once and prints nothing.
import Foundation
import WatchManCore

let input = FileHandle.standardInput.readDataToEndOfFile()

// Status line mode (`watchman-hook --statusline ['your command']`): pass Claude Code's status line data (plan
// usage, how full the context is) to WatchMan, then run your own status line command and print what it prints
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--statusline" {
    if var object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] {
        object["hook_event_name"] = StatusLineInfo.eventName
        let socketPath = ProcessInfo.processInfo.environment["WATCHMAN_SOCKET"] ?? WatchManPaths.socketPath
        if var line = try? JSONSerialization.data(withJSONObject: object), let fd = SocketIO.connect(path: socketPath, timeout: 0.2) {
            line.append(0x0A)
            _ = SocketIO.writeAll(fd, line)
            close(fd)
        }
    }
    guard CommandLine.arguments.count > 2 else { exit(0) }
    let own = Process()
    own.executableURL = URL(fileURLWithPath: "/bin/sh")
    own.arguments = ["-c", CommandLine.arguments[2]]
    let stdin = Pipe()
    own.standardInput = stdin
    guard (try? own.run()) != nil else { exit(0) }
    stdin.fileHandleForWriting.write(input)
    try? stdin.fileHandleForWriting.close()
    own.waitUntilExit()
    exit(own.terminationStatus)
}
guard var payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }

let environment = ProcessInfo.processInfo.environment
// Headless `claude -p` runs (scripts, WatchMan's own summaries) aren't sessions to watch
if environment["CLAUDE_CODE_ENTRYPOINT"]?.hasPrefix("sdk") == true { exit(0) }
payload[HookEvent.RelayKey.host] = HostKind.detect(environment: environment).rawValue
if let claude = ProcessAncestry.claudeProcess(environment: environment) {
    payload[HookEvent.RelayKey.pid] = claude.pid
    if let tty = claude.tty { payload[HookEvent.RelayKey.tty] = tty }
}

guard var line = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]) else { exit(0) }
line.append(0x0A)

let isPermissionRequest = payload["hook_event_name"] as? String == "PermissionRequest"
// Permission requests wait for the user's click in WatchMan; everything else is fire-and-forget
let socketPath = environment["WATCHMAN_SOCKET"] ?? WatchManPaths.socketPath   // override for tests
// Up to 590 s: WatchMan may hold a prompt while you answer from your phone (the hook's own timeout is 600 s)
guard let fd = SocketIO.connect(path: socketPath, timeout: isPermissionRequest ? 590 : 0.3) else { exit(0) }
defer { close(fd) }
guard SocketIO.writeAll(fd, line) else { exit(0) }

if isPermissionRequest, let reply = SocketIO.readLine(fd) {
    let (decision, extras) = PermissionDecision.parseReply(socketLine: reply)
    if let output = decision.hookOutput(permissionSuggestions: payload["permission_suggestions"], extras: extras,
                                        toolInput: payload["tool_input"] as? [String: Any]) {
        print(output)
    }
}
exit(0)
