import Foundation
import Testing

@testable import AgnetaClient

@Suite @MainActor struct ClientTests {
    @Test func pairingAndStoredAccess() async throws {
        let host = StandIn(), tokens = MemoryTokenStore()
        let client = try host.client(tokens: tokens)
        defer { client.close() }
        var codes: [String] = []
        _ = client.onEvent { if case .pairingCode(let code) = $0 { codes.append(code) } }
        async let first = client.connect()
        async let second = client.connect()
        let (a, b) = try await (first, second)
        #expect(a == b); #expect(codes == ["123456"])
        #expect(tokens.load() == "secret-token")
        #expect(client.state == .connected); #expect(client.remembered)
        #expect(host.transport.calls("agneta/pair").count == 1)
        #expect(host.transport.calls("initialize")[0]["params"]?["_meta"]?["agneta"]?["token"] == "secret-token")
        #expect(chooseProvider(client.access, sandbox: .contained)?.engineID == "goose")
        let removed = client.onEvent { _ in }
        removed(); removed()
        host.transport.notify("agneta/accessChanged", ["access": accessFixture])
        try await eventually { client.access != nil }
    }
    @Test func allowOnceAndRejectedTokens() async throws {
        let host = StandIn(), tokens = MemoryTokenStore("stale")
        host.remembered = false
        host.overrides = { method, message, socket in
            if method == "initialize", message["params"]?["_meta"]?["agneta"]?["token"] == "stale" {
                socket.fail(message, code: -32001); return true
            }; return false
        }
        let client = try host.client(tokens: tokens)
        defer { client.close() }
        _ = try await client.connect()
        #expect(tokens.load() == nil); #expect(!client.remembered)
        #expect(client.state == .connected)
    }
    @Test func quietConnectNeverPairs() async throws {
        let host = StandIn(), client = try host.client()
        defer { client.close() }
        await expectKind(.needsPairing) { try await client.connect(.init(pair: .never)) }
        #expect(host.transport.calls("agneta/pair").isEmpty)
        #expect(client.connection == nil)
    }
    @Test func closeWhileOpeningCannotAttachLate() async throws {
        let host = StandIn()
        host.transport.startAction = { try await Task.sleep(for: .seconds(30)) }
        let client = try host.client()
        let opening = Task { try await client.connect() }
        try await eventually { client.state == .connecting }
        client.close()
        do { _ = try await opening.value; Issue.record("Expected cancellation") } catch is CancellationError {}
        #expect(client.connection == nil); #expect(client.state == .disconnected); #expect(host.transport.closed)
    }
    @Test func cancellationOfPendingGuideIgnoresLateYes() async throws {
        let environment = FakeEnvironment()
        let host = StandIn()
        host.transport.startAction = { throw AgnetaError(.notRunning, "not running") }
        let client = try host.client { $0.environment = environment }
        var answer: CheckedContinuation<Bool, Never>?
        var options = ConnectOptions()
        options.guide = { _ in await withCheckedContinuation { answer = $0 } }
        let connecting = Task { try await client.connect(options) }
        try await eventually { answer != nil }
        connecting.cancel()
        do { _ = try await connecting.value; Issue.record("Expected cancellation") } catch is CancellationError {}
        answer?.resume(returning: true)
        await Task.yield()
        #expect(environment.openCount == 0); #expect(environment.installCount == 0)
        client.close()
    }
    @Test func setupAndMinimumVersion() async throws {
        let host = StandIn()
        host.catalog = ["providers": [], "engines": [], "connected": false, "version": "0.8.0"]
        host.overrides = { method, message, socket in
            if method == "agneta/setup" {
                host.catalog = catalogFixture
                socket.reply(message, result: ["shown": true]); return true
            }; return false
        }
        let client = try host.client { $0.minimumVersion = "0.7.0" }
        var connect = ConnectOptions(); connect.setup = true
        defer { client.close() }
        _ = try await client.connect(connect)
        #expect(host.transport.calls("agneta/setup").count == 1)
        #expect(client.state == .connected)
        #expect(compareVersions("0.8.0-beta", "0.7") == .orderedDescending)
        #expect(compareVersions("dev", "9") == .orderedSame)
        #expect(compareVersions("0.0.0", "9") == .orderedSame)
        #expect(compareVersions("garbage", "9") == nil)
    }
    @Test func unsupportedResultsFailBeforeOpeningSession() async throws {
        let host = StandIn(); host.extensions = ["agneta/access"]
        let client = try host.client(); _ = try await client.connect()
        defer { client.close() }
        var options = SessionOptions(); options.results = ResultDeclaration(schema: ["type": "object"])
        await expectKind(.unsupportedByAgneta) { try await client.newSession(options) }
        #expect(host.transport.calls("session/new").isEmpty)
    }
    @Test func disconnectEndsHandlesAndReconnectUsesRememberedTokenOnly() async throws {
        let first = StandIn(), second = StandIn()
        var connections = 0
        var options = ClientOptions(name: "Example")
        options.reconnect = .init(delay: 0.01, maxDelay: 0.02)
        options.transport = { _ in
            connections += 1; return connections == 1 ? first.transport : second.transport
        }
        let client = try AgnetaClient(options: options)
        defer { client.close() }
        _ = try await client.connect()
        let session = try await client.newSession()
        var reconnected = false
        _ = client.onEvent { if case .reconnected = $0 { reconnected = true } }
        first.transport.close()
        try await eventually { reconnected }
        #expect(session.ended != nil); #expect(client.sessions.isEmpty)
        #expect(second.transport.calls("agneta/pair").isEmpty)
        #expect(second.transport.calls("initialize").count == 1)
        await expectKind(.connectionClosed) { try await session.prompt("old").result }
    }
    @Test func closingInPairedCallbackNeverReopensDirectPair() async throws {
        let host = StandIn(), client = try host.client()
        _ = client.onEvent { if case .paired = $0 { client.close() } }
        do { _ = try await client.pair(); Issue.record("Expected cancellation") } catch is CancellationError {}
        #expect(client.connection == nil)
        #expect(host.transport.calls("initialize").isEmpty)
    }
    @Test func timeoutOrCancellationWhileOpeningClosesTheConnection() async throws {
        for method in ["session/new", "session/load", "agneta/fork"] {
            for cancelled in [false, true] {
                let host = StandIn(), client = try host.client()
                _ = try await client.connect()
                let source = try await client.newSession()
                host.overrides = { received, _, _ in received == method }
                var options = SessionOptions(); options.timeout = cancelled ? 0 : 0.01
                let task = Task { @MainActor [options] in
                    switch method {
                    case "session/load": return try await client.loadSession(source.id, options: options)
                    case "agneta/fork": return try await client.fork(source.id, options: options)
                    default: return try await client.newSession(options)
                    }
                }
                if cancelled {
                    let before = method == "session/new" ? 2 : 1
                    try await eventually { host.transport.calls(method).count == before }
                    task.cancel()
                    do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {}
                } else {
                    await expectKind(.timeout) { try await task.value }
                }
                #expect(host.transport.closed)
                #expect(client.sessions.isEmpty)
                #expect(source.ended != nil)
                client.close()
            }
        }
    }
    @Test func closingDuringLoadReplayDoesNotReturnAnOpenHandle() async throws {
        let host = StandIn(), client = try host.client()
        _ = try await client.connect()
        let original = try await client.newSession()
        var options = SessionOptions()
        options.onEvent = { if case .update = $0 { client.close() } }
        await expectKind(.connectionClosed) { try await client.loadSession(original.id, options: options) }
        #expect(client.connection == nil)
        #expect(client.sessions.isEmpty)
    }

}

@MainActor final class FakeEnvironment: AgnetaEnvironment {
    var state: AgnetaPresence = .notRunning(version: "0.8.0", placement: .applications)
    var openCount = 0, installCount = 0
    func lookup(_ build: AgnetaBuild) async -> AgnetaPresence { state }
    func open(_ build: AgnetaBuild) async -> Bool { openCount += 1; return true }
    func openInstallPage(_ build: AgnetaBuild) async -> Bool { installCount += 1; return true }
}
