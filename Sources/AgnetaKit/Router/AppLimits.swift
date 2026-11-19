// The limits the user sets for one app, in Settings → Apps: what it may spend on API keys over a day, a week or a
// month, how many of its turns run at once, and how many new tasks it may start in an hour or a day. All optional,
// none unless the user sets them, kept with the app's grant. The app's own policy limits (`maxTurns`, `maxSeconds`,
// `maxCostUSD`) are separate and checked first.
//
// Spending counts only tasks on API keys: a Claude or ChatGPT plan isn't charged per call (the plan pays), so a
// spending limit isn't offered for plans and a turn on one is neither counted nor stopped by it. It counts the same
// basis as `maxCostUSD` and `agneta/usage` (each turn's share of the task's known cost), at the engine's prices.
//
// At a limit Agneta stops: new work is refused (`-32016`) and running turns stop at the spending limit; a turn over
// "at once" waits its turn. `whenReached` names that behaviour, so asking the user first can be added beside it.
import Foundation

public struct AppLimits: Sendable, Equatable, Codable {
    public enum Period: String, Sendable, Codable, CaseIterable {
        /// The last 60 minutes, rolling.
        case hour
        /// Calendar periods in the user's time zone: they reset at midnight, at the start of the week, on the 1st.
        case day, week, month
    }

    /// What happens when a limit is reached.
    public enum WhenReached: String, Sendable, Codable {
        /// The work is refused, or stopped.
        case stop

        /// A value this build doesn't know (one a later build may write) reads as stop: refusing is never less than
        /// what the user asked for.
        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .stop
        }
    }

    public struct Spend: Sendable, Equatable, Codable {
        /// US dollars, at the engines' prices.
        public var max: Double
        /// `day`, `week` or `month`.
        public var period: Period
        public var whenReached: WhenReached

        public init(max: Double, period: Period, whenReached: WhenReached = .stop) {
            self.max = max
            self.period = period
            self.whenReached = whenReached
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            max = try container.decode(Double.self, forKey: .max)
            period = try container.decode(Period.self, forKey: .period)
            whenReached = try container.decodeIfPresent(WhenReached.self, forKey: .whenReached) ?? .stop
        }
    }

    public struct Starts: Sendable, Equatable, Codable {
        public var max: Int
        /// `hour` (rolling) or `day`.
        public var period: Period
        public var whenReached: WhenReached

        public init(max: Int, period: Period, whenReached: WhenReached = .stop) {
            self.max = max
            self.period = period
            self.whenReached = whenReached
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            max = try container.decode(Int.self, forKey: .max)
            period = try container.decode(Period.self, forKey: .period)
            whenReached = try container.decodeIfPresent(WhenReached.self, forKey: .whenReached) ?? .stop
        }
    }

    /// Spending on the app's API keys over a period.
    public var spend: Spend?
    /// Its turns running at once, across its connections and providers; more wait their turn.
    public var atOnce: Int?
    /// New tasks (`session/new`, `agneta/fork`) over a period; resuming one (`session/load`) isn't a new task.
    public var newTasks: Starts?

    public init(spend: Spend? = nil, atOnce: Int? = nil, newTasks: Starts? = nil) {
        self.spend = spend
        self.atOnce = atOnce
        self.newTasks = newTasks
    }

    public static let none = AppLimits()
    public var isEmpty: Bool { self == .none }

    /// The most a spending limit may be, a sanity bound rather than a policy.
    public static let maxSpend = 10_000.0
    public static let maxNewTasks = 10_000

    /// Why these limits can't be kept, or nil. `global`: how many turns Agneta runs at once, the most "at once" can be.
    public func problem(global: Int) -> String? {
        if let spend {
            guard spend.max.isFinite, spend.max > 0, spend.max <= Self.maxSpend else {
                return "A spending limit is more than $0 and at most $10,000"
            }
            guard spend.period != .hour else { return "A spending limit is per day, week or month" }
        }
        if let atOnce, !(1...global).contains(atOnce) { return "At once is between 1 and \(global)" }
        if let newTasks {
            guard (1...Self.maxNewTasks).contains(newTasks.max) else {
                return "New tasks are between 1 and \(Self.maxNewTasks)"
            }
            guard newTasks.period == .hour || newTasks.period == .day else {
                return "New tasks are counted per hour or per day"
            }
        }
        return nil
    }

    // MARK: Words

    /// "$5", "$2.50".
    public static func dollars(_ amount: Double) -> String {
        amount == amount.rounded() && amount < 1e9 ? "$\(Int(amount))" : String(format: "$%.2f", amount)
    }

    /// "$1.23": what's been spent, always with cents.
    public static func cents(_ amount: Double) -> String { String(format: "$%.2f", amount) }

    static func per(_ period: Period) -> String {
        switch period {
        case .hour: "an hour"
        case .day: "a day"
        case .week: "a week"
        case .month: "a month"
        }
    }

    /// Each limit set, in a few words: "$5 a day", "2 at once", "10 new tasks an hour".
    public var parts: [String] {
        var parts: [String] = []
        if let spend { parts.append("\(Self.dollars(spend.max)) \(Self.per(spend.period))") }
        if let atOnce { parts.append("\(atOnce) at once") }
        if let newTasks {
            parts.append("\(newTasks.max) new \(newTasks.max == 1 ? "task" : "tasks") \(Self.per(newTasks.period))")
        }
        return parts
    }

    /// "$5 a day · 2 at once", or "No limits".
    public var summary: String { isEmpty ? "No limits" : parts.joined(separator: " · ") }

    /// When a period's count starts again, in words for the user: "at midnight", "on Monday", "on 1 December",
    /// "at 15:12" (a rolling hour, or anything today).
    public static func resets(at date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? Locale.current
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.setLocalizedDateFormatFromTemplate("jmm")
            return "at \(formatter.string(from: date))"
        }
        if calendar.startOfDay(for: date) == date {
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
                date == tomorrow
            {
                return "at midnight"
            }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: date).day ?? 8
            formatter.setLocalizedDateFormatFromTemplate(days < 7 ? "EEEE" : "dMMMM")
            return "on \(formatter.string(from: date))"
        }
        formatter.setLocalizedDateFormatFromTemplate("EEEEjmm")
        return "on \(formatter.string(from: date))"
    }
}
