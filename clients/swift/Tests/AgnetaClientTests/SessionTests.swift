import Foundation
import Testing

@testable import AgnetaClient

@Suite @MainActor struct SessionTests {
    @Test func streamsReplayAndMergesToolCalls() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        host.overrides = { method, message, socket in
            guard method == "session/prompt" else { return false }
            let id = message["params"]!["sessionId"]!.string!
            socket.notify("agneta/queued", ["sessionId": .string(id), "position": 2, "waitingFor": "app"])
            socket.update(id, ["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "in_progress"])
            socket.update(
                id, ["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Read", "rawInput": ["path": "x"]])
            socket.update(
                id, ["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed", "rawOutput": .null]
            )
            socket.update(id, ["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "Thinking"]])
            socket.update(id, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Hello"]])
            socket.update(id, ["sessionUpdate": "future_update", "future": 42])
            socket.reply(
                message,
                result: ["stopReason": "end_turn", "_meta": ["agneta/limit": ["limit": "maxTurns", "value": 2]]])
            return true
        }
        _ = try await client.connect()
        var options = SessionOptions()
        options.account = "p1"; options.engine = "goose"; options.instructions = "Help"; options.appTools = .always
        options.policy = Policy(
            tools: .workspace, sandbox: .contained, network: "none", approval: .neverAsk,
            readOnly: ["/tmp/workspace/fixed"], toolPorts: [5000], builtins: [.read])
        let session = try await client.newSession(options)
        let turn = try session.prompt("Hi")
        #expect(throws: AgnetaError.self) { try session.prompt("busy") }
        let result = try await turn.result
        #expect(result.text == "Hello"); #expect(result.thought == "Thinking")
        #expect(result.toolCalls.count == 1); #expect(result.toolCalls[0].status == "completed");
        #expect(result.toolCalls[0].title == "Read")
        #expect(result.limit?.limit == "maxTurns"); #expect(turn.done); #expect(session.turn == nil)
        var first: [TurnEvent] = [], second: [TurnEvent] = []
        for try await event in turn.events { first.append(event) }
        for try await event in turn.events { second.append(event) }
        #expect(first == second); #expect(first.count == 7)
        let params = host.transport.calls("session/new")[0]["params"]!
        #expect(params["_meta"]?["agneta/policy"]?["builtins"] == ["read"])
        #expect(params["_meta"]?["agneta/appTools"] == ["load": "always"])
        await expectKind(.noTurnRunning) { try await turn.steer("ended") }
    }
    @Test func cancelledTurnAndSteering() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        var pending: JSONValue?
        host.overrides = { method, message, socket in
            if method == "session/prompt" { pending = message; return true }
            if method == "session/cancel", let pending {
                socket.reply(pending, result: ["stopReason": "cancelled"]); return true
            }
            return false
        }
        _ = try await client.connect()
        let session = try await client.newSession(), turn = try session.prompt("wait")
        try await eventually { pending != nil }
        #expect(try await turn.steer("more")["delivery"] == "accepted")
        let waiting = Task { try await turn.result }
        waiting.cancel()
        #expect(try await waiting.value.cancelled)
        #expect(host.transport.calls("session/cancel").count == 1)
    }
    @Test func timeoutCancelsRemoteTurn() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        host.overrides = { method, _, _ in method == "session/prompt" }
        _ = try await client.connect()
        let session = try await client.newSession(), turn = try session.prompt("wait", options: .init(timeout: 0.01))
        await expectKind(.timeout) { try await turn.result }
        #expect(host.transport.calls("session/cancel").count == 1)
        #expect(client.connection?.isOpen == true)
    }
    @Test func loadedHistoryRetiresOldHandleAndEndedHandleCannotSendWork() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        _ = try await client.connect()
        let original = try await client.newSession()
        let loaded = try await client.loadSession(original.id)
        #expect(original.ended == .closed)
        #expect(loaded.history.first?.text == "history")
        #expect(loaded.resumed)
        await expectKind(.invalidParams) { try await original.setInstructions("do not send") }
        #expect(host.transport.calls("agneta/instructions/set").isEmpty)
        _ = try await loaded.prompt("new").result
        try await loaded.close()
        #expect(loaded.ended == .closed); #expect(client.sessions.isEmpty)
    }
    @Test func closeFailureKeepsHandleForRetryAndUnknownSessionReconciles() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        _ = try await client.connect()
        let session = try await client.newSession()
        host.overrides = { method, _, _ in method == "session/close" }
        await expectKind(.timeout) { try await session.close(options: .init(timeout: 0.01)) }
        #expect(session.ended == nil); #expect(client.session(id: session.id) === session)
        host.overrides = { method, message, socket in
            if method == "session/close" { socket.fail(message, code: -32602, message: "Unknown session"); return true };
            return false
        }
        try await session.close()
        #expect(session.ended == .closed)
    }
    @Test func permissionsDefaultDenyAndSessionOverride() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        _ = try await client.connect()
        var options = SessionOptions(); options.permissions = { _ in .allow }
        let session = try await client.newSession(options)
        let optionsJSON: JSONValue = [
            ["optionId": "yes", "name": "Allow", "kind": "allow_once"],
            ["optionId": "no", "name": "Reject", "kind": "reject_once"]
        ]
        for (id, sessionId) in [(20, "unknown"), (21, session.id)] {
            host.transport.feed([
                "jsonrpc": "2.0", "id": .integer(Int64(id)), "method": "session/request_permission",
                "params": ["sessionId": .string(sessionId), "toolCall": ["toolCallId": "t"], "options": optionsJSON]
            ])
        }
        try await eventually { host.transport.sent.filter { $0["result"]?["outcome"] != nil }.count == 2 }
        #expect(host.transport.sent.first { $0["id"] == 20 }?["result"]?["outcome"]?["optionId"] == "no")
        #expect(host.transport.sent.first { $0["id"] == 21 }?["result"]?["outcome"]?["optionId"] == "yes")
    }
    @Test func engineDownloadRetryAndStopDetails() async throws {
        let host = StandIn(), client = try host.client { $0.timeouts.downloadPoll = 0.001 }
        defer { client.close() }
        var downloads = 0
        host.overrides = { method, message, socket in
            if method == "session/new", downloads == 0 {
                downloads += 1
                socket.fail(
                    message, code: -32015,
                    data: ["agneta": ["engineDownloading": ["engine": "goose", "received": 10, "total": 20]]]);
                return true
            }
            if method == "session/prompt" {
                let id = message["params"]!["sessionId"]!
                socket.notify(
                    "agneta/sessionStopped", ["sessionId": id, "stoppedBy": "reach", "reason": "tool port vanished"])
                socket.reply(message, result: ["stopReason": "cancelled"]); return true
            }
            return false
        }
        _ = try await client.connect()
        var progress: [DownloadProgress] = [], options = SessionOptions()
        options.onDownloadProgress = { progress.append($0) }
        let session = try await client.newSession(options)
        #expect(progress.first?.received == 10)
        let result = try await session.prompt("go").result
        #expect(result.stoppedBy == "reach"); #expect(result.cancelled)
        #expect(session.ended == .stopped(by: "reach", detail: "tool port vanished"))
    }
    @Test func tracePagesMustAdvanceAndPreserveLargeIntegers() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        _ = try await client.connect()
        host.overrides = { method, message, socket in
            guard method == "agneta/trace/read" else { return false }
            let after = message["params"]?["after"]?.integer ?? 0
            if after == 0 {
                socket.reply(message, result: ["records": [], "next": 1, "complete": false])
            } else {
                socket.reply(
                    message,
                    result: [
                        "records": [["seq": 2, "type": "meta", "mono": 9_007_199_254_740_993]], "next": .null,
                        "complete": true
                    ])
            }
            return true
        }
        var records: [TraceRecord] = []
        for try await record in client.traceRecords("s1") { records.append(record) }
        #expect(records.count == 1); #expect(records[0].raw["mono"]?.integer == 9_007_199_254_740_993)
        host.overrides = { _, message, socket in
            socket.reply(message, result: ["records": [], "next": 0, "complete": false]); return true
        }
        await expectKind(.protocolViolation) {
            for try await _ in client.traceRecords("s1") {}
        }
    }
}
