// Providers report rate and plan limits only as words. Goose retries a 429
// itself (measured: four requests over about 60 s on goose-acp 1.59.2), then
// fails the turn with "Ran into this error: Rate limit exceeded: <provider
// message>". This reads such a message: is it a limit, and when does it reset?
// Unknown stays unknown: no reset time is invented.
import Foundation

public struct RateLimit: Sendable, Equatable {
    /// The provider's own words.
    public var message: String
    /// When the provider said the limit resets, if it did.
    public var resetsAt: Date?

    /// What only a provider's limit says. Not a bare "429" or "limit reached": a context window, a tool's output or a
    /// token count ("134290 tokens") says those too, and an app would wait and retry for nothing.
    static let markers = [
        #"\brate[ _-]?limit"#, #"\busage limit"#, #"\btoo many requests\b"#, #"\bhit your (?:usage )?limit"#,
        #"\b(?:insufficient_quota|quota exceeded|exceeded your (?:current )?quota)\b"#,
        #"\b(?:\d+-hour|hourly|daily|weekly|monthly|plan|session|usage) limit (?:reached|exceeded)"#,
        #"(?:\b(?:http|status|error|code)\W{0,3}429\b|^429\b|\b429 too many)"#,
    ]

    /// - Parameter now: the time the message arrived; relative times count from it.
    public static func detect(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> RateLimit? {
        let lower = text.lowercased()
        guard markers.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) else { return nil }
        let message = text.replacingOccurrences(of: "Ran into this error: ", with: "")
            .components(separatedBy: "\n\nPlease retry")[0].trimmingCharacters(in: .whitespacesAndNewlines)
        return RateLimit(message: message, resetsAt: relative(lower, now: now) ?? clock(lower, now: now, calendar: calendar))
    }

    /// "try again in 20s", "in 1h20m3.5s", "in 5 minutes", "in 3 days 4 hours".
    static func relative(_ text: String, now: Date) -> Date? {
        guard let range = text.range(of: #"(?:try again|retry|resets?|available again)\s+in\s+([0-9a-z .,]+)"#, options: .regularExpression) else { return nil }
        let phrase = String(text[range]).components(separatedBy: " in ").dropFirst().joined(separator: " in ")
        let units: [(pattern: String, seconds: Double)] = [
            (#"([0-9.]+)\s*(?:d|days?)\b"#, 86_400), (#"([0-9.]+)\s*(?:h|hours?|hrs?)\b"#, 3_600),
            (#"([0-9.]+)\s*(?:m|mins?|minutes?)\b"#, 60), (#"([0-9.]+)\s*(?:s|secs?|seconds?)\b"#, 1),
        ]
        // "1h20m3.5s" has no spaces between parts: split them first.
        let spaced = phrase.replacingOccurrences(of: #"([0-9.]+)([a-z]+)"#, with: "$1 $2 ", options: .regularExpression)
        var total = 0.0
        for unit in units {
            guard let expression = try? NSRegularExpression(pattern: unit.pattern) else { continue }
            for match in expression.matches(in: spaced, range: NSRange(spaced.startIndex..., in: spaced)) {
                if let r = Range(match.range(at: 1), in: spaced), let value = Double(spaced[r]) { total += value * unit.seconds }
            }
        }
        return total > 0 ? now.addingTimeInterval(total) : nil
    }

    /// "resets 3pm", "resets at 14:00", "try again at 2:43 PM": the next such time.
    static func clock(_ text: String, now: Date, calendar: Calendar) -> Date? {
        let pattern = #"(?:resets?|try again|available again)\s+(?:at\s+)?([0-9]{1,2})(?::([0-9]{2}))?\s*(am|pm)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hourRange = Range(match.range(at: 1), in: text), var hour = Int(text[hourRange]) else { return nil }
        let minute = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
        let meridiem = Range(match.range(at: 3), in: text).map { String(text[$0]) }
        if meridiem == nil && match.range(at: 2).location == NSNotFound { return nil } // a bare number isn't a time
        if meridiem == "pm" && hour < 12 { hour += 12 }
        if meridiem == "am" && hour == 12 { hour = 0 }
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime)
    }
}
