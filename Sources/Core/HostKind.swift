import Foundation

/// The app a Claude Code session runs in.
public enum HostKind: String, Codable, Sendable, CaseIterable {
    case ghostty
    case iterm
    case terminal
    case vscodeTerminal
    case vscodeExtension
    case other

    public var label: String {
        switch self {
        case .ghostty: "Ghostty"
        case .iterm: "iTerm2"
        case .terminal: "Terminal"
        case .vscodeTerminal: "VS Code"
        case .vscodeExtension: "VS Code ext"
        case .other: "Other"
        }
    }

    public var bundleIdentifier: String? {
        switch self {
        case .ghostty: "com.mitchellh.ghostty"
        case .iterm: "com.googlecode.iterm2"
        case .terminal: "com.apple.Terminal"
        case .vscodeTerminal, .vscodeExtension: "com.microsoft.VSCode"
        case .other: nil
        }
    }

    /// Terminals WatchMan can type into.
    public var canSend: Bool {
        switch self {
        case .ghostty, .iterm, .terminal: true
        default: false
        }
    }

    /// Works out the host from the environment Claude Code passes to its hooks.
    public static func detect(environment env: [String: String]) -> HostKind {
        let termProgram = env["TERM_PROGRAM"] ?? ""
        let bundle = (env["__CFBundleIdentifier"] ?? "").lowercased()
        if env["CLAUDE_CODE_ENTRYPOINT"] == "claude-vscode" { return .vscodeExtension }
        if termProgram == "vscode" { return .vscodeTerminal }
        if termProgram == "ghostty" || env["GHOSTTY_RESOURCES_DIR"] != nil || bundle == "com.mitchellh.ghostty" {
            return .ghostty
        }
        if termProgram == "iTerm.app" || env["ITERM_SESSION_ID"] != nil || bundle == "com.googlecode.iterm2" {
            return .iterm
        }
        if termProgram == "Apple_Terminal" || bundle == "com.apple.terminal" { return .terminal }
        if bundle.contains("vscode") { return .vscodeExtension }
        return .other
    }
}
