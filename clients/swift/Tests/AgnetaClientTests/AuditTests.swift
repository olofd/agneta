import Foundation
import Testing

@testable import AgnetaClient

@Suite @MainActor struct AuditTests {
    @Test func immediateCancelFollowsItsPrompt() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        _ = try await client.connect()
        let session = try await client.newSession()
        var prompt: JSONValue?
        host.overrides = { method, message, socket in
            if method == "session/prompt" { prompt = message; return true }
            if method == "session/cancel" {
                if let prompt { socket.reply(prompt, result: ["stopReason": "cancelled"]) }
                return true
            }
            return false
        }
        let turn = try session.prompt("Start and stop", options: .init(timeout: 2))
        try await turn.cancel()
        #expect(try await turn.result.cancelled)
        let methods = host.transport.sent.compactMap { $0["method"]?.string }
            .filter { $0 == "session/prompt" || $0 == "session/cancel" }
        #expect(methods.first == "session/prompt")
    }
    @Test func immediateSteerFollowsItsPrompt() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        _ = try await client.connect()
        let session = try await client.newSession()
        var prompt: JSONValue?
        host.overrides = { method, message, socket in
            if method == "session/prompt" { prompt = message; return true }
            if method == "agneta/steer" {
                if prompt == nil {
                    socket.fail(message, code: -32010)
                } else {
                    socket.reply(message, result: ["delivery": "accepted", "runId": .null])
                }
                return true
            }
            return false
        }
        let turn = try session.prompt("Start", options: .init(timeout: 2))
        #expect(try await turn.steer("More")["delivery"] == "accepted")
        if let prompt { host.transport.reply(prompt, result: ["stopReason": "end_turn"]) }
        _ = try await turn.result
    }
    @Test func outboundFramesCannotOvertakeASuspendedSend() async throws {
        let socket = ScriptedTransport(), connection = try await Connection.open(transport: socket)
        defer { connection.close() }
        var release: CheckedContinuation<Void, Never>?
        socket.onSend = { message, socket in
            if message["method"] == "first" {
                await withCheckedContinuation { release = $0 }
                socket.reply(message, result: "done")
            }
        }
        let first = Task { try await connection.request("first") }
        try await eventually { release != nil }
        let second = Task { try await connection.notify("second") }
        for _ in 0..<10 { await Task.yield() }
        #expect(socket.calls("second").isEmpty)
        release?.resume()
        #expect(try await first.value == "done")
        try await second.value
    }
    @Test func resultWaitCancellationCannotStopAFutureTurn() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        _ = try await client.connect()
        let session = try await client.newSession()
        let old = try session.prompt("Done")
        _ = try await old.result
        let current = try session.prompt("Current")
        let waiting = Task { try await old.result }
        waiting.cancel()
        _ = try await waiting.value
        _ = try await current.result
        #expect(host.transport.calls("session/cancel").isEmpty)
    }
    @Test func closeFromConnectedProgressDoesNotReturnSuccess() async throws {
        let host = StandIn(), client = try host.client()
        var connect = ConnectOptions()
        connect.onProgress = { if $0.step == .connected { client.close() } }
        do {
            _ = try await client.connect(connect); Issue.record("Returned successful access after close")
        } catch is CancellationError {}
        #expect(client.connection == nil)
    }
    @Test func closeFromConnectedStateDoesNotReturnSuccessfulInitialize() async throws {
        let host = StandIn(), client = try host.client()
        _ = client.onEvent { if case .state(.connected) = $0 { client.close() } }
        do {
            _ = try await client.initialize(token: "secret-token"); Issue.record("Initialized a closed connection")
        } catch is CancellationError {}
        #expect(client.connection == nil)
        #expect(!client.remembered)
    }
    @Test func lateNotificationsForEndedSessionsDoNotFillOpeningBuffers() async throws {
        let host = StandIn(), client = try host.client { $0.buffers.earlySessions = 2 }
        defer { client.close() }
        _ = try await client.connect()
        for index in 0..<4 {
            host.transport.update(
                "ended-\(index)", ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "late"]])
        }
        host.transport.notify("marker", [:])
        for _ in 0..<10 { await Task.yield() }
        #expect(client.connection?.isOpen == true)
    }
    @Test func progressIncludesPairingAndItsCode() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        var events: [ConnectProgress] = []
        var options = ConnectOptions(); options.onProgress = { events.append($0) }
        _ = try await client.connect(options)
        #expect(events.contains { $0.step == .connecting })
        #expect(events.contains { $0.step == .pairing && $0.code == "123456" })
        #expect(events.last?.step == .connected)
    }
    @Test func aRejectedOneShotClosePreservesTheAnswerAndStopsItsConnection() async throws {
        let host = StandIn(), client = try host.client()
        _ = try await client.connect()
        host.overrides = { method, message, socket in
            if method == "session/prompt" {
                socket.reply(
                    message,
                    result: [
                        "stopReason": "end_turn",
                        "_meta": [
                            resultExtension: [
                                "status": "valid", "name": "result", "mechanism": "tool", "attempts": 1,
                                "value": ["name": "Ada"]
                            ]
                        ]
                    ])
                return true
            }
            if method == "session/close" { socket.fail(message, code: -32603); return true }
            return false
        }
        let result = try await client.ask("Return it", schema: ["type": "object"], as: JSONValue.self)
        #expect(result.value == ["name": "Ada"])
        #expect(client.sessions.isEmpty)
        #expect(client.connection == nil)
        #expect(host.transport.closed)
    }
    @Test func invalidWaitDeadlineIsAnError() async throws {
        let host = StandIn(), client = try host.client()
        await expectKind(.invalidParams) { try await client.waitForAgneta(timeout: .nan) }
        #expect(!host.transport.started)
        client.close()
    }

    @Test func expiredQueuedRequestsAreNeverSentLater() async throws {
        let socket = ScriptedTransport(), connection = try await Connection.open(transport: socket)
        defer { connection.close() }
        var release: CheckedContinuation<Void, Never>?
        socket.onSend = { message, socket in
            if message["method"] == "head" {
                await withCheckedContinuation { release = $0 }
                socket.reply(message, result: "sent")
            }
        }
        let head = Task { try await connection.request("head") }
        try await eventually { release != nil }
        await expectKind(.timeout) { try await connection.request("expired", options: .init(timeout: 0.01)) }
        release?.resume()
        _ = try await head.value
        try await connection.notify("tail")
        #expect(socket.calls("expired").isEmpty)
        #expect(socket.calls("tail").count == 1)
    }
    @Test func cancellingAQueuedNotificationDoesNotSendOrCloseTheConnection() async throws {
        let socket = ScriptedTransport(), connection = try await Connection.open(transport: socket)
        defer { connection.close() }
        var release: CheckedContinuation<Void, Never>?
        socket.onSend = { message, socket in
            if message["method"] == "head" {
                await withCheckedContinuation { release = $0 }
                socket.reply(message, result: "sent")
            }
        }
        let head = Task { try await connection.request("head") }
        try await eventually { release != nil }
        let notification = Task { try await connection.notify("cancelled") }
        await Task.yield(); notification.cancel()
        do { try await notification.value; Issue.record("Expected cancellation") } catch is CancellationError {}
        release?.resume(); _ = try await head.value
        try await connection.notify("tail")
        #expect(socket.calls("cancelled").isEmpty)
        #expect(connection.isOpen)
    }
    @Test func aStuckWriterFailsEvenWhenTheRPCDeadlineIsDisabled() async throws {
        let socket = ScriptedTransport(),
            connection = try await Connection.open(requestTimeout: 0.01, transport: socket)
        socket.onSend = { _, _ in try await Task.sleep(for: .seconds(30)) }
        await expectKind(.connectionClosed) { try await connection.request("blocked", options: .init(timeout: 0)) }
        #expect(!connection.isOpen)
        #expect(socket.closed)
    }
    @Test func immediateCloseIsOrderedAfterPromptAndCancelsIt() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        _ = try await client.connect()
        let session = try await client.newSession()
        var prompt: JSONValue?
        host.overrides = { method, message, socket in
            if method == "session/prompt" { prompt = message; return true }
            if method == "session/close" {
                if let prompt { socket.reply(prompt, result: ["stopReason": "cancelled"]) }
                socket.reply(message, result: [:]); return true
            }
            return false
        }
        let turn = try session.prompt("Close immediately", options: .init(timeout: 2))
        try await session.close()
        #expect(try await turn.result.cancelled)
        #expect(session.ended == .closed)
    }

    @Test func failedLoadDiscardsReplayButRetainsAStop() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        _ = try await client.connect()
        let old = try await client.newSession()
        var updates = 0
        _ = old.onEvent { if case .update = $0 { updates += 1 } }
        host.overrides = { method, message, socket in
            guard method == "session/load" else { return false }
            socket.update(
                old.id, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Failed replay"]])
            socket.notify(
                "agneta/sessionStopped",
                ["sessionId": .string(old.id), "stoppedBy": "reach", "reason": "server stopped"])
            socket.fail(message, code: -32603); return true
        }
        await expectKind(.internalError) { try await client.loadSession(old.id) }
        #expect(old.ended == .stopped(by: "reach", detail: "server stopped"))
        #expect(client.session(id: old.id) == nil)
        #expect(updates == 0)
    }
    @Test func loadingARunningTurnCannotStealItsUpdates() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        _ = try await client.connect()
        let session = try await client.newSession()
        var prompt: JSONValue?
        host.overrides = { method, message, _ in
            if method == "session/prompt" { prompt = message; return true }; return false
        }
        let turn = try session.prompt("Running")
        await expectKind(.turnBusy) { try await client.loadSession(session.id) }
        try await eventually { prompt != nil }
        host.transport.update(
            session.id, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Still here"]])
        host.transport.reply(prompt!, result: ["stopReason": "end_turn"])
        #expect(try await turn.result.text == "Still here")
        #expect(host.transport.calls("session/load").isEmpty)
    }

    @Test func nonJSONHandlerResultFailsTheRemoteCallInsteadOfHangingIt() async throws {
        let socket = ScriptedTransport(), connection = try await Connection.open(transport: socket)
        defer { connection.close() }
        _ = connection.handle("invalid") { _ in .number(.nan) }
        socket.feed(["jsonrpc": "2.0", "id": "remote", "method": "invalid", "params": [:]])
        try await eventually { socket.sent.contains { $0["id"] == "remote" } }
        #expect(socket.sent.last?["error"]?["code"] == -32603)
        #expect(connection.isOpen)
    }

}
