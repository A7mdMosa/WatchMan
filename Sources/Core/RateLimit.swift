import Foundation

/// Claude's usage limit: "Claude usage limit reached. Your limit will reset at 9pm (Asia/Kuwait).",
/// "5-hour limit reached ∙ resets 9pm", or a StopFailure error of type rate_limit.
public enum RateLimit {
    private static let patterns = [
        #"usage limit"#, #"rate[ _-]?limit"#, #"limit reached"#, #"\b(5|five)[- ]hour limit\b"#, #"weekly limit"#,
        #"limit will reset"#, #"\bresets? (at )?\d{1,2}(:\d{2})?\s?(am|pm)\b"#,
    ]

    public static func isLimit(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// When it resets, as Claude Code said it: "9pm", "10:30am", "9pm (Asia/Kuwait)".
    public static func resetTime(_ text: String?) -> String? {
        guard let text else { return nil }
        let pattern = #"resets?(?: at)? (\d{1,2}(?::\d{2})?\s?(?:am|pm)?(?: \([^)]+\))?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let time = String(text[range]).trimmingCharacters(in: .whitespaces)
        // A bare number isn't a time ("resets 3 sessions")
        return time.range(of: #"(am|pm|:)"#, options: [.regularExpression, .caseInsensitive]) != nil ? time : nil
    }

    /// The next moment a reset time like "9pm", "3:45pm" or "9pm (Asia/Kuwait)" comes round, from `now`.
    public static func resetDate(_ time: String?, now: Date = Date()) -> Date? {
        guard var text = time?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
        var zone = TimeZone.current
        if let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")"), open < close {
            if let named = TimeZone(identifier: String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                .split(separator: "/").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "/")) {
                zone = named
            }
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        text = text.replacingOccurrences(of: " ", with: "")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        var parsed: Date?
        for format in ["h:mma", "ha", "H:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { parsed = date; break }
        }
        guard let parsed else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: parsed)
        guard let today = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: now) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }
}
