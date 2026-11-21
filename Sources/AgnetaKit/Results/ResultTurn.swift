// One turn's structured result, as a state machine.
//
// Every rule about when a turn has a result lives here, written once and tested as a table: the router feeds in what
// happens (a submission from the result tool, the turn's end) and does what it's told (answer the model, report the
// outcome). No clocks and no I/O, so the same events always give the same outcome.
//
// The rules, each one measured elsewhere as a real failure (docs/APP_PROTOCOL.md, Structured results):
// - The first valid value wins. A later call can't replace it: models call an end-of-turn tool twice, the second
//   silently replacing the first, or call it early and again after the work.
// - Submissions are bounded: every call counts, valid or not, so a confused model can't loop on the tool.
// - A turn that was stopped reports no value it didn't accept, and an accepted value is still reported.
import Foundation

public struct ResultTurn: Sendable {
    /// This turn's own identity: work that waited (a value being checked) finds out whether its turn is still open.
    public let id = UUID()
    public let request: ResultRequest
    public let schema: ResultSchema
    /// The tool this turn's result comes through.
    public var tool: String { ResultDeclaration.tool(for: request.name) }

    public private(set) var accepted: JSONValue?
    /// Calls of the session's result tools so far: valid or not, the wrong tool included.
    public private(set) var submissions = 0
    /// The last value refused, and why: reported if no value is accepted.
    public private(set) var lastRefused: ResultOutcome.Refused?
    /// Once the turn ended its outcome is final: nothing a late call does changes it.
    public private(set) var ended: ResultOutcome?

    /// Made by the declaration (`ResultDeclaration.turn(for:)`), so a request always meets its own schema.
    init(request: ResultRequest, schema: ResultSchema) {
        self.request = request
        self.schema = schema
    }

    /// What the model is told after a call, and what happened.
    public enum Answer: Sendable, Equatable {
        /// The value matches and is now the turn's result.
        case accepted
        /// It doesn't; the model may try again `left` more times.
        case refused(issues: [ResultIssue], left: Int)
        /// It doesn't, and that was the last attempt.
        case exhausted(issues: [ResultIssue])
        /// A value was already accepted; nothing changed.
        case alreadyReceived
        /// The model called another result's tool; the turn asks for `expected`. It counted as an attempt.
        case wrongTool(expected: String, left: Int)
        /// No attempts are left; nothing was checked.
        case noAttemptsLeft
        /// The turn has ended (or no result is asked for now); nothing was checked.
        case notAsked
    }

    /// A call reserved for checking: it counted as an attempt, and its value is being validated.
    public struct Ticket: Sendable, Equatable {
        public let attempt: Int
    }

    /// What a call does before its value is checked: counts as an attempt and gets a ticket, or is answered at once
    /// (the turn ended, a value was accepted, no attempts are left, the wrong tool). On the router's actor, with
    /// `complete`, so the bookkeeping is one step each side of the validation, which runs off the actor.
    public mutating func reserve(tool called: String) -> Reservation {
        if ended != nil { return .answered(.notAsked) }
        if accepted != nil { return .answered(.alreadyReceived) }
        guard submissions < request.attempts else { return .answered(.noAttemptsLeft) }
        submissions += 1
        guard called == tool else { return .answered(.wrongTool(expected: tool, left: request.attempts - submissions)) }
        return .check(Ticket(attempt: submissions))
    }

    /// What `reserve` gives: a value to check, or an answer already.
    public enum Reservation: Sendable, Equatable {
        case check(Ticket)
        case answered(Answer)
    }

    /// A reserved call's value, checked: the first valid value to finish checking wins, so two calls checked at once
    /// never both count (with calls in parallel, that may not be the one sent first; values are usually checked in
    /// well under a millisecond, so the order they were sent in almost always holds).
    public mutating func complete(_ ticket: Ticket, value: JSONValue, issues: [ResultIssue]) -> Answer {
        if ended != nil { return .notAsked }
        if accepted != nil { return .alreadyReceived }
        if issues.isEmpty {
            accepted = value
            lastRefused = nil
            return .accepted
        }
        // A later attempt's refusal is the one reported, whichever finished checking first.
        if ticket.attempt >= (lastRefusedAttempt ?? 0) {
            lastRefused = .init(value: value, issues: issues)
            lastRefusedAttempt = ticket.attempt
        }
        let left = request.attempts - submissions
        return left > 0 ? .refused(issues: issues, left: left) : .exhausted(issues: issues)
    }

    private var lastRefusedAttempt: Int?

    /// `reserve`, validation on the caller's thread and `complete` in one step: for tests and values known to be
    /// shallow. The router validates off its stack (`ResultSchema.checked`).
    public mutating func submit(tool called: String, arguments: JSONValue) -> Answer {
        switch reserve(tool: called) {
        case .answered(let answer): return answer
        case .check(let ticket): return complete(ticket, value: arguments, issues: schema.validate(arguments))
        }
    }

    /// Ends the turn with `stopReason` (ACP's), `stopped` when a cancel, the user's Stop or a limit ended it, and gives
    /// its outcome. Final: ending again gives the same outcome, and later calls are told nothing is asked.
    public mutating func end(stopReason: String, stopped: Bool) -> ResultOutcome {
        if let ended { return ended }
        let outcome = outcome(stopReason: stopReason, stopped: stopped)
        ended = outcome
        return outcome
    }

    /// The outcome by one rule of precedence: a valid value wins; attempts used up on refused values are `invalid`
    /// however the turn ended; otherwise a turn that ended abnormally (stopped, a limit, out of tokens, a refusal) is
    /// `missing` for that reason, with the last refused value as detail; and one that simply ended is `invalid` if a
    /// value was refused, else `missing` because nothing was submitted.
    func outcome(stopReason: String, stopped: Bool) -> ResultOutcome {
        if let accepted { return .valid(accepted) }
        if let lastRefused, submissions >= request.attempts {
            return .invalid(value: lastRefused.value, issues: lastRefused.issues)
        }
        let abnormal: ResultOutcome.Reason? =
            stopped || stopReason == "cancelled" || stopReason == "max_turn_requests"
            ? .stopped
            : stopReason == "max_tokens" ? .truncated : stopReason == "refusal" ? .refused : nil
        if let abnormal { return .missing(abnormal, last: lastRefused) }
        if let lastRefused { return .invalid(value: lastRefused.value, issues: lastRefused.issues) }
        return .missing(.notSubmitted, last: nil)
    }
}

public enum ResultOutcome: Sendable, Equatable {
    case valid(JSONValue)
    case invalid(value: JSONValue, issues: [ResultIssue])
    /// No valid value, for `Reason`; `last` is the last value refused before the turn ended, if any.
    case missing(Reason, last: Refused?)

    public struct Refused: Sendable, Equatable {
        public var value: JSONValue
        public var issues: [ResultIssue]
    }

    public enum Reason: String, Sendable, Equatable {
        /// Cancelled, stopped by the user, or a limit ended the turn (Agneta's or the engine's).
        case stopped
        /// The model refused (`stopReason: "refusal"`).
        case refused
        /// The model ran out of output tokens.
        case truncated
        /// The turn ended without a call of the result tool.
        case notSubmitted = "not-submitted"
    }

    public var status: String {
        switch self {
        case .valid: "valid"
        case .invalid: "invalid"
        case .missing: "missing"
        }
    }
}

/// What the model reads: the note on the prompt and the result tool's answers. Short and fixed, so they're cheap and
/// the same on every engine; documented in docs/APP_PROTOCOL.md.
public enum ResultWording {
    /// Added to a prompt that asks for a result.
    public static func note(tool: String) -> String {
        // Engines show the tool under their own prefixes (mcp__agneta-result__…, agneta-result__…): named by its own
        // name and its server, which every engine keeps.
        "When your work for this request is done, call the tool \(tool) (from the \(ResultServer.name) tools) once, "
            + "with the result as its arguments. Don't call it before then."
    }

    /// Told to a call made while no turn asks for a result.
    public static let notAsked = "No result is being asked for now. Don't call this tool unless a request asks for it."

    /// The longest line about one issue, and the longest answer, in characters: the answer lands in the model's
    /// context, and a value's own keys must not be able to fill it.
    static let maxLine = 300
    static let maxAnswer = 4_000

    /// The tool's answer to a call.
    public static func answer(_ answer: ResultTurn.Answer, tool: String, schema: ResultSchema) -> (
        text: String, isError: Bool
    ) {
        switch answer {
        case .accepted:
            return ("Result received; it's final. End your turn now, and don't call \(tool) again.", false)
        case .refused(let issues, let left):
            return (
                bounded(
                    "The result doesn't match its schema, so it wasn't accepted. Fix these and call \(tool) again "
                        + "(\(attempts(left)) left):", issues, schema: schema), true
            )
        case .exhausted(let issues):
            return (
                bounded(
                    "The result doesn't match its schema, and that was the last attempt, so no result was accepted. "
                        + "Don't call \(tool) again in this turn. What was wrong:", issues, schema: schema), true
            )
        case .alreadyReceived:
            return (
                "A result was already received in this turn; it's final and can't be changed. End your turn now.", true
            )
        case .wrongTool(let expected, let left):
            if left == 0 {
                return (
                    "This request asks for its result through \(expected), and no attempts are left, so no result was "
                        + "accepted. Don't call result tools again in this turn.", true
                )
            }
            return (
                "This request asks for its result through \(expected); call that tool instead (\(attempts(left)) left).",
                true
            )
        case .noAttemptsLeft:
            return ("No attempts are left in this turn; no result was accepted. Don't call \(tool) again.", true)
        case .notAsked:
            return (notAsked, true)
        }
    }

    static func attempts(_ n: Int) -> String { n == 1 ? "1 attempt" : "\(n) attempts" }

    /// The heading and the issues, each line and the whole cut to their bounds.
    static func bounded(_ heading: String, _ issues: [ResultIssue], schema: ResultSchema) -> String {
        var text = heading
        for (i, issue) in issues.enumerated() {
            let line = "\n" + cut(line(issue, schema: schema), to: maxLine)
            if text.count + line.count > maxAnswer {
                text += "\n… and \(issues.count - i) more"
                break
            }
            text += line
        }
        return text
    }

    static func cut(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    /// One issue on a line: where, what, and the part of the schema it broke (engines may not show the model every
    /// constraint, so the failing part is quoted). Where is escaped: a key can't start a line of its own.
    static func line(_ issue: ResultIssue, schema: ResultSchema) -> String {
        let at = issue.path.isEmpty ? "the result" : escapeControls(issue.path)
        var line = "- \(at): \(issue.message)"
        if let quoted = schema.fragment(for: issue) { line += " (schema: \(quoted))" }
        return line
    }

    static func escapeControls(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7f || scalar.value == 0x2028 || scalar.value == 0x2029 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

extension ResultSchema {
    /// The schema an issue broke, as compact JSON, when it's short enough to quote.
    func fragment(for issue: ResultIssue, maxLength: Int = 200) -> String? {
        guard issue.keyword != "limit", issue.keyword != "false" else { return nil }
        // The issue's schema path ends with its keyword: quote the schema that holds it.
        var tokens = issue.schemaPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if tokens.last == issue.keyword { tokens.removeLast() }
        var node: JSONValue? = source
        for token in tokens.dropFirst() {
            let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch node {
            case .object(let fields)?: node = fields[key]
            case .array(let items)?: node = Int(key).flatMap { items.indices.contains($0) ? items[$0] : nil }
            default: node = nil
            }
        }
        guard var fields = node?.objectValue else { return nil }
        for annotation in ["description", "title", "examples", "$comment", "default"] { fields[annotation] = nil }
        guard let data = try? JSONCoding.encode(JSONValue.object(fields)),
            let text = String(data: data, encoding: .utf8),
            text.count <= maxLength
        else { return nil }
        return text
    }
}
