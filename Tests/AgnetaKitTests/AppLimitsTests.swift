// The limits the user sets for an app and the meter that counts them, as values: their JSON, what's valid, the words
// they're shown in, and periods across midnight, summer time and a change of time zone.
import Foundation
import Testing
@testable import AgnetaKit

struct AppLimitsTests {
    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        return calendar
    }

    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func limitsRoundTripAndAreChecked() throws {
        let limits = AppLimits(spend: .init(max: 5, period: .day), atOnce: 2, newTasks: .init(max: 10, period: .hour))
        let data = try JSONEncoder().encode(limits)
        #expect(try JSONDecoder().decode(AppLimits.self, from: data) == limits)
        // Saved without `whenReached` (or with fields this build doesn't know), they read as stop.
        let read = try JSONDecoder().decode(AppLimits.self, from: Data(#"{"spend":{"max":2.5,"period":"week","later":1},"other":true}"#.utf8))
        #expect(read == AppLimits(spend: .init(max: 2.5, period: .week)))
        #expect(try JSONDecoder().decode(AppLimits.self, from: Data("{}".utf8)) == .none)

        #expect(limits.problem(global: 8) == nil)
        for bad in [AppLimits(spend: .init(max: 0, period: .day)), AppLimits(spend: .init(max: .infinity, period: .day)),
                    AppLimits(spend: .init(max: 10_001, period: .day)), AppLimits(spend: .init(max: 1, period: .hour)),
                    AppLimits(atOnce: 0), AppLimits(atOnce: 9), AppLimits(newTasks: .init(max: 0, period: .hour)),
                    AppLimits(newTasks: .init(max: 3, period: .month))] {
            #expect(bad.problem(global: 8) != nil, "\(bad)")
        }
    }

    @Test func limitsAreSaidPlainly() {
        #expect(AppLimits.none.summary == "No limits")
        #expect(AppLimits(spend: .init(max: 5, period: .day), atOnce: 2).summary == "$5 a day · 2 at once")
        #expect(AppLimits(spend: .init(max: 2.5, period: .month), newTasks: .init(max: 1, period: .day)).summary == "$2.50 a month · 1 new task a day")
        #expect(AppLimits(newTasks: .init(max: 10, period: .hour)).summary == "10 new tasks an hour")
        #expect(AppLimits.cents(1.2) == "$1.20")

        let calendar = Self.calendar("Europe/Stockholm")
        let now = Self.date("2026-11-19T14:00:00Z") // a Thursday, 15:00 in Stockholm
        #expect(AppLimits.resets(at: Self.date("2026-11-19T23:00:00Z"), now: now, calendar: calendar) == "at midnight")
        #expect(AppLimits.resets(at: Self.date("2026-11-19T15:12:00Z"), now: now, calendar: calendar) == "at 16:12")
        #expect(AppLimits.resets(at: Self.date("2026-11-22T23:00:00Z"), now: now, calendar: calendar) == "on Monday")
        #expect(AppLimits.resets(at: Self.date("2026-11-30T23:00:00Z"), now: now, calendar: calendar) == "on 1 December")
    }

    @Test func periodsFollowTheCalendar() {
        let calendar = Self.calendar("Europe/Stockholm")
        var meter = AppMeter()
        meter.add(.init(cost: 1, turns: 1), at: Self.date("2026-11-19T22:30:00Z")) // 23:30 in Stockholm
        meter.add(.init(cost: 2, turns: 1), at: Self.date("2026-11-19T23:10:00Z")) // 00:10, the next day
        #expect(meter.spent(.day, now: Self.date("2026-11-19T22:59:00Z"), calendar: calendar) == 1)
        #expect(meter.spent(.day, now: Self.date("2026-11-19T23:30:00Z"), calendar: calendar) == 2)
        // Monday 2026-11-16 starts the week, so both count this week, and this month.
        #expect(meter.spent(.week, now: Self.date("2026-11-20T08:00:00Z"), calendar: calendar) == 3)
        #expect(meter.spent(.month, now: Self.date("2026-11-20T08:00:00Z"), calendar: calendar) == 3)
        #expect(meter.resetsAt(.day, now: Self.date("2026-11-19T12:00:00Z"), calendar: calendar) == Self.date("2026-11-19T23:00:00Z"))
        #expect(meter.resetsAt(.month, now: Self.date("2026-11-19T12:00:00Z"), calendar: calendar) == Self.date("2026-11-30T23:00:00Z"))

        // Summer time ends on 25 October 2026 in Stockholm: that day is 25 hours long, and midnight moves by an hour.
        #expect(meter.resetsAt(.day, now: Self.date("2026-10-25T12:00:00Z"), calendar: calendar) == Self.date("2026-10-25T23:00:00Z"))
        #expect(meter.resetsAt(.day, now: Self.date("2026-10-24T12:00:00Z"), calendar: calendar) == Self.date("2026-10-24T22:00:00Z"))

        // The same usage seen from another time zone (the user travelled): its own midnight.
        let tokyo = Self.calendar("Asia/Tokyo")
        #expect(meter.spent(.day, now: Self.date("2026-11-19T23:30:00Z"), calendar: tokyo) == 3) // 08:30 on the 20th in Tokyo
        // Half an hour off UTC: the bucket over midnight counts toward both days, never neither.
        let india = Self.calendar("Asia/Kolkata")
        var straddling = AppMeter()
        straddling.add(.init(cost: 4), at: Self.date("2026-11-19T18:40:00Z")) // 00:10 on the 20th in India; its hour began 23:30
        #expect(straddling.spent(.day, now: Self.date("2026-11-19T18:45:00Z"), calendar: india) == 4)
        #expect(straddling.spent(.day, now: Self.date("2026-11-19T18:20:00Z"), calendar: india) == 4)
    }

    @Test func newTasksCountInARollingHourAndAfterARestart() {
        let calendar = Self.calendar("Europe/Stockholm")
        var meter = AppMeter()
        let start = Self.date("2026-11-19T10:15:00Z")
        meter.taskStarted(at: start)
        meter.taskStarted(at: start.addingTimeInterval(600))
        let refunded = start.addingTimeInterval(700)
        meter.taskStarted(at: refunded)
        meter.taskRefunded(startedAt: refunded)
        #expect(meter.tasks(.hour, now: start.addingTimeInterval(900), calendar: calendar) == 2)
        #expect(meter.resetsAt(.hour, now: start.addingTimeInterval(900), calendar: calendar) == start.addingTimeInterval(3600))
        #expect(meter.tasks(.hour, now: start.addingTimeInterval(3700), calendar: calendar) == 1)
        #expect(meter.tasks(.hour, now: start.addingTimeInterval(4300), calendar: calendar) == 0)
        #expect(meter.resetsAt(.hour, now: start.addingTimeInterval(4300), calendar: calendar) == nil)
        #expect(meter.tasks(.day, now: start.addingTimeInterval(4300), calendar: calendar) == 2)

        // After a restart only the hour is known: they count until two hours after it began, never less than they were.
        let restored = AppMeter(restoring: meter.hours)
        #expect(restored.tasks(.hour, now: start.addingTimeInterval(900), calendar: calendar) == 2)
        #expect(restored.tasks(.hour, now: Self.date("2026-11-19T11:59:00Z"), calendar: calendar) == 2)
        #expect(restored.tasks(.hour, now: Self.date("2026-11-19T12:00:00Z"), calendar: calendar) == 0)
        #expect(restored.resetsAt(.hour, now: start, calendar: calendar) == Self.date("2026-11-19T12:00:00Z"))

        var pruned = meter
        pruned.prune(before: Self.date("2026-11-19T11:00:00Z"))
        #expect(pruned.hours.isEmpty && pruned.tasks(.hour, now: start.addingTimeInterval(900), calendar: calendar) == 0)
    }
}
