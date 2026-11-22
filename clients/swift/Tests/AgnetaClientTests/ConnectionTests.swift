import Foundation
import Testing

@testable import AgnetaClient

@Suite @MainActor struct ConnectionTests {
    @Test func callsTimeoutCancellationAndLateReplies() async throws {
        let transport = ScriptedTransport()
        let connection = try await Connection.open(transport: transport)
        defer { connection.close() }
        transport.onSend = { message, transport in
            if message["method"] == "echo" { transport.reply(message, result: message["params"]!) }
        }
        let output = try await connection.request("echo", params: ["n": 9_007_199_254_740_993])
        #expect(output["n"]?.integer == 9_007_199_254_740_993)
        await expectKind(.timeout) { try await connection.request("hang", options: .init(timeout: 0.01)) }
        let late = transport.calls("hang")[0]
        transport.reply(late, result: "late")
        #expect(try await connection.request("echo", params: .null) == .null)
        let pending = Task { try await connection.request("cancel", options: .init(timeout: 0)) }
        try await eventually { transport.calls("cancel").count == 1 }
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Expected cancellation") } catch is CancellationError {}
        #expect(connection.isOpen)
        let closing = Task { try await connection.request("closing") }
        try await eventually { transport.calls("closing").count == 1 }
        connection.close()
        await expectKind(.connectionClosed) { try await closing.value }
    }
    @Test func outOfOrderResponsesRemainCorrelated() async throws {
        let socket = ScriptedTransport(), connection = try await Connection.open(transport: socket)
        defer { connection.close() }
        let first = Task { try await connection.request("first") },
            second = Task { try await connection.request("second") }
        try await eventually { socket.sent.count == 2 }
        socket.reply(socket.calls("second")[0], result: 2)
        socket.reply(socket.calls("first")[0], result: 1)
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
    }
    @Test func malformedRepliesAndInvalidJSON() async throws {
        let socket = ScriptedTransport(), connection = try await Connection.open(transport: socket)
        socket.onSend = { message, socket in
            socket.feed(["jsonrpc": "2.0", "id": message["id"]!, "result": 1, "error": .null])
        }
        await expectKind(.protocolViolation) { try await connection.request("bad") }
        #expect(connection.isOpen)
        socket.feedText("not JSON")
        try await eventually { !connection.isOpen }
        #expect(connection.closeError?.kind == .protocolViolation)
    }
    @Test func redactionAndServerRequests() async throws {
        let socket = ScriptedTransport(), connection = try await Connection.open(transport: socket)
        defer { connection.close() }
        var log: [JSONValue] = []
        _ = connection.onEvent { if case .message(let message, _) = $0 { log.append(message) } }
        socket.onSend = { message, socket in
            if message["method"] != nil { socket.reply(message, result: ["token": "pair-secret"]) }
        }
        #expect(
            try await connection.request("initialize", params: ["_meta": ["agneta": ["token": "auth-secret"]]])["token"]
                == "pair-secret")
        let text = String(decoding: try JSONEncoder().encode(log), as: UTF8.self)
        #expect(!text.contains("auth-secret")); #expect(!text.contains("pair-secret"));
        #expect(text.contains("[redacted]"))
        let old = connection.handle("custom") { _ in "old" }
        _ = connection.handle("custom") { params in params }
        old()
        socket.feed(["jsonrpc": "2.0", "id": 19, "method": "custom", "params": ["answer": 42]])
        try await eventually { socket.sent.contains { $0["id"] == 19 } }
        #expect(socket.sent.last?["result"] == ["answer": 42])
        socket.feed(["jsonrpc": "2.0", "id": "unsupported", "method": "fs/read_text_file"])
        try await eventually { socket.sent.contains { $0["id"] == "unsupported" } }
        #expect(socket.sent.last?["error"]?["code"] == -32601)
    }
    @Test func failedOpenIsClosedAndPrecancelledOpenDoesNotStart() async throws {
        let socket = ScriptedTransport()
        socket.startAction = { try await Task.sleep(for: .seconds(30)) }
        await expectKind(.timeout) { try await Connection.open(connectTimeout: 0.01, transport: socket) }
        #expect(socket.closed)
        let other = ScriptedTransport()
        let task = Task { try await Connection.open(transport: other) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {}
        #expect(!other.started)
    }
    @Test func releasingConnectionClosesTransport() async throws {
        let socket = ScriptedTransport()
        var connection: Connection? = try await Connection.open(transport: socket)
        let released = { [weak connection] in connection == nil }
        connection = nil
        try await eventually { released() && socket.closed }
    }
    @Test func errorCodesAndStructuredData() {
        let codes: [(Int, AgnetaError.Kind)] = [
            (-32001, .needsPairing), (-32002, .notAllowed), (-32010, .noTurnRunning), (-32011, .turnBusy),
            (-32012, .queueFull), (-32013, .paused), (-32014, .unsupportedByEngine), (-32015, .engineDownloading),
            (-32016, .appLimit), (-32601, .methodNotFound), (-32602, .invalidParams), (-32603, .internalError),
            (-32000, .rpc)
        ]
        for (code, kind) in codes { #expect(AgnetaError.rpc(code: code, message: "error").kind == kind) }
        #expect(
            AgnetaError.rpc(code: -32000, message: "login", data: ["agneta": ["needsSignIn": "p1"]]).account == "p1")
        #expect(
            AgnetaError.rpc(code: -32000, message: "limit", data: ["agneta": ["rateLimited": ["account": "p1"]]]).kind
                == .rateLimited)
        #expect(
            AgnetaError.rpc(code: -32602, message: "state", data: ["agneta": ["stateChanged": ["engine": "goose"]]])
                .kind == .stateChanged)
    }
}
