import Foundation
import Testing

@testable import AgnetaClient

@Suite @MainActor struct ReviewRegressionTests {
    @Test func overflowClosesBeforeAnySubsequentPromptCanRun() async throws {
        let host = StandIn(), client = try host.client { $0.buffers.turnBytes = 128 }
        defer { client.close() }
        _ = try await client.connect()
        let session = try await client.newSession()
        host.overrides = { method, message, socket in
            guard method == "session/prompt" else { return false }
            socket.update(
                session.id,
                [
                    "sessionUpdate": "agent_message_chunk",
                    "content": ["type": "text", "text": .string(String(repeating: "x", count: 256))]
                ])
            return true
        }
        let turn = try session.prompt("too much")
        await expectKind(.bufferOverflow) { try await turn.result }
        #expect(host.transport.closed); #expect(session.ended != nil)
        await expectKind(.bufferOverflow) { try await session.prompt("next").result }
        #expect(host.transport.calls("session/prompt").count == 1)
        #expect(host.transport.calls("session/cancel").isEmpty)
    }
    @Test func openingReplayHasAByteBudget() async throws {
        let host = StandIn(), client = try host.client { $0.buffers.earlyBytes = 128 }
        defer { client.close() }
        _ = try await client.connect()
        host.overrides = { method, _, socket in
            guard method == "session/new" else { return false }
            socket.update(
                "opening",
                [
                    "sessionUpdate": "agent_message_chunk",
                    "content": ["type": "text", "text": .string(String(repeating: "x", count: 256))]
                ])
            return true
        }
        await expectKind(.bufferOverflow) { try await client.newSession() }
        #expect(client.connection == nil); #expect(host.transport.closed)
    }
    @Test func zeroDownloadTimeoutWaitsUntilReady() async throws {
        let host = StandIn(),
            client = try host.client {
                $0.timeouts.download = 0; $0.timeouts.downloadPoll = 0.001
            }
        defer { client.close() }
        var retries = 0
        host.overrides = { method, message, socket in
            if method == "session/new", retries < 2 { retries += 1; socket.fail(message, code: -32015); return true }
            return false
        }
        _ = try await client.connect()
        _ = try await client.newSession()
        #expect(retries == 2)
    }
    @Test func manualConnectWaitsForCancelledReconnectCleanup() async throws {
        let first = StandIn(), reconnect = StandIn(), manual = StandIn()
        var reconnectStarted = false, attempts = 0
        reconnect.transport.startAction = {
            reconnectStarted = true; try await Task.sleep(for: .seconds(30))
        }
        var options = ClientOptions(name: "Example")
        options.reconnect = ReconnectOptions(delay: 0.001, maxDelay: 0.01)
        options.transport = { _ in
            attempts += 1
            switch attempts {
            case 1: return first.transport;
            case 2: return reconnect.transport;
            default: return manual.transport
            }
        }
        let client = try AgnetaClient(options: options)
        defer { client.close() }
        _ = try await client.connect()
        first.transport.close()
        try await eventually { reconnectStarted }
        _ = try await client.connect()
        #expect(client.state == .connected)
        #expect(manual.transport.calls("initialize").count == 1)
        #expect(reconnect.transport.closed)
    }
    @Test func excessiveNestingIsRejectedBeforeRecursiveDecode() async throws {
        let socket = ScriptedTransport(), connection = try await Connection.open(transport: socket)
        socket.feedText(String(repeating: "[", count: 1000) + "0" + String(repeating: "]", count: 1000))
        try await eventually { !connection.isOpen }
        #expect(connection.closeError?.kind == .protocolViolation)
        #expect(AgnetaError.rpc(code: -32013, message: "Paused", data: ["agneta": ["paused": "p1"]]).account == "p1")
    }
    @Test func installedOldVersionIsOutdatedWithoutOpening() async throws {
        let host = StandIn(), environment = FakeEnvironment()
        environment.state = .notRunning(version: "0.1.0", placement: .applications)
        host.transport.startAction = { throw AgnetaError(.notRunning, "not running") }
        let client = try host.client {
            $0.environment = environment; $0.minimumVersion = "0.8.0"
        }
        await expectKind(.outdated) { try await client.connect() }
        #expect(environment.openCount == 0)
        client.close()
    }
}
