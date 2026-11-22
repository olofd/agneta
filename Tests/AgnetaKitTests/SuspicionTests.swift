// The review's suspicions, each settled by a test (docs: "Suspicions to measure"): kept as regression tests.
import Darwin
import Foundation
import Testing

@testable import AgnetaKit

/// A WebSocket client on a plain socket, so a test can make it stop reading for real: what it doesn't read stays in
/// the kernel's buffers, which fill, as with an app that hangs.
final class RawWebSocket {
    private let fd: Int32
    private var buffer = Data()

    init(port: UInt16) throws {
        fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var small: Int32 = 4096 // a small receive buffer fills sooner
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: 10, tv_usec: 0) // a read that waits longer fails, rather than hang the test
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        // Agneta may disconnect this client (that's what some of these tests check): a write after that is an error,
        // not a SIGPIPE ending the whole test run.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        try write(
            Data(
                "GET /acp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
                    .utf8))
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil { try fill() }
        let end = buffer.range(of: Data("\r\n\r\n".utf8))!
        guard String(decoding: buffer[..<end.lowerBound], as: UTF8.self).contains(" 101 ") else {
            throw POSIXError(.EPROTO)
        }
        buffer.removeSubrange(..<end.upperBound)
    }

    deinit { close(fd) }

    private func write(_ data: Data) throws {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, data.count - sent, 0) }
            guard n > 0 else { throw POSIXError(.EPIPE) }
            sent += n
        }
    }

    private func fill() throws {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &chunk, chunk.count, 0)
        guard n > 0 else { throw POSIXError(.ECONNRESET) }
        buffer.append(contentsOf: chunk[0..<n])
    }

    private func take(_ count: Int) throws -> Data {
        while buffer.count < count { try fill() }
        let out = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return out
    }

    /// Sends one text frame (masked, as clients must).
    func send(_ value: JSONValue) throws {
        let payload = try JSONCoding.encode(value)
        var frame = Data([0x81])
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count < 65536 {
            frame.append(0x80 | 126); frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        } else {
            frame.append(0x80 | 127);
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xff) })
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try write(frame)
    }

    /// The next text frame.
    func receive() throws -> JSONValue {
        while true {
            let header = try take(2)
            var length = Int(header[1] & 0x7f)
            if length == 126 {
                length = try take(2).reduce(0) { $0 << 8 | Int($1) }
            } else if length == 127 {
                length = try take(8).reduce(0) { $0 << 8 | Int($1) }
            }
            let payload = try take(length)
            switch header[0] & 0x0f {
            case 0x1: return try JSONCoding.decode(payload)
            case 0x8: throw POSIXError(.ECONNRESET)
            default: continue
            }
        }
    }

    /// Sends a request and reads until its response, skipping notifications.
    func request(_ id: Int, _ method: String, _ params: JSONValue) throws -> JSONValue {
        try send(["jsonrpc": "2.0", "id": .int(Int64(id)), "method": .string(method), "params": params])
        while true {
            let message = try receive()
            if message["id"]?.intValue == Int64(id), message["method"] == nil {
                if let error = message["error"] {
                    throw RPCError(code: error["code"]?.intValue ?? 0, message: error["message"]?.stringValue ?? "")
                }
                return message["result"] ?? .null
            }
        }
    }
}

struct TimedOut: Error {}

/// The value of `work`, or `TimedOut` once `limit` passes. It never waits for work that's stuck (a task group would:
/// it waits for every child before returning), so a test that catches a hang fails instead of hanging.
func within<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let once = OnceFlag()
        Task {
            do {
                let value = try await work()
                if once.take() { continuation.resume(returning: value) }
            } catch {
                if once.take() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: limit)
            if once.take() { continuation.resume(throwing: TimedOut()) }
        }
    }
}

extension RouterIntegrationTests {
    /// S1: an app that stops reading its connection holds up no other session, not even one on the same shared engine.
    /// (Before the fix, a second app couldn't even open a session there.) Its own messages wait for it, up to the
    /// bound `anAppFarBehindIsDisconnected` checks.
    @Test func anAppThatStopsReadingHoldsUpNoOneElse() async throws {
        let stack = try await Stack.start(port: 47629, modelPort: 47630)
        do {
            let projects = stack.root.appending(path: "projects", directoryHint: .isDirectory).realFileURL.path(
                percentEncoded: false)
            let stalled = try RawWebSocket(port: stack.port)
            let paired = try stalled.request(
                1, "agneta/pair", ["name": "Stalled", "scope": ["tools": "workspace", "folders": [.string(projects)]]])
            _ = try stalled.request(
                2, "initialize",
                [
                    "protocolVersion": 1, "clientCapabilities": [:],
                    "_meta": ["agneta": ["token": paired["token"] ?? .null]]
                ])
            let created = try stalled.request(
                3, "session/new",
                [
                    "cwd": .string(try stack.workspace("Stalled").path(percentEncoded: false)), "mcpServers": [],
                    "_meta": [
                        SessionPolicy.key: ["tools": "app-only", "approval": "never-ask"], "agneta": ["account": "dev"]
                    ]
                ])
            let stalledSession = try #require(created["sessionId"]?.stringValue)
            try stalled.send([
                "jsonrpc": "2.0", "id": 4, "method": "session/prompt",
                "params": ["sessionId": .string(stalledSession), "prompt": [["type": "text", "text": "LONGREPLY 3000"]]]
            ])
            // From here on the stalled app reads nothing.

            let app = AppClient(port: stack.port)
            defer { app.close() }
            try await app.pairAndInitialize("Reader")
            let session = try await app.newSession(cwd: try stack.workspace("Reader"), tools: "app-only")
            try await Task.sleep(for: .milliseconds(500))
            // A hang never ends; a busy engine does. The shared engine is still working through the 3 MB reply, which
            // on GitHub's 2-core Intel runner took the other turn past 5 s (2026-11-18), so the bound is generous.
            let result = try await within(.seconds(15)) { try await app.prompt(session, "hello") }
            #expect(result["stopReason"]?.stringValue == "end_turn")
            #expect(app.text(session) == "Hello from the fake model.")
            #expect(await stack.runtime.router.sessionCount == 2) // the stalled app's session waits for it
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }
}

@Suite struct BackpressureTests {
    /// An app that stops reading is disconnected once what waits for it passes the bound, and sends to it fail from
    /// then on, rather than queue without limit.
    @Test func anAppFarBehindIsDisconnected() async throws {
        let server = try WebSocketServer(port: 47631, maxQueued: 10_000, maxQueuedBytes: 256 << 10)
        try await server.start()
        defer { server.stop() }
        let client = try RawWebSocket(port: server.port)
        var connections = server.connections.makeAsyncIterator()
        let connection = try #require(await connections.next())
        let message = Data(repeating: UInt8(ascii: "x"), count: 1024)
        var sent = 0
        do {
            while sent < 100_000 {
                try await connection.send(message)
                sent += 1
            }
            Issue.record("100 MB waited for an app that reads nothing")
        } catch WebSocketServer.WebSocketError.backpressure {
            #expect(sent > 0)
        }
        await #expect(throws: WebSocketServer.WebSocketError.self) { try await connection.send(message) }
        _ = client
    }
}

extension RouterIntegrationTests {
    /// S2, settled: the suspicion was that OpenCode writes a step's message when the step starts and fills in its
    /// tokens later, so a read in between would count zeros. Measured on 2.3.0, halfway through a 5 s model call (reads
    /// every 2 s; the test uses 2.5 s, enough to span one), its database holds only the user's message: the assistant's is written once, when the step ends,
    /// with its tokens and cost. This keeps it that way: a slow call is counted in full.
    @Test(.enabled(if: GooseHarness.openCodeAvailable)) func openCodeUsageIsCountedWhenTheStepEnds() async throws {
        let stack = try await Stack.start(port: 47632, modelPort: 47633)
        do {
            let app = AppClient(port: stack.port)
            defer { app.close() }
            try await app.pairAndInitialize("Counted")
            let session = try await app.newSession(
                cwd: try stack.workspace("Counted"), tools: "app-only", account: "oc")
            let result = try await app.prompt(session, "PAUSE 2500 hello") // longer than one 2 s read
            let usage = result["_meta"]?["agneta/usage"]
            // The fake model reports 42 tokens in and 7 out for each call.
            #expect(usage?["modelCalls"]?.intValue == 1, "\(usage ?? .null)")
            #expect(usage?["inputTokens"]?.intValue == 42 && usage?["outputTokens"]?.intValue == 7, "\(usage ?? .null)")
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }
}

extension ContainmentTests {
    /// S3: a task's own engine is never shared. A load right after a close waits until the closed task's process is
    /// gone (one engine home, one process), and a load while a fork's helper holds the home waits for it and gets
    /// a process of its own, started with its own sandbox and setup.
    @Test func aTasksEngineIsNeverShared() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agneta-s3-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory
        ).realFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        // Answers initialize, then takes 0.6 s to exit once told to stop: a window in which a second process could start.
        let probe = ProbeAdapter(
            script: """
                trap 'sleep 0.6; exit 0' TERM
                IFS= read -r line
                id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
                printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{}}}\\n' "$id"
                while true; do sleep 0.05; done
                """)
        let supervisor = EngineSupervisor(
            .init(shellTool: BuiltTools.shell, root: root.appending(path: "agneta")),
            accounts: ["a": ProviderSetup(kind: .openAI, apiKey: "k")])
        let context = PolicyContext(
            userHome: FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [root.appending(path: "agneta")])
        let editing = try SessionPolicy.parse(
            ["tools": "workspace"], cwd: workspace.path(percentEncoded: false), context: context)
        let reading = try SessionPolicy.parse(
            ["tools": "read"], cwd: workspace.path(percentEncoded: false), context: context)
        func spec(_ policy: SessionPolicy) -> EngineSessionSpec {
            EngineSessionSpec(policy: policy, servers: [], instructions: nil)
        }

        let first = try await supervisor.open(
            account: "a", engine: probe, policy: editing, mcpPorts: [], key: nil, session: spec(editing))
        let closing = Task { await supervisor.release(first) }
        try await Task.sleep(for: .milliseconds(50))
        let loaded = try await supervisor.open(
            account: "a", engine: probe, policy: editing, mcpPorts: [], key: first.key, session: spec(editing))
        #expect(kill(first.pid, 0) != 0, "a second engine started while the first was still on its home")
        #expect(loaded.pid != first.pid)
        await closing.value

        // `loaded` now stands for a fork's helper holding the home: a load waits for it and gets its own process.
        let helperDone = Task {
            try? await Task.sleep(for: .milliseconds(200))
            await supervisor.release(loaded)
        }
        let again = try await supervisor.open(
            account: "a", engine: probe, policy: reading, mcpPorts: [], key: loaded.key, session: spec(reading))
        #expect(again.pid != loaded.pid && kill(loaded.pid, 0) != 0)
        await helperDone.value
        await supervisor.stopAll()
    }
}

extension RouterContractTests {
    /// S4: what an engine says about a new session before its answer to `session/new` (the commands it offers, say)
    /// reaches the app, under the session's id, not dropped for arriving before the session had one.
    @Test func updatesDuringSessionSetupReachTheApp() async throws {
        let stack = try await Stack.start(port: 47634)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Early")
        let session = try await stack.session(app, account: "brokered")
        for _ in 0..<20 where app.updates(session).isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        let early = app.updates(session).first { $0["sessionUpdate"]?.stringValue == "available_commands_update" }
        #expect(
            early?["availableCommands"]?.arrayValue?.first?["name"]?.stringValue == "review",
            "the update sent during session/new was dropped")
    }
}

extension RouterContractTests {
    /// S5: an app can't switch an OpenCode session out of Agneta's agent, which carries the session's instructions:
    /// another agent (OpenCode's own build or plan) is refused, naming the mode; Agneta's own passes.
    @Test func anOpenCodeSessionStaysInAgnetasAgent() async throws {
        let stack = try await Stack.start(port: 47635)
        defer { stack.stop() }
        let opencode = OpenCodeAdapter(executable: URL(filePath: "/usr/bin/false"))
        await stack.router.setCatalog(EngineCatalog(ready: [opencode]))
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Modes")
        let session = try await stack.session(app, account: "brokered")
        for request in [
            ("session/set_mode", ["modeId": "build"] as JSONValue),
            ("session/set_config_option", ["configId": "mode", "value": "plan"])
        ] {
            do {
                _ = try await app.request(request.0, request.1.setting("sessionId", to: .string(session)))
                Issue.record("\(request.0) left Agneta's agent")
            } catch let error as RPCError {
                #expect(
                    error.code == RPCError.invalidParams
                        && error.data?["agneta"]?["unenforceable"]?.arrayValue?.first?.stringValue == "mode")
            }
        }
        _ = try await app.request("session/set_mode", ["sessionId": .string(session), "modeId": "agneta"])
    }
}
