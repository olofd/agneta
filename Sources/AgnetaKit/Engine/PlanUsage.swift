// A plan's own usage in words, from the limits an engine reports (Codex's
// rate_limits: primary and secondary windows, each with used percent).
import Foundation

public enum PlanUsage {
    /// The most used of the plan's limits: "57% of this week's limit used".
    public static func describe(_ limits: JSONValue) -> String? {
        let windows = ["primary", "secondary"].compactMap { limits[$0] }.filter { $0 != .null }
        guard let busiest = windows.max(by: { (number($0["used_percent"]) ?? 0) < (number($1["used_percent"]) ?? 0) }),
            let used = number(busiest["used_percent"])
        else { return nil }
        let minutes = number(busiest["window_minutes"]) ?? 0
        let window =
            switch minutes {
            case 10_080: "this week's limit"
            case 1_440: "today's limit"
            case 300: "the 5-hour limit"
            default: minutes > 0 ? "the \(Int(minutes / 60))-hour limit" : "the plan's limit"
            }
        return "\(Int(used.rounded()))% of \(window) used"
    }

    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let v)?: v;
        case .int(let v)?: Double(v);
        default: nil
        }
    }
}
