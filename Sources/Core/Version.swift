import Foundation

/// App versions like "0.2.0" or a release tag like "v0.2.0".
public enum AppVersion {
    /// Whether `candidate` is a later version than `current` (numbers compared part by part, "v" ignored).
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func parts(_ version: String) -> [Int] {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: "-").first.map(String.init)?
            .split(separator: ".").map { Int($0) ?? 0 } ?? []
    }
}
