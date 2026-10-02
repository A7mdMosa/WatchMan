import os

/// WatchMan's diagnostics, readable with:
/// /usr/bin/log show --last 10m --predicate 'subsystem == "com.moussa.WatchMan"'
enum Log {
    private static let logger = Logger(subsystem: "com.moussa.WatchMan", category: "app")

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}
