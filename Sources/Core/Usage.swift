import Foundation

/// Token totals across all sessions, grouped like Claude plan limits:
/// 5-hour blocks that start at the hour of the first message after the previous block ended.
public struct UsageSummary: Equatable, Sendable {
    public var currentBlockTokens: Int
    public var currentBlockStart: Date?
    public var currentBlockEnd: Date?
    public var lastSevenDaysTokens: Int

    public static let blockLength: TimeInterval = 5 * 60 * 60

    public static func compute(entries: [TranscriptState.UsageEntry], now: Date) -> UsageSummary {
        let sorted = entries.sorted { $0.at < $1.at }
        let weekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let week = sorted.filter { $0.at >= weekAgo && $0.at <= now }.reduce(0) { $0 + $1.tokens }

        var blockStart: Date?
        var blockTokens = 0
        for entry in sorted where entry.at <= now {
            if let start = blockStart, entry.at < start.addingTimeInterval(blockLength) {
                blockTokens += entry.tokens
            } else {
                blockStart = floorToHour(entry.at)
                blockTokens = entry.tokens
            }
        }
        guard let start = blockStart, now < start.addingTimeInterval(blockLength) else {
            return UsageSummary(currentBlockTokens: 0, currentBlockStart: nil, currentBlockEnd: nil,
                                lastSevenDaysTokens: week)
        }
        return UsageSummary(currentBlockTokens: blockTokens, currentBlockStart: start,
                            currentBlockEnd: start.addingTimeInterval(blockLength), lastSevenDaysTokens: week)
    }

    static func floorToHour(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: parts) ?? date
    }

    /// "1.2M", "850K", "900".
    public static func format(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...: String(format: "%.1fM", Double(tokens) / 1_000_000)
        case 1_000...: "\(tokens / 1_000)K"
        default: "\(tokens)"
        }
    }
}
