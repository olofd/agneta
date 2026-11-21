// Structured results in the router at its edges: deep values, limits, failures, parallel calls, queued prompts, forks
// and failed opens (first written by the independent review of the router's integration).
import Foundation
import Testing

@testable import AgnetaKit

@Suite(.serialized) struct ResultRouterEdgeTests {
    typealias Stack = RouterContractTests.Stack
    typealias C = ResultContractTests

    func prompt(_ app: AppClient, _ session: String, _ text: String, _ result: JSONValue? = nil) async throws
        -> JSONValue
    {
        var params: JSONValue = ["sessionId": .string(session), "prompt": [["type": "text", "text": .string(text)]]]
        if let result { params = params.setting("_meta", to: ["agneta/result": result]) }
        return try await app.request("session/prompt", params)
    }

    static func script(_ calls: [JSONValue], then: String? = nil) -> String {
        var json: JSONValue = ["calls": .array(calls), "stopReason": "end_turn"]
        if let then { json = json.setting("then", to: .string(then)) }
        return "result " + String(decoding: (try? JSONCoding.encode(json)) ?? Data(), as: UTF8.self)
    }

    static func nested(_ depth: Int) -> JSONValue {
        var value: JSONValue = 1
        for _ in 0..<depth { value = ["a": value] }
        return value
    }

    /// A refused value nested 125 deep fits every frame on the way in, but the reply that reports it nests 129 deep.
    @Test func aDeepRefusedValueStillReachesTheApp() async throws {
        let stack = try await Stack.start(port: 47800)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Review")
        let session = try await stack.session(
            app, account: "brokered", meta: ["agneta/result": ["schema": ["type": "object"]]])
        let value = Self.nested(125)
        do {
            let reply = try await prompt(
                app, session, Self.script([C.call("submit_result", value)]), ["attempts": 1])
            #expect(reply["_meta"]?["agneta/result"]?["status"] == "invalid")
        } catch {
            Issue.record("the prompt's reply never reached the app: \(error)")
        }
        // One level shallower, the reply nests exactly 128 deep and arrives.
        let app2 = AppClient(port: stack.port)
        defer { app2.close() }
        try await app2.pairAndInitialize("Review2")
        let s2 = try await stack.session(
            app2, account: "brokered", meta: ["agneta/result": ["schema": ["type": "object"]]])
        let ok = try await prompt(app2, s2, Self.script([C.call("submit_result", Self.nested(124))]), ["attempts": 1])
        #expect(ok["_meta"]?["agneta/result"]?["status"] == "invalid")
    }

    /// A limit that ends the session still reports the value accepted before it.
    @Test func aLimitStopReportsTheAcceptedValue() async throws {
        let stack = try await Stack.start(port: 47801, concurrency: .init(limitGrace: .milliseconds(300)))
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Review")
        let created = try await app.request(
            "session/new",
            [
                "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                "_meta": [
                    SessionPolicy.key: ["tools": "app-only", "approval": "never-ask", "limits": ["maxSeconds": 1]],
                    "agneta": ["account": "brokered"], "agneta/result": ["schema": C.invoice]
                ]
            ])
        let session = try #require(created["sessionId"]?.stringValue)
        let reply = try await prompt(app, session, Self.script([C.call("submit_result", C.good)], then: "deaf"))
        #expect(reply["_meta"]?["agneta/limit"]?["sessionEnded"] == true)
        #expect(reply["_meta"]?["agneta/result"]?["status"] == "valid")
        #expect(reply["_meta"]?["agneta/result"]?["value"] == C.good)
        #expect(await stack.router.resultTurns.isEmpty)
        #expect(await stack.router.resultRoutes.isEmpty)

        // The engine stops in time (after Agneta's cancel): still valid, stopped by the limit.
        let second = try await app.request(
            "session/new",
            [
                "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                "_meta": [
                    SessionPolicy.key: ["tools": "app-only", "approval": "never-ask", "limits": ["maxSeconds": 1]],
                    "agneta": ["account": "brokered"], "agneta/result": ["schema": C.invoice]
                ]
            ])
        let id = try #require(second["sessionId"]?.stringValue)
        let stopped = try await prompt(app, id, Self.script([C.call("submit_result", C.bad)], then: "wait"))
        #expect(stopped["_meta"]?["agneta/result"]?["status"] == "missing")
        #expect(stopped["_meta"]?["agneta/result"]?["reason"] == "stopped")
        #expect(stopped["_meta"]?["agneta/result"]?["value"] == C.bad)
    }

    /// A prompt that fails with an error leaves no result state, and the next turn works.
    @Test func aFailedPromptLeavesNoResult() async throws {
        let stack = try await Stack.start(port: 47802)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Review")
        let session = try await stack.session(
            app, account: "brokered", meta: ["agneta/result": ["schema": C.invoice]])
        await #expect(throws: RPCError.self) {
            _ = try await prompt(app, session, Self.script([C.call("submit_result", C.good)], then: "error"))
        }
        #expect(await stack.router.resultTurns.isEmpty)
        // A late call after the failed turn is told nothing is asked.
        let server = try #require(
            await stack.engines.opening.last?.params["mcpServers"]?.arrayValue?.first { $0["name"] == "agneta-result" })
        let late = await FakeEngines.callResultTool(server, tool: "submit_result", arguments: C.good)
        #expect(late?.text == ResultWording.notAsked)
        let next = try await prompt(app, session, Self.script([C.call("submit_result", C.good)]))
        #expect(next["_meta"]?["agneta/result"]?["status"] == "valid")
    }

    /// Calls arriving together: exactly one is accepted, and the reply carries that one.
    @Test func parallelCallsAcceptExactlyOne() async throws {
        let stack = try await Stack.start(port: 47803)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Review")
        let session = try await stack.session(
            app, account: "brokered", meta: ["agneta/result": ["schema": C.invoice]])
        let server = try #require(
            await stack.engines.opening.last?.params["mcpServers"]?.arrayValue?.first { $0["name"] == "agneta-result" })
        async let reply = prompt(app, session, Self.script([], then: "wait"), ["attempts": 10])
        try await Task.sleep(for: .milliseconds(400))
        let values: [JSONValue] = (0..<12).map { i in
            i % 2 == 0 ? ["number": .string("N\(i)"), "total": .int(Int64(i))] : ["number": 1, "total": "x"]
        }
        let answers = await withTaskGroup(of: (Int, (text: String, isError: Bool)?).self) { group in
            for (i, value) in values.enumerated() {
                group.addTask { (i, await FakeEngines.callResultTool(server, tool: "submit_result", arguments: value)) }
            }
            var all: [(Int, (text: String, isError: Bool)?)] = []
            for await answer in group { all.append(answer) }
            return all
        }
        let accepted = answers.filter { $0.1?.isError == false }
        #expect(accepted.count == 1)
        let report = try await reply
        #expect(report["_meta"]?["agneta/result"]?["status"] == "valid")
        if let winner = accepted.first {
            #expect(report["_meta"]?["agneta/result"]?["value"] == values[winner.0])
        }
    }

    /// A prompt that asked for a result and was cancelled while queued: does its reply say what became of the result?
    @Test func aQueuedPromptCancelledReportsItsResult() async throws {
        let stack = try await Stack.start(port: 47806, concurrency: .init(global: 2, perAccount: 1, queue: 1))
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Review")
        let busy = try await stack.session(app, account: "brokered")
        let asking = try await stack.session(
            app, account: "brokered", meta: ["agneta/result": ["schema": C.invoice]])
        async let first = app.prompt(busy, "slow")
        try await Task.sleep(for: .milliseconds(200))
        async let second = prompt(app, asking, "hello")
        try await Task.sleep(for: .milliseconds(200))
        app.notify("session/cancel", ["sessionId": .string(asking)])
        let cancelled = try await second
        #expect(cancelled["stopReason"] == "cancelled")
        #expect(cancelled["sessionId"] == .string(asking), "\(cancelled)")
        #expect(cancelled["_meta"]?["agneta/result"]?["status"] == "missing", "\(cancelled)")
        _ = try await first
    }

    /// A permission request naming agneta-result on a session that declared nothing goes the ordinary way.
    @Test func aSessionWithoutResultsIsntAllowedTheResultTool() async throws {
        let stack = try await Stack.start(port: 47804)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Review")
        app.answerPermissions(with: "reject")
        let session = try await stack.session(app, account: "brokered", approval: "ask-app")
        let goose: JSONValue = [
            "goose": ["toolCall": ["extensionName": "agneta-result", "toolName": "agneta-result__submit_result"]]
        ]
        let spec: JSONValue = [
            "announce": [
                "sessionUpdate": "tool_call", "toolCallId": "c1", "title": "x", "kind": "other", "status": "pending",
                "_meta": goose
            ],
            "toolCall": ["toolCallId": "c1", "kind": "other", "title": "x", "_meta": goose]
        ]
        let text = "ask probe " + String(decoding: try JSONCoding.encode(spec), as: UTF8.self)
        _ = try await app.prompt(session, text)
        #expect(app.permissionRequests == 1)
        #expect(await stack.engines.permissionAnswers["probe"]?["outcome"]?["optionId"] == "reject")
        #expect(app.updates(session).allSatisfy { $0["_meta"]?["agneta"]?["result"] == nil })
    }

    /// A fork keeps the declaration and gets a route of its own; a fork or load that fails drops its route.
    @Test func forksAndFailedOpensAndTheirRoutes() async throws {
        let stack = try await Stack.start(port: 47805)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Review")
        await stack.engines.exporting(true)
        let source = try await stack.session(
            app, account: "brokered", tools: "read", meta: ["agneta/result": ["schema": C.invoice]])
        _ = try await app.request("session/close", ["sessionId": .string(source)])
        let forked = try await app.request("agneta/fork", ["sessionId": .string(source), "mcpServers": []])
        let fork = try #require(forked["sessionId"]?.stringValue)
        #expect(forked["_meta"]?["agneta"]?["results"]?["declared"] == ["result"])
        let servers = try #require(await stack.engines.opening.last?.params["mcpServers"]?.arrayValue)
        #expect(servers.contains { $0["name"] == "agneta-result" })
        let reply = try await prompt(app, fork, Self.script([C.call("submit_result", C.good)]))
        #expect(reply["_meta"]?["agneta/result"]?["status"] == "valid")
        #expect(await stack.router.resultRoutes.keys.sorted() == [fork])

        // Opens that fail after their route was made (paused while the engine answers).
        await stack.engines.beforeOpeningReply { [weak router = stack.router] in
            await router?.setPaused("brokered", true)
        }
        for method in ["agneta/fork", "session/load"] {
            await stack.router.setPaused("brokered", false)
            await #expect(throws: RPCError.self) {
                _ = try await app.request(
                    method,
                    [
                        "sessionId": .string(source), "mcpServers": [],
                        "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false))
                    ])
            }
            #expect(await stack.router.resultRoutes.keys.sorted() == [fork], "\(method)")
        }
        let server = try #require(await stack.router.resultServer)
        for _ in 0..<50 where await server.routeCount > 1 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await server.routeCount == 1)
    }
}

extension ResultRouterEdgeTests {
    @Test func namesThatWouldPassForTheResultServerAreRefused() {
        for name in ["agneta-result", "agneta_result", "Agneta-Result", "agneta-result__x", "agneta-result_x"] {
            #expect(ResultServer.isReserved(name), "\(name)")
        }
        for name in ["agneta", "results", "app", "my-agneta-result"] {
            #expect(!ResultServer.isReserved(name), "\(name)")
        }
    }

    @Test func anAcceptedValueSurvivesAnEngineError() async throws {
        let stack = try await Stack.start(port: 47807)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Review")
        let session = try await stack.session(app, account: "brokered", meta: ["agneta/result": ["schema": C.invoice]])
        do {
            _ = try await prompt(app, session, Self.script([C.call("submit_result", C.good)], then: "error"))
            Issue.record("the engine's error didn't come back")
        } catch let error as RPCError {
            #expect(error.message == "boom")
            #expect(error.data?["agneta/result"]?["status"] == "valid")
            #expect(error.data?["agneta/result"]?["value"] == C.good)
        }
    }

    @Test func agnetasFieldNeverReachesTheEngine() async throws {
        let stack = try await Stack.start(port: 47808)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Review")
        let session = try await stack.session(
            app, account: "brokered", meta: ["agneta/result": ["schemas": ["invoice": C.invoice], "every": "invoice"]])
        _ = try await prompt(app, session, "hello", false)
        let sent = await stack.engines.lastPromptParams
        #expect(sent?["_meta"]?["agneta/result"] == nil)
    }
}

@Suite struct DeepFrameTests {
    @Test func theTopLevelIdAndMethodAreReadWithoutDecoding() {
        let deep = String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000)
        let request = #"{"jsonrpc":"2.0","params":"# + deep + #","id":42,"method":"x/y"}"#
        let top = JSONCoding.topLevel(of: Data(request.utf8))
        #expect(top?.id == 42 && top?.method == "x/y")
        let reply = #"{"id":"a\"b","result":{"deep":"# + deep + "}}"
        #expect(JSONCoding.topLevel(of: Data(reply.utf8))?.id == .string("a\"b"))
        #expect(JSONCoding.topLevel(of: Data("[1]".utf8)) == nil)
    }

    /// A request nested too deep to decode is answered with an error, not dropped: whoever sent it isn't left waiting.
    @Test func aRequestTooDeepToReadIsAnswered() async throws {
        let (a, b) = peerPair()
        await b.handle(requests: { _, _ in .success("unreachable") })
        var params: JSONValue = 1
        for _ in 0..<(JSONCoding.maxDepth + 5) { params = [params] }
        do {
            _ = try await a.request("x/y", params)
            Issue.record("answered as if it had been read")
        } catch let error as RPCError {
            #expect(error.code == RPCError.invalidRequest)
            #expect(error.message.contains("nested more than"))
        }
    }

    /// A reply nested too deep to read fails the request it answers, rather than leaving it waiting for ever.
    @Test func aReplyTooDeepToReadFailsItsRequest() async throws {
        let (a, b) = peerPair()
        var deep: JSONValue = 1
        for _ in 0..<(JSONCoding.maxDepth + 5) { deep = [deep] }
        let answer = deep
        await b.handle(requests: { _, _ in .success(answer) })
        await #expect(throws: RPCError.self) { _ = try await a.request("x/y", [:]) }
    }
}
