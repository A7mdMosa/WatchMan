import AppKit
import Observation
import WatchManCore

/// Looks for a newer WatchMan on GitHub Releases: once at launch and when you ask (no timer). Quiet when it can't
/// reach GitHub.
@MainActor @Observable
final class UpdateCheck {
    static let shared = UpdateCheck()
    static let releases = URL(string: "https://github.com/A7mdMosa/WatchMan/releases")!

    struct Release: Equatable { var version: String; var page: URL }
    /// A newer release than this one, when there is one.
    private(set) var available: Release?
    private(set) var checking = false
    /// What the last check you asked for found, for Settings ("You have the latest version").
    private(set) var lastResult: String?

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    func check() async {
        guard !checking, let url = URL(string: "https://api.github.com/repos/A7mdMosa/WatchMan/releases/latest") else { return }
        checking = true
        defer { checking = false }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = object["tag_name"] as? String else {
            lastResult = "Couldn't reach GitHub"
            return
        }
        let page = (object["html_url"] as? String).flatMap(URL.init(string:)) ?? Self.releases
        if AppVersion.isNewer(tag, than: current) {
            available = Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), page: page)
            lastResult = "WatchMan \(available!.version) is available"
        } else {
            available = nil
            lastResult = "You have the latest version"
        }
    }

    func openDownload() { NSWorkspace.shared.open(available?.page ?? Self.releases) }
}
