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
    public let request: ResultRequest
    public let schema: ResultSchema
    /// The tool this turn's result comes through.
    public var tool: String { ResultDeclaration.tool(for: request.name) }

    public private(set) var accepted: JSONValue?
    /// Submissions so far, valid or not.
    public private(set) var submissions = 0
    /// The last value refused, and why: reported if no value is accepted.
    public private(set) var lastRefused: (value: JSONValue, issues: [ResultIssue])?

    public init(request: ResultRequest, schema: ResultSchema) {
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
        /// The model called another result's tool; the turn asks for `expected`.
        case wrongTool(expected: String)
        /// No attempts are left; nothing was checked.
        case noAttemptsLeft
    }

    /// A call of one of the session's result tools during this turn, with its arguments (the value itself).
    public mutating func submit(tool called: String, arguments: JSONValue) -> Answer {
        if accepted != nil { return .alreadyReceived }
        guard submissions < request.attempts else { return .noAttemptsLeft }
        submissions += 1
        guard called == tool else { return .wrongTool(expected: tool) }
        let issues = schema.validate(arguments)
        if issues.isEmpty {
            accepted = arguments
            lastRefused = nil
            return .accepted
        }
        lastRefused = (arguments, issues)
        let left = request.attempts - submissions
        return left > 0 ? .refused(issues: issues, left: left) : .exhausted(issues: issues)
    }

    /// The turn's result, once it ended with `stopReason` (ACP's), `stopped` when a cancel, the user's Stop or a limit
    /// ended it.
    public func outcome(stopReason: String, stopped: Bool) -> ResultOutcome {
        if let accepted { return .valid(accepted) }
        if stopped || stopReason == "cancelled" { return .missing(.stopped) }
        if let lastRefused { return .invalid(value: lastRefused.value, issues: lastRefused.issues) }
        switch stopReason {
        case "refusal": return .missing(.refused)
        case "max_tokens": return .missing(.truncated)
        default: return .missing(.notSubmitted)
        }
    }
}

public enum ResultOutcome: Sendable, Equatable {
    case valid(JSONValue)
    case invalid(value: JSONValue, issues: [ResultIssue])
    case missing(Reason)

    public enum Reason: String, Sendable, Equatable {
        /// Cancelled, stopped by the user or a limit, or the engine stopped.
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
        "When your work for this request is done, call the tool \(tool) once, with the result as its arguments. "
            + "Don't call it before then."
    }

    /// Told to a call made while no turn asks for a result.
    public static let notAsked = "No result is being asked for now. Don't call this tool unless a request asks for it."

    /// The tool's answer to a call.
    public static func answer(_ answer: ResultTurn.Answer, tool: String, schema: ResultSchema) -> (
        text: String, isError: Bool
    ) {
        switch answer {
        case .accepted:
            return ("Result received. Don't call \(tool) again in this turn.", false)
        case .refused(let issues, let left):
            return (
                "The result doesn't match its schema, so it wasn't accepted. Fix these and call \(tool) again "
                    + "(\(left) \(left == 1 ? "attempt" : "attempts") left):\n" + list(issues, schema: schema), true
            )
        case .exhausted(let issues):
            return (
                "The result doesn't match its schema, and that was the last attempt; it wasn't accepted:\n"
                    + list(issues, schema: schema) + "\nDon't call \(tool) again in this turn.", true
            )
        case .alreadyReceived:
            return ("A result was already received in this turn and can't be changed. Don't call \(tool) again.", true)
        case .wrongTool(let expected):
            return ("This request asks for its result through \(expected); call that tool instead.", true)
        case .noAttemptsLeft:
            return ("No attempts are left in this turn; the result wasn't accepted. Don't call \(tool) again.", true)
        }
    }

    /// Each issue on a line: where, what, and the part of the schema it broke (engines may not show the model every
    /// constraint, so the failing part is quoted).
    static func list(_ issues: [ResultIssue], schema: ResultSchema) -> String {
        issues.map { issue in
            let at = issue.path.isEmpty ? "the result" : issue.path
            var line = "- \(at): \(issue.message)"
            if let quoted = schema.fragment(for: issue) { line += " (schema: \(quoted))" }
            return line
        }.joined(separator: "\n")
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
