import Foundation
import Testing

@testable import AgnetaKit

/// Declarations (what a session and a prompt ask for) and a turn's result as a state machine: every sequence of
/// submissions and every way a turn ends, with its outcome and what the model is told.
@Suite struct ResultTurnTests {
    let invoice: JSONValue = [
        "type": "object",
        "properties": ["number": ["type": "string"], "total": ["type": "number", "minimum": 0]],
        "required": ["number", "total"], "additionalProperties": false
    ]
    let contact: JSONValue = ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]

    func refusal(_ value: JSONValue) -> String? {
        do {
            _ = try ResultDeclaration.parse(value)
            return nil
        } catch {
            #expect(error.field == "agneta/result")
            return error.reason
        }
    }

    func declaration(_ value: JSONValue) throws -> ResultDeclaration {
        try #require(try ResultDeclaration.parse(value))
    }

    // MARK: Declarations

    @Test func declaresNamedSchemasAndOptionallyEvery() throws {
        let both = try declaration(["schemas": ["invoice": invoice, "contact": contact], "every": "invoice"])
        #expect(both.names == ["contact", "invoice"])
        #expect(both.every == "invoice")
        #expect(both.name(forTool: "submit_contact") == "contact")
        #expect(both.name(forTool: "submit_other") == nil && both.name(forTool: "contact") == nil)
        #expect(both.recorded == ["schemas": ["invoice": invoice, "contact": contact], "every": "invoice"])
        // What's recorded declares the same when the task resumes.
        let again = try declaration(both.recorded)
        #expect(again.names == both.names && again.every == both.every)
        #expect(try declaration(["schemas": ["contact": contact]]).every == nil)
    }

    @Test func theShorthandIsOneSchemaOnEveryPrompt() throws {
        let one = try declaration(["schema": invoice])
        #expect(one.names == ["result"] && one.every == "result")
        #expect(ResultDeclaration.tool(for: "result") == "submit_result")
    }

    @Test func nothingDeclaredIsNil() throws {
        #expect(try ResultDeclaration.parse(nil) == nil)
        #expect(try ResultDeclaration.parse(.null) == nil)
    }

    @Test func refusesMalformedDeclarations() {
        let cases: [(JSONValue, String)] = [
            ("invoice", "must be an object"),
            ([:], "declare \"schema\" or \"schemas\""),
            (["schema": invoice, "schemas": ["a": contact]], "not both"),
            (["schema": invoice, "every": "result"], "\"every\" goes with \"schemas\""),
            (["schemas": [:]], "at least one"),
            (["schemas": ["invoice": invoice], "every": "contact"], "isn't declared"),
            (["schemas": ["invoice": invoice], "every": 3], "must be a schema's name"),
            (["schemas": ["Invoice": invoice]], "isn't a usable name"),
            (["schemas": ["1st": invoice]], "isn't a usable name"),
            (["schemas": ["in-voice": invoice]], "isn't a usable name"),
            (["schemas": [.init(stringLiteral: String(repeating: "a", count: 33)): invoice]], "isn't a usable name"),
            (["schemas": ["invoice": invoice], "any": true], "unknown field any"),
            (["schemas": ["invoice": ["type": "string"]]], #"schema "invoice" the schema's root must have"#),
            (
                ["schemas": ["invoice": ["type": "object", "properties": ["a": ["nullable": true]]]]],
                "at /properties/a/nullable"
            )
        ]
        for (value, expected) in cases {
            let reason = refusal(value)
            #expect(reason?.contains(expected) == true, "\(value): \(reason ?? "accepted")")
        }
    }

    @Test func boundsHowManySchemasAndHowMuch() throws {
        let nine = JSONValue.object(Dictionary(uniqueKeysWithValues: (1...9).map { ("s\($0)", contact) }))
        #expect(refusal(["schemas": nine])?.contains("at most 8 schemas") == true)
        let eight = JSONValue.object(Dictionary(uniqueKeysWithValues: (1...8).map { ("s\($0)", contact) }))
        #expect(refusal(["schemas": eight]) == nil)
        let big: JSONValue = [
            "type": "object", "description": .string(String(repeating: "x", count: 9_000)), "properties": [:]
        ]
        #expect(refusal(["schemas": ["a": big, "b": big, "c": big, "d": big]])?.contains("bytes together") == true)
    }

    @Test func aRefusalIsTheUnenforceableError() {
        let error = ResultDeclaration.refused("why").rpcError
        #expect(error.code == RPCError.invalidParams)
        #expect(error.data?["agneta"]?["unenforceable"] == ["agneta/result"])
    }

    // MARK: Requests

    @Test func aPromptAsksByNameOrTakesEvery() throws {
        let session = try declaration(["schemas": ["invoice": invoice, "contact": contact], "every": "invoice"])
        #expect(try ResultRequest.parse(nil, declaration: session) == ResultRequest(name: "invoice", attempts: 3))
        #expect(
            try ResultRequest.parse(["name": "contact"], declaration: session)
                == ResultRequest(name: "contact", attempts: 3))
        #expect(
            try ResultRequest.parse(["attempts": 5], declaration: session)
                == ResultRequest(name: "invoice", attempts: 5))
        #expect(try ResultRequest.parse(false, declaration: session) == nil)
        let plain = try declaration(["schemas": ["contact": contact]])
        #expect(try ResultRequest.parse(nil, declaration: plain) == nil)
        #expect(try ResultRequest.parse(nil, declaration: nil) == nil)
        #expect(try ResultRequest.parse(false, declaration: nil) == nil)
    }

    @Test func refusesMalformedRequests() throws {
        let session = try declaration(["schemas": ["invoice": invoice]])
        let cases: [(JSONValue, ResultDeclaration?, String)] = [
            (["name": "invoice"], nil, "declared no results"),
            (["name": "contact"], session, "wasn't declared"),
            (["name": 3], session, "declared schema's name"),
            ([:], session, "declared schema's name"),
            (["schema": contact], session, "asked for by name"),
            (["name": "invoice", "followUps": 2], session, "unknown field followUps"),
            (["name": "invoice", "attempts": 0], session, "1 to 10"),
            (["name": "invoice", "attempts": 11], session, "1 to 10"),
            (["name": "invoice", "attempts": 2.5], session, "1 to 10"),
            (["name": "invoice", "attempts": true], session, "1 to 10"),
            (true, session, "or false"),
            ("invoice", session, "or false")
        ]
        for (value, declared, expected) in cases {
            do {
                _ = try ResultRequest.parse(value, declaration: declared)
                Issue.record("accepted \(value)")
            } catch {
                #expect(error.reason.contains(expected), "\(value): \(error.reason)")
            }
        }
    }

    // MARK: The turn

    func turn(attempts: Int = 3) throws -> ResultTurn {
        try ResultTurn(
            request: ResultRequest(name: "invoice", attempts: attempts), schema: ResultSchema.compile(invoice))
    }

    let good: JSONValue = ["number": "A-1", "total": 12.5]
    let bad: JSONValue = ["number": "A-1", "total": "12.5"]
    let other: JSONValue = ["number": "B-2", "total": 7]

    @Test func validOnTheFirstAttempt() throws {
        var t = try turn()
        #expect(t.tool == "submit_invoice")
        #expect(t.submit(tool: "submit_invoice", arguments: good) == .accepted)
        #expect(t.outcome(stopReason: "end_turn", stopped: false) == .valid(good))
        #expect(t.submissions == 1)
    }

    @Test func invalidThenValid() throws {
        var t = try turn()
        guard case .refused(let issues, let left) = t.submit(tool: "submit_invoice", arguments: bad) else {
            Issue.record("not refused")
            return
        }
        #expect(left == 2 && issues.map(\.path) == ["/total"])
        #expect(t.outcome(stopReason: "end_turn", stopped: false) == .invalid(value: bad, issues: issues))
        #expect(t.submit(tool: "submit_invoice", arguments: good) == .accepted)
        #expect(t.outcome(stopReason: "end_turn", stopped: false) == .valid(good))
        #expect(t.lastRefused == nil)
    }

    @Test func theFirstValidValueWins() throws {
        var t = try turn()
        #expect(t.submit(tool: "submit_invoice", arguments: good) == .accepted)
        #expect(t.submit(tool: "submit_invoice", arguments: other) == .alreadyReceived)
        #expect(t.submit(tool: "submit_invoice", arguments: bad) == .alreadyReceived)
        #expect(t.outcome(stopReason: "end_turn", stopped: false) == .valid(good))
        #expect(t.submissions == 1) // later calls change nothing, not even the count
    }

    @Test func attemptsRunOut() throws {
        var t = try turn(attempts: 2)
        guard case .refused = t.submit(tool: "submit_invoice", arguments: bad) else {
            Issue.record("not refused"); return
        }
        guard case .exhausted = t.submit(tool: "submit_invoice", arguments: ["number": 1]) else {
            Issue.record("not exhausted")
            return
        }
        #expect(t.submit(tool: "submit_invoice", arguments: good) == .noAttemptsLeft)
        guard case .invalid(let value, _) = t.outcome(stopReason: "end_turn", stopped: false) else {
            Issue.record("not invalid")
            return
        }
        #expect(value == ["number": 1]) // the last refused value is the one reported
    }

    @Test func aWrongToolCountsAsAnAttempt() throws {
        var t = try turn(attempts: 2)
        #expect(t.submit(tool: "submit_contact", arguments: ["name": "x"]) == .wrongTool(expected: "submit_invoice"))
        #expect(t.submit(tool: "submit_contact", arguments: ["name": "x"]) == .wrongTool(expected: "submit_invoice"))
        #expect(t.submit(tool: "submit_invoice", arguments: good) == .noAttemptsLeft)
        #expect(t.outcome(stopReason: "end_turn", stopped: false) == .missing(.notSubmitted))
    }

    /// How a turn ends decides what's reported when nothing was accepted; an accepted value always stands.
    @Test func outcomesByHowTheTurnEnded() throws {
        let rows: [(submit: JSONValue?, stopReason: String, stopped: Bool, expected: String)] = [
            (nil, "end_turn", false, "missing:not-submitted"),
            (nil, "refusal", false, "missing:refused"),
            (nil, "max_tokens", false, "missing:truncated"),
            (nil, "max_turn_requests", false, "missing:not-submitted"),
            (nil, "cancelled", false, "missing:stopped"),
            (nil, "end_turn", true, "missing:stopped"),
            (["number": 1], "end_turn", false, "invalid"),
            (["number": 1], "refusal", false, "invalid"),
            (["number": 1], "cancelled", false, "missing:stopped"),
            (["number": 1], "max_turn_requests", true, "missing:stopped"),
            (["number": "A", "total": 1], "cancelled", false, "valid"),
            (["number": "A", "total": 1], "end_turn", true, "valid"),
            (["number": "A", "total": 1], "max_tokens", false, "valid")
        ]
        for row in rows {
            var t = try turn()
            if let value = row.submit { _ = t.submit(tool: "submit_invoice", arguments: value) }
            let outcome = t.outcome(stopReason: row.stopReason, stopped: row.stopped)
            let shown: String =
                switch outcome {
                case .valid: "valid"
                case .invalid: "invalid"
                case .missing(let reason): "missing:\(reason.rawValue)"
                }
            #expect(shown == row.expected, "\(row)")
            #expect(outcome.status == row.expected.components(separatedBy: ":")[0])
        }
    }

    // MARK: What the model reads

    @Test func theModelIsToldWhatToFixAndHowManyTriesAreLeft() throws {
        var t = try turn()
        let answer = t.submit(tool: "submit_invoice", arguments: ["number": "A", "total": -3])
        let told = ResultWording.answer(answer, tool: t.tool, schema: t.schema)
        #expect(told.isError)
        #expect(
            told.text
                == "The result doesn't match its schema, so it wasn't accepted. Fix these and call submit_invoice again "
                + "(2 attempts left):\n- /total: must be at least 0, is -3 (schema: {\"minimum\":0,\"type\":\"number\"})"
        )
        let accepted = ResultWording.answer(.accepted, tool: "submit_invoice", schema: t.schema)
        #expect(!accepted.isError && accepted.text.contains("Don't call submit_invoice again"))
        for other: ResultTurn.Answer in [.alreadyReceived, .wrongTool(expected: "submit_invoice"), .noAttemptsLeft] {
            #expect(ResultWording.answer(other, tool: "submit_invoice", schema: t.schema).isError)
        }
        #expect(
            ResultWording.answer(.refused(issues: [], left: 1), tool: "x", schema: t.schema).text.contains(
                "(1 attempt left)"))
        #expect(ResultWording.note(tool: "submit_invoice").contains("call the tool submit_invoice once"))
    }

    @Test func quotesOnlyShortSchemaPartsWithoutAnnotations() throws {
        let schema = try ResultSchema.compile([
            "type": "object",
            "properties": [
                "code": ["type": "string", "pattern": "^[A-Z]{3}$", "description": "An ISO currency code"],
                "long": ["type": "string", "enum": .array((0..<100).map { .string("value\($0)") })]
            ]
        ])
        let issues = schema.validate(["code": "usd", "long": "x"])
        #expect(schema.fragment(for: issues[0]) == #"{"pattern":"^[A-Z]{3}$","type":"string"}"#)
        #expect(schema.fragment(for: issues[1]) == nil)
        #expect(
            schema.fragment(for: ResultIssue(path: "", keyword: "limit", message: "", schemaPath: "")) == nil)
    }
}
