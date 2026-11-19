// End-to-end checks against the pinned goose-acp and the scripted fake model
// (FakeServers.swift). No real provider is called. Skipped when the engine
// hasn't been fetched (scripts/fetch-engines).
import AgnetaFakes
import Foundation
import Testing

@testable import AgnetaKit

struct GooseHarness {
    static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static var arch: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return machine == "arm64" ? "arm64" : "x86_64"
    }
    static let goose = repo.appending(path: "Engines/bin/\(arch)/goose-acp")
    static let opencode = repo.appending(path: "Engines/bin/\(arch)/opencode")
    static var openCodeAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: opencode.path(percentEncoded: false))
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: goose.path(percentEncoded: false)) }

    /// Removes a test's folder, unless `AGNETA_KEEP_TEST_FILES` is set: CI keeps them to upload when a run fails.
    static func discard(_ folder: URL) {
        guard ProcessInfo.processInfo.environment["AGNETA_KEEP_TEST_FILES"] == nil else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    let root: URL
    let model: FakeServer
    let engine: ChildProcess
    let peer: RPCPeer
    let updates: UpdateLog

    /// Collects session/update notifications per session.
    actor UpdateLog {
        var bySession: [String: [JSONValue]] = [:]
        func add(_ params: JSONValue?) {
            guard let id = params?["sessionId"]?.stringValue, let update = params?["update"] else { return }
            bySession[id, default: []].append(update)
        }
        func text(_ session: String) -> String {
            (bySession[session] ?? []).compactMap { update in
                update["sessionUpdate"]?.stringValue == "agent_message_chunk"
                    ? update["content"]?["text"]?.stringValue : nil
            }.joined()
        }
    }

    static func start(port: Int) async throws -> GooseHarness {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agneta-goose-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "work"), withIntermediateDirectories: true)
        let model = try await FakeServer.model(port: port, log: root.appending(path: "model.log"))
        // The fake model stops if the engine can't start: a leaked one holds its port for later runs.
        do {
            return try await start(root: root, model: model, port: port)
        } catch {
            model.stop()
            throw error
        }
    }

    private static func start(root: URL, model: FakeServer, port: Int) async throws -> GooseHarness {
        let launch = GooseLaunch(
            executable: goose, home: root.appending(path: "home", directoryHint: .isDirectory),
            provider: [
                "GOOSE_PROVIDER": "openai", "GOOSE_MODEL": "gpt-4o",
                "OPENAI_BASE_URL": "http://127.0.0.1:\(port)/v1", "OPENAI_API_KEY": "fake"
            ])
        let engine = try launch.start(directory: root.appending(path: "work"))
        let (peer, lines) = RPCPeer.stdio(engine)
        let updates = UpdateLog()
        await peer.handle(notifications: { method, params in
            if method == "session/update" { await updates.add(params) }
        })
        Task { await peer.run(lines) }
        do {
            _ = try await peer.request(
                "initialize",
                [
                    "protocolVersion": 1, "clientCapabilities": [:],
                    "clientInfo": ["name": "agneta-tests", "version": "0"]
                ])
        } catch {
            await engine.stop()
            throw error
        }
        return GooseHarness(root: root, model: model, engine: engine, peer: peer, updates: updates)
    }

    func newSession() async throws -> String {
        let result = try await peer.request(
            "session/new", ["cwd": .string(root.appending(path: "work").path(percentEncoded: false)), "mcpServers": []])
        return try #require(result["sessionId"]?.stringValue)
    }

    func prompt(_ session: String, _ text: String) async throws -> JSONValue {
        try await peer.request(
            "session/prompt", ["sessionId": .string(session), "prompt": [["type": "text", "text": .string(text)]]])
    }

    /// Runs `body` with a fresh engine and fake model, and always stops both before returning.
    static func with(port: Int, _ body: (GooseHarness) async throws -> Void) async throws {
        let goose = try await start(port: port)
        do { try await body(goose) } catch {
            await goose.stop()
            throw error
        }
        await goose.stop()
    }

    func stop() async {
        await engine.stop()
        model.stop()
        Self.discard(root)
    }
}

@Suite(.serialized, .enabled(if: GooseHarness.available, "run scripts/fetch-engines first"))
struct GooseIntegrationTests {
    @Test func twoConcurrentSessionsInOneEngine() async throws {
        try await GooseHarness.with(port: 47411) { goose in
            let a = try await goose.newSession()
            let b = try await goose.newSession()
            #expect(a != b)
            async let first = goose.prompt(a, "hello from A")
            async let second = goose.prompt(b, "hello from B")
            let results = try await [first, second]
            #expect(results.allSatisfy { $0["stopReason"]?.stringValue == "end_turn" })
            #expect(await goose.updates.text(a) == "Hello from the fake model.")
            #expect(await goose.updates.text(b) == "Hello from the fake model.")
        }
    }

    @Test func cancelEndsTheTurnQuickly() async throws {
        try await GooseHarness.with(port: 47412) { goose in
            let session = try await goose.newSession()
            let started = ContinuousClock.now
            let turn = Task { try await goose.prompt(session, "answer slowly") }
            try await Task.sleep(for: .milliseconds(500))
            try await goose.peer.notify("session/cancel", ["sessionId": .string(session)])
            let result = try await turn.value
            #expect(result["stopReason"]?.stringValue == "cancelled")
            #expect(ContinuousClock.now - started < .seconds(3))
        }
    }

    @Test func secondPromptWhileBusyIsRefused() async throws {
        try await GooseHarness.with(port: 47413) { goose in
            let session = try await goose.newSession()
            let turn = Task { try await goose.prompt(session, "answer slowly") }
            try await Task.sleep(for: .milliseconds(500))
            await #expect(throws: RPCError.self) { _ = try await goose.prompt(session, "and another") }
            try await goose.peer.notify("session/cancel", ["sessionId": .string(session)])
            _ = try? await turn.value
        }
    }
}
