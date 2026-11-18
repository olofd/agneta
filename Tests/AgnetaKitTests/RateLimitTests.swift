// Reading provider limits from their words (Router/RateLimit.swift).
import Foundation
import Testing
@testable import AgnetaKit

@Suite struct RateLimitTests {
    let now = Date(timeIntervalSince1970: 1_794_928_000) // a fixed moment
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Stockholm")!; return c }

    /// Goose 1.59.2's exact text after OpenAI's 429 (measured with the fake model, AgnetaFakes).
    static let goose = "Ran into this error: Rate limit exceeded: Rate limit reached for requests. Please try again in 20s..\n\nPlease retry if you think this is a transient or recoverable error."

    @Test func readsGoosesRateLimitError() throws {
        let limit = try #require(RateLimit.detect(Self.goose, now: now, calendar: calendar))
        #expect(limit.message == "Rate limit exceeded: Rate limit reached for requests. Please try again in 20s..")
        #expect(limit.resetsAt == now.addingTimeInterval(20))
    }

    @Test func readsRelativeResetTimes() {
        func after(_ text: String) -> TimeInterval? { RateLimit.detect(text, now: now, calendar: calendar)?.resetsAt.map { ($0.timeIntervalSince(now) * 10).rounded() / 10 } }
        #expect(after("Rate limit reached. Please try again in 1h20m3.5s.") == 4803.5)
        #expect(after("You've hit your usage limit. Try again in 3 days 4 hours.") == Double(3 * 86_400 + 4 * 3600))
        #expect(after("429 Too Many Requests: retry in 5 minutes") == 300)
        #expect(after("Rate limit exceeded") == nil) // a limit without a time stays unknown
    }

    @Test func readsClockResetTimes() throws {
        // 1_794_928_000 is 2026-11-17 16:46:40 in Stockholm.
        let threePM = try #require(RateLimit.detect("5-hour limit reached ∙ resets 3pm", now: now, calendar: calendar)?.resetsAt)
        #expect(calendar.dateComponents([.day, .hour, .minute], from: threePM) == DateComponents(day: 18, hour: 15, minute: 0))
        let evening = try #require(RateLimit.detect("Usage limit reached, resets at 18:30", now: now, calendar: calendar)?.resetsAt)
        #expect(calendar.dateComponents([.day, .hour, .minute], from: evening) == DateComponents(day: 17, hour: 18, minute: 30))
    }

    @Test func ignoresOtherErrors() {
        #expect(RateLimit.detect("The engine stopped") == nil)
        #expect(RateLimit.detect("Invalid API key provided") == nil)
    }
}
