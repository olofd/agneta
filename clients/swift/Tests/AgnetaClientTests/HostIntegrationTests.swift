import Darwin
import Foundation
import Testing

@testable import AgnetaClient

@Suite(.enabled(if: ProcessInfo.processInfo.environment["AGNETA_CLIENT_INTEGRATION"] == "1"))
@MainActor struct HostIntegrationTests {
    struct Card: Codable, Sendable, Equatable { let name: String }
    @Test(.timeLimit(.minutes(4))) func realHostAndGooseAgainstFakeModel() async throws {
        let manager = FileManager.default
        #if arch(arm64)
            let architecture = "arm64"
        #else
            let architecture = "x86_64"
        #endif
        let hostBinary = repositoryRoot.appendingPathComponent(".build/debug/agnetad")
        let fakesBinary = repositoryRoot.appendingPathComponent(".build/debug/agneta-fakes")
        let goose = repositoryRoot.appendingPathComponent("Engines/bin/\(architecture)/goose-acp")
        for executable in [hostBinary, fakesBinary, goose] {
            guard manager.isExecutableFile(atPath: executable.path) else {
                throw AgnetaError(
                    .invalidParams, "Build agnetad, agneta-fakes, agneta-shell and fetch engines before this test.")
            }
        }
        let root = manager.temporaryDirectory.appendingPathComponent("agneta-swift-host-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let modelPort = try freePort()
        let model = try TestProcess(
            executable: fakesBinary,
            arguments: ["model", String(modelPort), root.appendingPathComponent("model.jsonl").path],
            log: root.appendingPathComponent("model.log"))
        var host: TestProcess?, tools: TestProcess?, client: AgnetaClient?
        do {
            try await model.waitFor { $0.contains("listening") }
            let toolPort = try freePort(excluding: [modelPort, modelPort + 2]), bearer = UUID().uuidString
            tools = try TestProcess(
                executable: fakesBinary,
                arguments: ["mcp", String(toolPort), bearer, root.appendingPathComponent("tools.jsonl").path],
                log: root.appendingPathComponent("tools.log"))
            try await tools!.waitFor { $0.contains("listening") }
            let port = try freePort(excluding: [modelPort, modelPort + 2, toolPort, toolPort + 2])
            host = try TestProcess(
                executable: hostBinary,
                arguments: [
                    "--goose", goose.path, "--home", root.appendingPathComponent("host").path,
                    "--port", String(port), "--env", "GOOSE_MODEL=gpt-4o", "--env", "OPENAI_API_KEY=fake",
                    "--env", "OPENAI_BASE_URL=http://127.0.0.1:\(modelPort)/v1"
                ], log: root.appendingPathComponent("host.log"))
            try await host!.waitFor { $0.contains("listening on") }
            let tokens = MemoryTokenStore()
            var options = ClientOptions(name: "Swift Client Integration", tokens: tokens)
            options.url = URL(string: "ws://127.0.0.1:\(port)/acp")!
            options.scope = PairingScope(
                tools: .workspace, providers: .all, engines: .only(["goose"]), sandbox: "contained")
            let connected = try AgnetaClient(options: options); client = connected
            #expect(try await connected.catalog().connected)
            let access = try await connected.connect()
            #expect(access.providers.first?.id == "dev"); #expect(tokens.load() != nil)
            var sessionOptions = SessionOptions()
            sessionOptions.account = "dev"; sessionOptions.engine = "goose"; sessionOptions.trace = true
            sessionOptions.policy = Policy(
                tools: .workspace, sandbox: .contained, network: "none", approval: .neverAsk,
                limits: .init(maxTurns: 20, maxSeconds: 90))
            sessionOptions.mcpServers = [
                HTTPMCPServer(name: "test", url: URL(string: "http://127.0.0.1:\(toolPort)/mcp")!, token: bearer)
            ]
            var live: [TraceRecord] = []
            sessionOptions.onEvent = { if case .trace(let records) = $0 { live += records } }
            let session = try await connected.newSession(sessionOptions)
            #expect(session.engine == "goose"); #expect(session.sandbox == "contained")
            let turn = try session.prompt("Hello there")
            var streamed = false
            for try await event in turn.events {
                if case .update(let update) = event, update.kind == "agent_message_chunk" { streamed = true }
            }
            let reply = try await turn.result
            #expect(streamed); #expect(!reply.text.isEmpty); #expect(reply.usage?.billing == "api-key")
            #expect(reply.usage?.modelCalls == 1)
            let toolReply = try await session.prompt(#"CALL test__echo {"text":"hi"}"#).result
            #expect(toolReply.toolCalls.contains { $0.status == "completed" })
            if let model = session.model?.currentValue {
                _ = try await session.setConfigOption(session.model!.id, value: model)
            }
            try await session.setInstructions("Be brief.", mode: "append", key: "tone")
            let slow = try session.prompt("Reply slowly.")
            let start = ContinuousClock.now
            while !(try String(contentsOf: root.appendingPathComponent("model.jsonl"), encoding: .utf8)).contains(
                "Reply slowly.")
            {
                if start.duration(to: .now) > .seconds(20) {
                    throw AgnetaError(.timeout, "Fake model did not see the slow prompt.")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await slow.cancel()
            #expect(try await slow.result.cancelled)
            let forked = try await session.fork()
            #expect(forked.forkOf == session.id); try await forked.close()
            try await session.close()
            var records: [TraceRecord] = []
            for try await record in connected.traceRecords(session.id, limit: 5) { records.append(record) }
            #expect(records.count > 5); #expect(!live.isEmpty)
            let resumed = try await connected.loadSession(session.id, options: sessionOptions)
            #expect(resumed.resumed); #expect(!resumed.history.isEmpty)
            try await resumed.close()
            let schema: JSONValue = [
                "type": "object", "properties": ["name": ["type": "string"]], "required": ["name"],
                "additionalProperties": false
            ]
            let card = try await connected.ask(
                #"CALL agneta-result__submit_result {"name":"Ada"}"#, schema: schema, as: Card.self)
            #expect(card.value == Card(name: "Ada"))
            #expect(card.turnResult.toolCalls.isEmpty)
            #expect(!card.turnResult.resultCalls.isEmpty)
            let list = try await connected.ask(
                #"CALL agneta-result__submit_result {"value":["a","b"]}"#,
                schema: ["type": "array", "items": ["type": "string"]], as: [String].self)
            #expect(list.value == ["a", "b"]); #expect(connected.sessions.isEmpty)
            var bad = SessionOptions(); bad.policy = Policy(tools: .workspace, sandbox: .developer)
            await expectKind(.unenforceable) { try await connected.newSession(bad) }
            connected.close()
            let again = try AgnetaClient(options: options)
            _ = try await again.connect(.init(pair: .never)); again.close()
            await host?.stop(); await tools?.stop(); await model.stop()
            try manager.removeItem(at: root)
        } catch {
            client?.close(); await host?.stop(); await tools?.stop(); await model.stop()
            // Keep the isolated logs on failure, matching the host's integration suites.
            throw error
        }
    }
}

// A range separate from the host suites, TypeScript client, and example apps. Reserve room for diagnostics (+2).
private func freePort(excluding: Set<Int> = []) throws -> Int {
    func bindPort(_ port: Int) -> Int32? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = UInt16(port).bigEndian
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { Darwin.close(descriptor); return nil }
        return descriptor
    }
    for port in (47700...47797).shuffled() where !excluding.contains(port) && !excluding.contains(port + 2) {
        guard let app = bindPort(port) else { continue }
        guard let diagnostics = bindPort(port + 2) else { Darwin.close(app); continue }
        Darwin.close(app); Darwin.close(diagnostics)
        return port
    }
    throw AgnetaError(.internalError, "No free Swift integration test port in 47700–47799.")
}
