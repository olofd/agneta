// What one app has used, for the limits the user sets for it (AppLimits) and the usage Settings shows: hourly totals
// of what its turns on API keys cost, the tokens, turns and new tasks. Hourly buckets, keyed by the start of the hour
// in UTC, are enough for a day, a week and a month, and say nothing of what ran. Saved by the runtime (`app_usage`),
// kept 35 days, independent of task history: clearing history doesn't hand an app a fresh budget.
//
// Calendar periods are computed from the calendar at each check, so midnight, a change to or from summer time and a
// change of time zone are taken as they come. A bucket counts toward a period when its hour overlaps it: exact where
// the time zone is a whole number of hours from UTC, and at worst early by the part of an hour before midnight (or
// the period's start) elsewhere, never late.
//
// A clock set back (by the user, or a sync) is taken as it is: usage recorded "later" stays in its hour and counts in
// any period that hour overlaps, so a period may look fuller than it was, never emptier; new tasks started "in the
// future" count in the rolling hour until an hour after their recorded start.
//
// The rolling hour of new tasks uses each start's exact time while Agneta runs. Starts from before a restart are
// known only by their hour, so they count as a whole until two hours after that hour began: never less than they were.
import Foundation

public struct AppMeter: Sendable, Equatable {
    public struct Usage: Sendable, Equatable, Codable {
        /// What turns on API keys cost, as their engines reported it: each turn's share of its task's known cost.
        /// Turns on a plan aren't counted here: the plan pays, nothing is charged per call.
        public var cost: Double
        public var inputTokens: Int
        public var outputTokens: Int
        public var turns: Int
        public var tasks: Int
        /// Turns on API keys that called a model the engine gave no price for (Goose reports none, OpenCode $0, for a
        /// model it has no price for): what they cost isn't known, so a spending limit didn't count it.
        public var unpriced: Int

        public init(cost: Double = 0, inputTokens: Int = 0, outputTokens: Int = 0, turns: Int = 0, tasks: Int = 0, unpriced: Int = 0) {
            self.cost = cost
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.turns = turns
            self.tasks = tasks
            self.unpriced = unpriced
        }

        public static func + (a: Usage, b: Usage) -> Usage {
            Usage(cost: a.cost + b.cost, inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens,
                  turns: a.turns + b.turns, tasks: a.tasks + b.tasks, unpriced: a.unpriced + b.unpriced)
        }

        public var isEmpty: Bool { self == Usage() }
    }

    /// Totals by the start of each hour (UTC).
    public private(set) var hours: [Date: Usage]
    /// When each new task counted since the meter was made started, for the rolling hour.
    private var starts: [Date] = []
    /// New tasks from before a restart, by hour.
    private var earlierStarts: [Date: Int]

    /// A meter going on from saved totals (the runtime's `app_usage`).
    public init(restoring hours: [Date: Usage] = [:]) {
        self.hours = hours
        earlierStarts = hours.compactMapValues { $0.tasks > 0 ? $0.tasks : nil }
    }

    /// The start of the hour `date` falls in, in UTC.
    public static func hour(of date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    public mutating func add(_ usage: Usage, at date: Date) {
        guard !usage.isEmpty else { return }
        hours[Self.hour(of: date), default: Usage()] = hours[Self.hour(of: date), default: Usage()] + usage
    }

    /// A new task counted (reserved before its engine starts, so a burst can't all pass the check).
    public mutating func taskStarted(at date: Date) {
        starts.append(date)
        add(Usage(tasks: 1), at: date)
    }

    /// A task counted at `date` that didn't start after all.
    public mutating func taskRefunded(startedAt date: Date) {
        guard let index = starts.lastIndex(of: date) else { return }
        starts.remove(at: index)
        let hour = Self.hour(of: date)
        hours[hour]?.tasks -= 1
        if hours[hour]?.isEmpty == true { hours[hour] = nil }
    }

    /// The period `now` is in: the last 60 minutes for an hour; the calendar's day, week or month otherwise.
    public static func interval(_ period: AppLimits.Period, now: Date, calendar: Calendar) -> DateInterval {
        let component: Calendar.Component
        switch period {
        case .hour: return DateInterval(start: now.addingTimeInterval(-3600), end: now)
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        return calendar.dateInterval(of: component, for: now) ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
    }

    /// Everything counted in the period `now` is in. For an hour, only the new tasks are exact (the rest is by bucket).
    public func total(_ period: AppLimits.Period, now: Date, calendar: Calendar) -> Usage {
        let span = Self.interval(period, now: now, calendar: calendar)
        var total = hours.reduce(Usage()) { sum, entry in
            entry.key < span.end && entry.key.addingTimeInterval(3600) > span.start ? sum + entry.value : sum
        }
        if period == .hour { total.tasks = tasks(.hour, now: now, calendar: calendar) }
        return total
    }

    public func spent(_ period: AppLimits.Period, now: Date, calendar: Calendar) -> Double {
        total(period, now: now, calendar: calendar).cost
    }

    /// New tasks in the period `now` is in.
    public func tasks(_ period: AppLimits.Period, now: Date, calendar: Calendar) -> Int {
        guard period == .hour else { return total(period, now: now, calendar: calendar).tasks }
        let since = now.addingTimeInterval(-3600)
        return starts.count(where: { $0 > since }) + earlierStarts.reduce(0) { $0 + ($1.key.addingTimeInterval(7200) > now ? $1.value : 0) }
    }

    /// When the count starts again: the next period's start, or for the rolling hour when the oldest new task in it
    /// leaves it (nil when there's none).
    public func resetsAt(_ period: AppLimits.Period, now: Date, calendar: Calendar) -> Date? {
        guard period == .hour else { return Self.interval(period, now: now, calendar: calendar).end }
        let since = now.addingTimeInterval(-3600)
        let leaving = starts.filter { $0 > since }.map { $0.addingTimeInterval(3600) }
            + earlierStarts.keys.filter { $0.addingTimeInterval(7200) > now }.map { $0.addingTimeInterval(7200) }
        return leaving.min()
    }

    /// Forgets what's older than `date` (the runtime keeps 35 days).
    public mutating func prune(before date: Date) {
        hours = hours.filter { $0.key >= date }
        earlierStarts = earlierStarts.filter { $0.key >= date }
        starts.removeAll { $0 < date }
    }
}
