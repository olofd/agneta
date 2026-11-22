import Foundation
import Testing

@testable import AgnetaClient

@Suite @MainActor struct ResultTests {
    struct Invoice: Codable, Sendable, Equatable { let number: String; let total: Double }
    let invoice: JSONValue = [
        "type": "object", "properties": ["number": ["type": "string"], "total": ["type": "number"]],
        "required": ["number", "total"], "additionalProperties": false
    ]
    @Test func typedResultsAndOneShotCleanup() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        host.overrides = { method, message, socket in
            guard method == "session/prompt" else { return false }
            socket.reply(
                message,
                result: [
                    "stopReason": "end_turn",
                    "_meta": [
                        resultExtension: [
                            "status": "valid", "name": "result", "mechanism": "tool", "attempts": 1,
                            "value": ["number": "A1", "total": 12.5]
                        ]
                    ]
                ])
            return true
        }
        _ = try await client.connect()
        let result = try await client.ask("Extract invoice", schema: invoice, as: Invoice.self)
        #expect(result.value == Invoice(number: "A1", total: 12.5))
        #expect(result.report.attempts == 1)
        #expect(
            host.transport.calls("session/new")[0]["params"]?["_meta"]?["agneta/policy"] == [
                "tools": "app-only", "approval": "never-ask"
            ])
        #expect(client.sessions.isEmpty)
        #expect(host.transport.calls("session/close").count == 1)
    }
    @Test func invalidCannotBecomeValidThroughDecoding() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        host.overrides = { method, message, socket in
            guard method == "session/prompt" else { return false }
            socket.reply(
                message,
                result: [
                    "stopReason": "end_turn",
                    "_meta": [
                        resultExtension: [
                            "status": "invalid", "name": "result", "mechanism": "tool", "attempts": 3,
                            "value": ["number": "A1", "total": 12.5],
                            "issues": [
                                [
                                    "path": "/total", "keyword": "maximum", "message": "too much",
                                    "schemaPath": "/properties/total/maximum"
                                ]
                            ]
                        ]
                    ]
                ])
            return true
        }
        _ = try await client.connect()
        do {
            _ = try await client.ask("Extract", schema: invoice, as: Invoice.self); Issue.record("Expected invalid")
        } catch let error as ResultFailure { #expect(error.kind == .invalid); #expect(error.report.issues.count == 1) }
        #expect(client.sessions.isEmpty)
    }
    @Test func primitiveSchemasWrapReferencesButDoNotRewriteData() async throws {
        let schema: JSONValue = [
            "type": "array", "$defs": ["item": ["type": "string"]],
            "items": ["$ref": "#/$defs/item"], "examples": [["$ref": "#"]], "not": ["$ref": "#/items"]
        ]
        let declaration = ResultDeclaration(schema: schema)
        let wire = try declaration.wire()["schemas"]!["result"]!
        #expect(wire["properties"]?["value"]?["items"]?["$ref"] == "#/$defs/item")
        #expect(wire["properties"]?["value"]?["not"]?["$ref"] == "#/properties/value/items")
        #expect(wire["properties"]?["value"]?["examples"] == [["$ref": "#"]])
        #expect(wire["$defs"]?["item"]?["type"] == "string")
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        host.overrides = { method, message, socket in
            guard method == "session/prompt" else { return false }
            socket.reply(
                message,
                result: [
                    "stopReason": "end_turn",
                    "_meta": [
                        resultExtension: [
                            "status": "valid", "name": "result", "mechanism": "tool", "attempts": 1,
                            "value": ["value": ["a", "b"]]
                        ]
                    ]
                ])
            return true
        }
        _ = try await client.connect()
        var options = SessionOptions();
        options.results = ResultDeclaration(schema: ["type": "array", "items": ["type": "string"]])
        let session = try await client.newSession(options)
        let value = try await session.ask("Return names", as: [String].self).value
        #expect(value == ["a", "b"])
        let id = session.id
        try await session.close()
        let loaded = try await client.loadSession(id)
        #expect(try await loaded.ask("Again", as: [String].self).value == ["a", "b"])
    }
    @Test func missingAndDecodeFailureAreDistinctAndErrorReportsSurvive() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        var report: JSONValue = [
            "status": "missing", "name": "result", "mechanism": "tool", "attempts": 0, "reason": "not-submitted"
        ]
        host.overrides = { method, message, socket in
            guard method == "session/prompt" else { return false }
            socket.reply(message, result: ["stopReason": "end_turn", "_meta": [resultExtension: report]]); return true
        }
        _ = try await client.connect()
        var options = SessionOptions(); options.results = ResultDeclaration(schema: invoice)
        let session = try await client.newSession(options)
        do { _ = try await session.ask("Extract", as: Invoice.self).value; Issue.record("Expected missing") } catch let
            error as ResultFailure
        { #expect(error.kind == .missing) }
        report = [
            "status": "valid", "name": "result", "mechanism": "tool", "attempts": 1, "value": ["different": "shape"]
        ]
        do {
            _ = try await session.ask("Extract", as: Invoice.self).value; Issue.record("Expected decoding failure")
        } catch let error as ResultFailure { #expect(error.kind == .decoding) }
        let failure = AgnetaError.rpc(code: -32603, message: "engine stopped", data: ["agneta": ["result": report]])
        #expect(failure.structured?.status == .valid)
        #expect(failure.structured?.value == ["different": "shape"])
    }
    @Test func ordinaryPromptCanDisableTheSessionsDefaultResult() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        _ = try await client.connect()
        var options = SessionOptions(); options.results = ResultDeclaration(schema: invoice)
        let session = try await client.newSession(options)
        _ = try await session.prompt("Chat normally", result: .disabled).result
        #expect(host.transport.calls("session/prompt")[0]["params"]?["_meta"]?[resultExtension] == false)
    }

}
