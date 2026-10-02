import Foundation

/// A project's git state from `git status --porcelain=v1 --branch`: changed files and commits not pushed yet.
public struct GitState: Equatable, Sendable {
    public var branch: String?
    /// Commits on this branch its upstream doesn't have yet.
    public var ahead: Int
    /// Changed, added, deleted and new files.
    public var changed: Int
    public var hasUpstream: Bool

    public init(branch: String? = nil, ahead: Int = 0, changed: Int = 0, hasUpstream: Bool = false) {
        self.branch = branch
        self.ahead = ahead
        self.changed = changed
        self.hasUpstream = hasUpstream
    }

    /// Work that isn't saved anywhere else yet.
    public var unsaved: Bool { changed > 0 || ahead > 0 }

    public static func parse(_ output: String) -> GitState {
        var state = GitState()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("## ") {
                let header = line.dropFirst(3)
                let names = header.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                if names.contains("...") {
                    state.hasUpstream = true
                    state.branch = names.components(separatedBy: "...").first
                } else if header.hasPrefix("No commits yet on ") {
                    state.branch = String(header.dropFirst("No commits yet on ".count))
                } else if !header.hasPrefix("HEAD") {
                    state.branch = names
                }
                if let range = header.range(of: #"ahead (\d+)"#, options: .regularExpression) {
                    state.ahead = Int(header[range].filter(\.isNumber)) ?? 0
                }
            } else {
                state.changed += 1
            }
        }
        return state
    }
}
