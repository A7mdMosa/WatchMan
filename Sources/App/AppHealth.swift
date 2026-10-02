import Foundation
import Observation

/// Whether WatchMan can hear Claude Code at all. When it can't, the notch turns red and says why.
@MainActor @Observable
final class AppHealth {
    static let shared = AppHealth()

    /// The hook socket couldn't be opened.
    var socketFailed = false
    private(set) var hooksInstalled = HookInstaller.hooksInstalled

    /// Re-reads whether the hooks are in Claude Code's settings (after installing or removing them).
    func refresh() {
        hooksInstalled = HookInstaller.hooksInstalled
    }

    var problem: String? {
        if socketFailed { return "WatchMan can't hear Claude" }
        if !hooksInstalled { return "Hooks not installed" }
        return nil
    }
}
