// Structured results through the router, end to end with the fake engine: an app declares results, its engine gets
// Agneta's result server, the engine's calls reach it over real HTTP, and the prompt's reply carries the outcome.
import Foundation
import Testing

@testable import AgnetaKit

@Suite(.serialized) struct ResultContractTests {
    typealias Stack = RouterContractTests.Stack

    static let invoice: JSONValue = [
        "type": "object",
        "properties": ["number": ["type": "string"], "total": ["type": "number", "minimum": 0]],
        "required": ["number", "total"], "additionalProperties": false
    ]
    static let contact: JSONValue = ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]
    static let good: JSONValue = ["number": "A-1", "total": 12.5]
    static let bad: JSONValue = ["number": "A-1", "total": "12.5"]

    /// A prompt whose engine calls result tools as scripted.
    static func script(_ calls: [JSONValue], stopReason: String = "end_turn") -> String {
        let json: JSONValue = ["calls": .array(calls), "stopReason": .string(stopReason)]
        return "result " + String(decoding: (try? JSONCoding.encode(json)) ?? Data(), as: UTF8.self)
    }

    static func call(_ tool: String, _ arguments: JSONValue, ask: Bool = false) -> JSONValue {
        ["tool": .string(tool), "arguments": arguments, "ask": .bool(ask)]
    }

    func prompt(_ app: AppClient, _ session: String, _ text: String, _ result: JSONValue? = nil) async throws
        -> JSONValue
    {
        var params: JSONValue = ["sessionId": .string(session), "prompt": [["type": "text", "text": .string(text)]]]
        if let result { params = params.setting("_meta", to: ["agneta/result": result]) }
        return try await app.request("session/prompt", params)
    }

    func results(_ stack: Stack, _ task: String) throws -> [JSONValue] {
        try stack.records(task).filter { $0["type"] == "result" }
    }

    @Test func aDeclaredResultComesBackValidOnTheFirstAttempt() async throws {
        let stack = try await Stack.start(port: 47760)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Results")
        #expect(await stack.router.resultServer == nil) // nothing listens until a session declares results

        let opened = try await app.request(
            "session/new",
            [
                "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                "_meta": [
                    "agneta/policy": ["tools": "app-only", "approval": "never-ask"], "agneta": ["account": "brokered"],
                    "agneta/result": ["schema": Self.invoice]
                ]
            ])
        let session = try #require(opened["sessionId"]?.stringValue)
        #expect(
            opened["_meta"]?["agneta"]?["results"]
                == [
                    "declared": ["result"], "every": "result", "mechanism": "tool", "schemas": ["result": Self.invoice]
                ])
        // Declaring results loads the app's tools up front, so the model never has to search for the result tool.
        #expect(opened["_meta"]?["agneta"]?["appTools"]?["load"] == "always")
        // The engine got Agneta's result server beside the app's (none here), on loopback with its own bearer.
        let servers = try #require(await stack.engines.opening.last?.params["mcpServers"]?.arrayValue)
        #expect(servers.count == 1 && servers[0]["name"] == "agneta-result" && servers[0]["type"] == "http")
        #expect(servers[0]["url"]?.stringValue?.hasPrefix("http://127.0.0.1:") == true)
        #expect(servers[0]["headers"]?.arrayValue?.first?["value"]?.stringValue?.hasPrefix("Bearer ") == true)

        let reply = try await prompt(app, session, Self.script([Self.call("submit_result", Self.good)]))
        #expect(
            reply["_meta"]?["agneta/result"]
                == ["status": "valid", "name": "result", "mechanism": "tool", "attempts": 1, "value": Self.good])
        #expect(reply["stopReason"] == "end_turn")
        let answer = try #require(await stack.engines.resultAnswers.first ?? nil)
        #expect(!answer.isError && answer.text.hasPrefix("Result received"))
        // The engine read the note naming the tool, after the app's own words; Agneta's field didn't reach it.
        let blocks = try #require(await stack.engines.prompts.last)
        #expect(
            blocks.count == 2
                && blocks[1]["text"]?.stringValue?.contains(
                    "call the tool submit_result (from the agneta-result tools) once") == true
        )
        // The trace has the turn's result from asked to final.
        let events = try results(stack, session).map { $0["event"]?.stringValue }
        #expect(events == ["asked", "submitted", "final"])
    }

    @Test func anInvalidValueIsCorrectedWithinTheTurn() async throws {
        let stack = try await Stack.start(port: 47761)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Results")
        let session = try await stack.session(
            app, account: "brokered", meta: ["agneta/result": ["schema": Self.invoice]])
        let reply = try await prompt(
            app, session,
            Self.script([Self.call("submit_result", Self.bad), Self.call("submit_result", Self.good)]))
        #expect(reply["_meta"]?["agneta/result"]?["status"] == "valid")
        #expect(reply["_meta"]?["agneta/result"]?["attempts"] == 2)
        let answers = await stack.engines.resultAnswers
        let first = try #require(answers[0])
        #expect(first.isError && first.text.contains("- /total: expected a number, got a string"))
        #expect(first.text.contains("(2 attempts left)"))
        #expect(answers[1]?.isError == false)
    }

    @Test func outcomesWithoutAValidValue() async throws {
        let stack = try await Stack.start(port: 47762)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Results")
        let session = try await stack.session(
            app, account: "brokered", meta: ["agneta/result": ["schema": Self.invoice]])

        let silent = try await prompt(app, session, "hello")
        #expect(silent["_meta"]?["agneta/result"]?["status"] == "missing")
        #expect(silent["_meta"]?["agneta/result"]?["reason"] == "not-submitted")

        let refused = try await prompt(app, session, Self.script([], stopReason: "refusal"))
        #expect(refused["_meta"]?["agneta/result"]?["reason"] == "refused")

        let exhausted = try await prompt(
            app, session, Self.script([Self.call("submit_result", Self.bad)]), ["attempts": 1])
        let report = try #require(exhausted["_meta"]?["agneta/result"])
        #expect(report["status"] == "invalid" && report["value"] == Self.bad)
        #expect(
            report["issues"]?.arrayValue?.first?["path"] == "/total"
                && report["issues"]?.arrayValue?.first?["keyword"] == "type")
        #expect(await stack.engines.resultAnswers.last??.text.contains("that was the last attempt") == true)

        // Each turn starts fresh: the next one accepts.
        let fresh = try await prompt(app, session, Self.script([Self.call("submit_result", Self.good)]))
        #expect(fresh["_meta"]?["agneta/result"]?["status"] == "valid")
    }

    @Test func promptsAskByNameOptOutOrAskNothing() async throws {
        let stack = try await Stack.start(port: 47763)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Results")
        let session = try await stack.session(
            app, account: "brokered",
            meta: ["agneta/result": ["schemas": ["invoice": Self.invoice, "contact": Self.contact]]])

        // No "every": an ordinary turn has no result, and a call of a result tool is told nothing is asked.
        let plain = try await prompt(app, session, Self.script([Self.call("submit_contact", ["name": "Ada"])]))
        #expect(plain["_meta"]?["agneta/result"] == nil)
        #expect(await stack.engines.resultAnswers.last??.text == ResultWording.notAsked)
        #expect(await stack.engines.prompts.last?.count == 1) // no note without a result asked

        let named = try await prompt(
            app, session, Self.script([Self.call("submit_contact", ["name": "Ada"])]), ["name": "contact"])
        #expect(named["_meta"]?["agneta/result"]?["value"] == ["name": "Ada"])

        // The wrong tool is told which to call, and it counts as an attempt.
        let wrong = try await prompt(
            app, session,
            Self.script([Self.call("submit_contact", ["name": "Ada"]), Self.call("submit_invoice", Self.good)]),
            ["name": "invoice"])
        #expect(wrong["_meta"]?["agneta/result"]?["status"] == "valid")
        #expect(wrong["_meta"]?["agneta/result"]?["attempts"] == 2)
        #expect(await stack.engines.resultAnswers.dropLast().last??.text.contains("through submit_invoice") == true)

        let everySession = try await stack.session(
            app, account: "brokered",
            meta: ["agneta/result": ["schemas": ["invoice": Self.invoice], "every": "invoice"]])
        let optedOut = try await prompt(app, everySession, "hello", false)
        #expect(optedOut["_meta"]?["agneta/result"] == nil)
    }

    @Test func whatDoesntFitIsRefusedBeforeAnythingRuns() async throws {
        let stack = try await Stack.start(port: 47764)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Results")
        let before = await stack.engines.opened

        await #expect(throws: RPCError.self) {
            _ = try await stack.session(
                app, account: "brokered", meta: ["agneta/result": ["schema": ["type": "object", "nullable": true]]])
        }
        do {
            _ = try await stack.session(app, account: "brokered", meta: ["agneta/result": ["schemas": [:]]])
        } catch let error as RPCError {
            #expect(error.code == RPCError.invalidParams)
            #expect(error.data?["agneta"]?["unenforceable"] == ["agneta/result"])
        }
        #expect(await stack.engines.opened == before) // no engine started for a refused declaration

        // An app's server can't take the result server's name, whatever the engine.
        do {
            _ = try await app.request(
                "session/new",
                [
                    "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)),
                    "mcpServers": [
                        ["type": "http", "name": "agneta-result", "url": "http://127.0.0.1:1/mcp", "headers": []]
                    ],
                    "_meta": ["agneta/policy": ["tools": "app-only"], "agneta": ["account": "brokered"]]
                ])
            Issue.record("accepted a server named agneta-result")
        } catch let error as RPCError {
            #expect(error.data?["agneta"]?["unenforceable"] == ["mcpServers"])
        }

        // A prompt asking for something the session didn't declare is refused, and the engine never sees it.
        let session = try await stack.session(
            app, account: "brokered", meta: ["agneta/result": ["schema": Self.invoice]])
        let prompts = await stack.engines.prompts.count
        do {
            _ = try await prompt(app, session, "hello", ["name": "contact"])
            Issue.record("accepted an undeclared name")
        } catch let error as RPCError {
            #expect(error.code == RPCError.invalidParams && error.message.contains("wasn't declared"))
        }
        #expect(await stack.engines.prompts.count == prompts)
        // And the session still works.
        let reply = try await prompt(app, session, Self.script([Self.call("submit_result", Self.good)]))
        #expect(reply["_meta"]?["agneta/result"]?["status"] == "valid")
    }

    @Test func agnetaAllowsItsOwnToolAndTagsItsCalls() async throws {
        let stack = try await Stack.start(port: 47765)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Results")
        // The app asks for every permission, yet isn't asked about the result tool.
        let session = try await stack.session(
            app, account: "brokered", approval: "ask-app", meta: ["agneta/result": ["schema": Self.invoice]])
        let reply = try await prompt(app, session, Self.script([Self.call("submit_result", Self.good, ask: true)]))
        #expect(reply["_meta"]?["agneta/result"]?["status"] == "valid")
        #expect(await stack.engines.permissionAnswers["submit_result"]?["outcome"]?["optionId"] == "allow")
        #expect(app.permissionRequests == 0)
        let decision = try stack.records(session).first { $0["type"] == "permission" }
        #expect(decision?["decision"] == "allowed-by-agneta")
        // The app sees the call, tagged as the result's.
        let calls = app.updates(session).filter { $0["toolCallId"]?.stringValue?.hasPrefix("result-") == true }
        #expect(!calls.isEmpty)
        #expect(calls.allSatisfy { $0["_meta"]?["agneta"]?["result"]?["name"] == "result" })
        // The engine's own Goose metadata is kept beside Agneta's.
        #expect(calls.first?["_meta"]?["goose"] != nil)
    }

    @Test func aRouteEndsWithItsSessionAndResumingGetsANewOne() async throws {
        let stack = try await Stack.start(port: 47766)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Results")
        let session = try await stack.session(
            app, account: "brokered", tools: "read", meta: ["agneta/result": ["schema": Self.invoice]])
        let first = try #require(
            await stack.engines.opening.last?.params["mcpServers"]?.arrayValue?.first { $0["name"] == "agneta-result" })
        _ = try await app.request("session/close", ["sessionId": .string(session)])
        // The closed session's route reaches nothing.
        #expect(await FakeEngines.callResultTool(first, tool: "submit_result", arguments: Self.good) == nil)
        let server = try #require(await stack.router.resultServer)
        for _ in 0..<50 where await server.routeCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await server.routeCount == 0)

        // Resumed, it declares the same results (kept with the task) through a new route.
        let resumed = try await app.request(
            "session/load",
            [
                "sessionId": .string(session),
                "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)),
                "mcpServers": []
            ])
        // The reply carries the schemas, so a client resuming in a new process can rebuild them.
        #expect(resumed["_meta"]?["agneta"]?["results"]?["schemas"] == ["result": Self.invoice])
        #expect(resumed["_meta"]?["agneta"]?["results"]?["every"] == "result")
        let loaded = try #require(await stack.engines.opening.last)
        #expect(loaded.method == "session/load")
        let second = try #require(loaded.params["mcpServers"]?.arrayValue?.first { $0["name"] == "agneta-result" })
        #expect(second["url"] != first["url"])
        let reply = try await prompt(app, session, Self.script([Self.call("submit_result", Self.good)]))
        #expect(reply["_meta"]?["agneta/result"]?["status"] == "valid")
    }

    @Test func aTurnCutOffReportsNoValue() async throws {
        let stack = try await Stack.start(port: 47767)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Results")
        let session = try await stack.session(
            app, account: "brokered", meta: ["agneta/result": ["schema": Self.invoice]])
        async let reply = prompt(app, session, "deaf")
        try await Task.sleep(for: .milliseconds(300))
        await stack.router.stop(session)
        let ended = try await reply
        #expect(ended["stopReason"] == "cancelled")
        #expect(ended["_meta"]?["agneta/result"]?["status"] == "missing")
        #expect(ended["_meta"]?["agneta/result"]?["reason"] == "stopped")
    }

    @Test func sessionsWithoutResultsAreUntouched() async throws {
        let stack = try await Stack.start(port: 47768)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Results")
        let opened = try await app.request(
            "session/new",
            [
                "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                "_meta": [
                    "agneta/policy": ["tools": "app-only", "approval": "never-ask"], "agneta": ["account": "brokered"]
                ]
            ])
        let session = try #require(opened["sessionId"]?.stringValue)
        #expect(opened["_meta"]?["agneta"]?["appTools"]?["load"] == "engine")
        #expect(opened["_meta"]?["agneta"]?["results"] == nil)
        #expect(await stack.engines.opening.last?.params["mcpServers"] == [])
        let reply = try await prompt(app, session, "hello")
        #expect(reply["_meta"]?["agneta/result"] == nil)
        #expect(await stack.engines.prompts.last?.count == 1)
        #expect(try results(stack, session).isEmpty)
        #expect(await stack.router.resultServer == nil)
        // Asking for a result where none was declared is refused, not ignored.
        await #expect(throws: RPCError.self) { _ = try await prompt(app, session, "hello", ["name": "x"]) }
    }
}
