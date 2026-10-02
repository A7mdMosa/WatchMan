import AppKit
import WatchManCore

/// Opens, types into and starts Claude sessions in the app they run in.
@MainActor
enum Hosts {
    /// Brings the session's tab (or app) to the front.
    static func open(_ session: Session) {
        Task {
            switch session.host {
            case .ghostty: await GhosttyHost.focus(session)
            case .iterm: await ITermHost.focus(session)
            case .terminal: await TerminalAppHost.focus(session)
            case .vscodeTerminal, .vscodeExtension: VSCodeHost.focus(session)
            case .other: break
            }
        }
    }

    /// Types a message into the session and presses Enter. Returns nil on success, or why it failed.
    static func send(_ text: String, to session: Session) async -> String? {
        guard session.host.canSend else { return "\(session.host.label) can't receive messages from WatchMan." }
        guard let tty = session.tty else { return "WatchMan doesn't know this session's terminal yet." }
        // Never type into a plain shell: the text would run as a command
        let table = await ProcessSnapshot.current()
        guard table.claudeIsForeground(onTTY: tty) else { return "Claude isn't running in that tab anymore." }
        // Ghostty pastes several lines as one message; elsewhere each new line would press Enter
        let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        switch session.host {
        case .ghostty: return await GhosttyHost.send(text, tty: tty, cwd: session.cwd)
        case .iterm: return await ITermHost.send(oneLine, tty: tty)
        case .terminal: return await TerminalAppHost.send(oneLine, tty: tty)
        default: return "Can't send to \(session.host.label)."
        }
    }

    /// Presses Esc in the session to interrupt Claude (Ghostty and iTerm2 only).
    static func interrupt(_ session: Session) async -> String? {
        guard let tty = session.tty else { return "WatchMan doesn't know this session's terminal yet." }
        switch session.host {
        case .ghostty: return await GhosttyHost.pressEscape(tty: tty, cwd: session.cwd)
        case .iterm: return await ITermHost.send("\u{1B}", tty: tty, newline: false)
        default: return "Open \(session.host.label) and press Esc there."
        }
    }

    static func canInterrupt(_ host: HostKind) -> Bool { host == .ghostty || host == .iterm }

    /// You're looking at the session: its app is in front and so is its tab (or, in VS Code, its project's window).
    /// When the tab can't be told apart, being in its app counts.
    static func isInFront(_ session: Session) async -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == session.host.bundleIdentifier else { return false }
        switch session.host {
        case .ghostty: return await GhosttyHost.isFocused(session) ?? true
        case .iterm: return await ITermHost.isFocused(session) ?? true
        case .terminal: return await TerminalAppHost.isFocused(session) ?? true
        case .vscodeTerminal, .vscodeExtension: return VSCodeHost.isFocused(session) ?? true
        case .other: return true
        }
    }

    /// Why the last new tab couldn't be opened, in words for a message.
    private(set) static var lastStartProblem: String?

    /// Notes a new-tab script's outcome: logged, and kept in words when it failed.
    static func opened(_ result: Script.Result, in app: String) -> Bool {
        guard !result.ok else { lastStartProblem = nil; return true }
        Log.info("couldn't open a tab in \(app): \(result.error)")
        if result.error.contains("-1743") || result.error.localizedCaseInsensitiveContains("not authorized") {
            lastStartProblem = "WatchMan isn't allowed to control \(app). Allow it in System Settings → Privacy & Security → Automation."
        } else if result.error.contains("-600") || result.error.contains("-1728") {
            lastStartProblem = "\(app) didn't respond. Open it and try again."
        } else {
            lastStartProblem = result.error.isEmpty ? "\(app) didn't open a tab." : "\(app): \(result.error)"
        }
        NotificationCenter.default.post(name: .watchManStartFailed, object: lastStartProblem)
        return false
    }

    /// Opens a new tab running `command` in `folder` (Ghostty by default).
    static func startSession(in folder: String, command: String, host: HostKind = .ghostty) async -> Bool {
        switch host {
        case .iterm: await ITermHost.openNew(cwd: folder, command: command)
        case .terminal: await TerminalAppHost.openNew(cwd: folder, command: command)
        default: await GhosttyHost.openNew(cwd: folder, command: command)
        }
    }

    static func activate(bundleIdentifier: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// `ps` snapshot, taken off the main thread.
enum ProcessSnapshot {
    static func current() async -> ProcessTable {
        let result = await Script.run("/bin/ps", ["-axo", "pid=,ppid=,rss=,tty=,stat=,args="])
        return ProcessTable.parse(result.output)
    }
}

// MARK: - Ghostty

/// Ghostty 1.3+ AppleScript. Its terminals don't expose their tty, so a tab is found by
/// writing a unique OSC 7 working directory to the tty and looking for the terminal reporting it.
@MainActor
enum GhosttyHost {
    private static var terminalIds: [String: String] = [:]   // tty → terminal id
    private static let bundleId = "com.mitchellh.ghostty"

    static func focus(_ session: Session) async {
        guard let tty = session.tty, let id = await terminalId(for: tty, cwd: session.cwd) else {
            Hosts.activate(bundleIdentifier: bundleId)
            return
        }
        let result = await Script.appleScript("""
            on run argv
                tell application "Ghostty"
                    focus (first terminal whose id is (item 1 of argv))
                    activate
                end tell
            end run
            """, [id])
        if !result.ok {
            terminalIds[tty] = nil
            Hosts.activate(bundleIdentifier: bundleId)
        }
    }

    static func send(_ text: String, tty: String, cwd: String) async -> String? {
        guard let id = await terminalId(for: tty, cwd: cwd) else { return "Couldn't find the Ghostty tab." }
        let result = await Script.appleScript("""
            on run argv
                tell application "Ghostty"
                    set t to first terminal whose id is (item 1 of argv)
                    input text (item 2 of argv) to t
                    delay 0.1
                    send key "enter" to t
                end tell
            end run
            """, [id, text])
        if !result.ok { terminalIds[tty] = nil }
        return result.ok ? nil : "Ghostty didn't accept the message."
    }

    /// Whether the session's terminal is the focused one in Ghostty's front window (nil: can't tell).
    static func isFocused(_ session: Session) async -> Bool? {
        guard let tty = session.tty, let id = await terminalId(for: tty, cwd: session.cwd) else { return nil }
        let result = await Script.appleScript("""
            tell application "Ghostty" to return id of focused terminal of selected tab of front window
            """)
        return result.ok ? result.output == id : nil
    }

    static func pressEscape(tty: String, cwd: String) async -> String? {
        guard let id = await terminalId(for: tty, cwd: cwd) else { return "Couldn't find the Ghostty tab." }
        let result = await Script.appleScript("""
            on run argv
                tell application "Ghostty"
                    send key "escape" to (first terminal whose id is (item 1 of argv))
                end tell
            end run
            """, [id])
        return result.ok ? nil : "Ghostty didn't accept the key."
    }

    static func openNew(cwd: String, command: String) async -> Bool {
        let result = await Script.appleScript("""
            on run argv
                tell application "Ghostty"
                    set cfg to new surface configuration
                    set initial working directory of cfg to (item 1 of argv)
                    set initial input of cfg to (item 2 of argv) & linefeed
                    if (count of windows) is 0 then
                        new window with configuration cfg
                    else
                        new tab in front window with configuration cfg
                    end if
                    activate
                end tell
            end run
            """, [cwd, command])
        return Hosts.opened(result, in: "Ghostty")
    }

    private static func terminalId(for tty: String, cwd: String) async -> String? {
        if let cached = terminalIds[tty] { return cached }
        let id = await Task.detached { findTerminal(tty: tty, cwd: cwd) }.value
        if let id { terminalIds[tty] = id }
        return id
    }

    /// Blocking: tags the tty, finds the terminal reporting the tag, restores its directory.
    nonisolated private static func findTerminal(tty: String, cwd: String) -> String? {
        guard tty.range(of: #"^/dev/ttys[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        let listing = Script.appleScriptBlocking("""
            tell application "Ghostty"
                set out to ""
                repeat with t in terminals
                    set out to out & (id of t) & tab & (working directory of t) & linefeed
                end repeat
                return out
            end tell
            """)
        guard listing.ok else { return nil }
        var directories: [String: String] = [:]
        for line in listing.output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2 { directories[parts[0]] = parts[1] }
        }
        let marker = "/watchman-" + UUID().uuidString
        guard writeWorkingDirectory(marker, to: tty) else { return nil }
        let found = Script.appleScriptBlocking("""
            on run argv
                tell application "Ghostty"
                    repeat 20 times
                        set hits to (every terminal whose working directory is (item 1 of argv))
                        if (count of hits) > 0 then return id of (item 1 of hits)
                        delay 0.05
                    end repeat
                end tell
                return ""
            end run
            """, [marker]).output
        writeWorkingDirectory(directories[found] ?? cwd, to: tty)
        return found.isEmpty ? nil : found
    }

    /// Writes an OSC 7 "current directory" report to the tty, as a shell prompt would.
    @discardableResult
    nonisolated private static func writeWorkingDirectory(_ path: String, to tty: String) -> Bool {
        var host = [CChar](repeating: 0, count: 256)
        gethostname(&host, host.count - 1)
        let hostName = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let bytes = Array("\u{1B}]7;file://\(hostName)\(encoded)\u{07}".utf8)
        let fd = Darwin.open(tty, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == bytes.count
    }
}

// MARK: - iTerm2

@MainActor
enum ITermHost {
    static func focus(_ session: Session) async {
        guard let tty = session.tty else { Hosts.activate(bundleIdentifier: "com.googlecode.iterm2"); return }
        let result = await Script.appleScript("""
            on run argv
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is (item 1 of argv) then
                                    select w
                                    select t
                                    select s
                                    activate
                                    return "ok"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return ""
            end run
            """, [tty])
        if result.output != "ok" { Hosts.activate(bundleIdentifier: "com.googlecode.iterm2") }
    }

    /// Whether the session is iTerm2's current session in its front window (nil: can't tell).
    static func isFocused(_ session: Session) async -> Bool? {
        guard let tty = session.tty else { return nil }
        let result = await Script.appleScript("""
            tell application id "com.googlecode.iterm2" to return tty of current session of current window
            """)
        return result.ok ? result.output == tty : nil
    }

    static func send(_ text: String, tty: String, newline: Bool = true) async -> String? {
        let result = await Script.appleScript("""
            on run argv
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is (item 1 of argv) then
                                    if (item 3 of argv) is "1" then
                                        tell s to write text (item 2 of argv)
                                    else
                                        tell s to write text (item 2 of argv) newline no
                                    end if
                                    return "ok"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return ""
            end run
            """, [tty, text, newline ? "1" : "0"])
        return result.output == "ok" ? nil : "Couldn't find the iTerm2 session."
    }

    static func openNew(cwd: String, command: String) async -> Bool {
        let line = "cd \(Script.shellQuote(cwd)) && \(command)"
        let result = await Script.appleScript("""
            on run argv
                tell application id "com.googlecode.iterm2"
                    if (count of windows) is 0 then
                        create window with default profile
                    else
                        tell current window to create tab with default profile
                    end if
                    tell current session of current window to write text (item 1 of argv)
                    activate
                end tell
            end run
            """, [line])
        return Hosts.opened(result, in: "a terminal")
    }
}

// MARK: - Terminal.app

@MainActor
enum TerminalAppHost {
    static func focus(_ session: Session) async {
        guard let tty = session.tty else { Hosts.activate(bundleIdentifier: "com.apple.Terminal"); return }
        let result = await Script.appleScript("""
            on run argv
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is (item 1 of argv) then
                                set selected of t to true
                                set index of w to 1
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end tell
                return ""
            end run
            """, [tty])
        if result.output != "ok" { Hosts.activate(bundleIdentifier: "com.apple.Terminal") }
    }

    /// Whether the session is the selected tab of Terminal's front window (nil: can't tell).
    static func isFocused(_ session: Session) async -> Bool? {
        guard let tty = session.tty else { return nil }
        let result = await Script.appleScript("""
            tell application id "com.apple.Terminal" to return tty of selected tab of front window
            """)
        return result.ok ? result.output == tty : nil
    }

    static func send(_ text: String, tty: String) async -> String? {
        let result = await Script.appleScript("""
            on run argv
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is (item 1 of argv) then
                                do script (item 2 of argv) in t
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end tell
                return ""
            end run
            """, [tty, text])
        return result.output == "ok" ? nil : "Couldn't find the Terminal tab."
    }

    static func openNew(cwd: String, command: String) async -> Bool {
        let line = "cd \(Script.shellQuote(cwd)) && \(command)"
        let result = await Script.appleScript("""
            on run argv
                tell application id "com.apple.Terminal"
                    do script (item 1 of argv)
                    activate
                end tell
            end run
            """, [line])
        return Hosts.opened(result, in: "a terminal")
    }
}

// MARK: - VS Code

@MainActor
enum VSCodeHost {
    /// VS Code can't be scripted: open the project folder (which focuses its window) or just the app.
    static func focus(_ session: Session) {
        let bundleId = "com.microsoft.VSCode"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = session.projectRoot ?? (session.cwd == home ? nil : session.cwd)
        guard let folder, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            Hosts.activate(bundleIdentifier: bundleId)
            return
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Whether VS Code's front window is the session's project, from its title (Accessibility; nil: can't tell).
    /// Which chat or terminal inside that window is showing can't be read.
    static func isFocused(_ session: Session) -> Bool? {
        guard let app = NSWorkspace.shared.frontmostApplication, AXIsProcessTrusted() else { return nil }
        let folder = ((session.projectRoot ?? session.cwd) as NSString).lastPathComponent
        guard !folder.isEmpty else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(unsafeDowncast(windowValue, to: AXUIElement.self), kAXTitleAttribute as CFString,
                                            &titleValue) == .success, let title = titleValue as? String, !title.isEmpty else { return nil }
        return title.localizedCaseInsensitiveContains(folder)
    }
}
