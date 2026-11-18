// A real round on your own accounts (manual):
//   AGNETA_REAL_PROBE=1 AGNETA_REAL_PROBE_HOME=<folder> swift test --filter realProbe
// Runs ChatGPT (Luna, on Codex) and Claude (Haiku where offered) plans through Agneta's whole stack, with the sign-ins
// in AGNETA_REAL_PROBE_HOME, a fake app tool server and a temporary data folder; prints replies, usage and trace
// summaries. The folder is laid out like Agneta's own data (Accounts/<id>, Runtimes); sign in once with
// `agneta-signin claude --home <folder>/Accounts/claude` and `agneta-signin codex --home <folder>/Accounts/chatgpt`.
// AGNETA_REAL_PROBE_ACCOUNTS=claude-direct,codex picks accounts; AGNETA_REAL_PROBE_KEEP=<folder> keeps each trace;
// AGNETA_REAL_PROBE_TOOLS=workspace and AGNETA_REAL_PROBE_PROMPT=<text> replace the policy's tools and the second prompt.
import Foundation
import Testing
@testable import AgnetaKit

@Test(.enabled(if: ProcessInfo.processInfo.environment["AGNETA_REAL_PROBE"] != nil)) func realProbe() async throws {
    let env = ProcessInfo.processInfo.environment
    let home = try #require(env["AGNETA_REAL_PROBE_HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) },
                            "Set AGNETA_REAL_PROBE_HOME to the folder holding the probe's sign-ins")
    let accounts = AgnetaStore(root: home).accountsFolder
    let root = FileManager.default.temporaryDirectory.appending(path: "agneta-real-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory).realFileURL
    try FileManager.default.createDirectory(at: root.appending(path: "work"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let mcp = try GooseHarness.fake("fake-mcp.py", ["47489", "realprobe-bearer-123", root.appending(path: "mcp.log").path(percentEncoded: false)], root: root, name: "mcp")
    defer { killpg(mcp.pid, SIGKILL) }
    // The pinned adapter version, installed (and verified) where the app would keep it.
    let adapterPath = try await RuntimeInstaller(lockFile: GooseHarness.repo.appending(path: "Engines/runtimes.lock"),
                                                 runtimes: AgnetaStore(root: home).runtimesFolder).install("claude-agent-acp")
    let traces = Traces(folder: root.appending(path: "agneta/Traces", directoryHint: .isDirectory))
    let goose = GooseAdapter(executable: GooseHarness.goose)
    let claudeCLI = try #require(CLILocator.claudeCode().first, "Claude Code isn't installed")
    let claudeCode = ClaudeCodeAdapter(executable: adapterPath, cli: claudeCLI)
    print("PROBE Claude Code:", claudeCLI.label)
    let bin = GooseHarness.repo.appending(path: "Engines/bin/\(GooseHarness.arch)")
    let codex = CLILocator.codex().first(where: \.supported).map { CodexAdapter(node: bin.appending(path: "node-runtime/bin/node"), script: bin.appending(path: "codex-acp/dist/index.js"), cli: $0) }
    let supervisor = EngineSupervisor(.init(engines: [goose, claudeCode] + (codex.map { [$0] } ?? []), shellTool: BuiltTools.shell, root: root.appending(path: "agneta"), traces: traces), accounts: [
        "codex": AccountSetup(engine: "codex", provider: ProviderSetup(kind: .chatGPT, subscription: SubscriptionAccount(route: .chatGPT, home: accounts.appending(path: "chatgpt", directoryHint: .isDirectory)))),
        "claude-direct": AccountSetup(engine: "claude-code", provider: ProviderSetup(kind: .claudeCode, subscription: SubscriptionAccount(route: .claudeCode, home: accounts.appending(path: "claude", directoryHint: .isDirectory), adapter: adapterPath))),
        "claude": AccountSetup(engine: "goose", provider: ProviderSetup(kind: .claudeCode, subscription: SubscriptionAccount(route: .claudeCode, home: accounts.appending(path: "claude", directoryHint: .isDirectory), adapter: adapterPath, claudeCode: claudeCLI.path))),
    ])
    let router = Router(context: PolicyContext(userHome: FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [root.appending(path: "agneta")]),
                        engines: supervisor, traces: traces) { _ in Router.PairingAnswer(accounts: ["claude", "claude-direct", "codex"], remember: true) }
    await router.add(account: "claude", label: "Claude", runner: .native, kind: "claude", billing: "subscription", engine: goose)
    await router.add(account: "claude-direct", label: "Claude (Claude Code)", runner: .native, kind: "claude", billing: "subscription", engine: claudeCode)
    if let codex { await router.add(account: "codex", label: "ChatGPT (Codex)", runner: .native, kind: "chatgpt", billing: "subscription", engine: codex) }
    let server = try WebSocketServer(port: 47488)
    try await server.start()
    defer { server.stop() }
    Task { for await connection in server.connections { Task { await router.serve(connection) } } }
    AppClient.register(scope: root.appending(path: "work", directoryHint: .isDirectory), port: 47488)
    let app = AppClient(port: 47488)
    defer { app.close() }
    try await app.pairAndInitialize("Probe")
    let only = env["AGNETA_REAL_PROBE_ACCOUNTS"].map { Set($0.split(separator: ",").map(String.init)) }
    for (account, wanted) in [("claude", "haiku"), ("claude-direct", "haiku"), ("codex", "luna")] where only?.contains(account) ?? true {
        do {
            let created = try await app.request("session/new", [
                "cwd": .string(root.appending(path: "work").path(percentEncoded: false)),
                "mcpServers": [["type": "http", "name": "app", "url": "http://127.0.0.1:47489/mcp", "headers": [["name": "Authorization", "value": "Bearer realprobe-bearer-123"]]]],
                "_meta": ["agneta": ["account": .string(account)], SessionPolicy.key: ["tools": .string(env["AGNETA_REAL_PROBE_TOOLS"] ?? "app-only"), "approval": "never-ask"],
                          "agneta/instructions": ["text": "You are testing a tool connection. Be very brief."], "agneta/trace@1": ["live": true]],
            ])
            let session = try #require(created["sessionId"]?.stringValue)
            // The raw trace, for measuring: kept whether the round succeeds or fails.
            defer {
                if let keep = env["AGNETA_REAL_PROBE_KEEP"] {
                    traces.session(session)?.writer.flush()
                    try? FileManager.default.copyItem(at: traces.file(for: session), to: URL(filePath: keep).appending(path: "\(account).jsonl"))
                }
            }
            let options = created["configOptions"]?.arrayValue?.first { $0["id"]?.stringValue == "model" }?["options"]?.arrayValue ?? []
            let pick = options.compactMap { $0["value"]?.stringValue }.first { $0.lowercased().contains(wanted) }
            print("PROBE \(account) models:", options.compactMap { $0["value"]?.stringValue }.prefix(12), "pick:", pick ?? "none")
            if let pick { _ = try await app.request("session/set_config_option", ["sessionId": .string(session), "configId": "model", "value": .string(pick)]) }
            let started = ContinuousClock.now
            let first = try await app.prompt(session, "Reply with exactly: agneta works")
            print("PROBE \(account) reply:", app.text(session).suffix(160), "in", ContinuousClock.now - started)
            var t = ""; TraceJSON.encode(first["_meta"]?["agneta/usage@1"] ?? .null, into: &t); print("PROBE \(account) usage:", t)
            let second = try await app.prompt(session, env["AGNETA_REAL_PROBE_PROMPT"] ?? "Call the app echo tool with the text 'agneta', then say what it returned.")
            print("PROBE \(account) second reply:", app.text(session).suffix(300).replacingOccurrences(of: "\n", with: " "))
            print("PROBE \(account) work folder:", (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "work").path(percentEncoded: false))) ?? [])
            print("PROBE \(account) tool turn:", second["stopReason"] ?? .null, "tool output:", app.toolOutput(session).prefix(120))
            _ = try await app.request("session/close", ["sessionId": .string(session)])
            try await Task.sleep(for: .milliseconds(500))
            let s = TraceSummary(records: traces.records(task: session) ?? [])
            print("PROBE \(account) trace: turns", s.turns.map { "\($0.n):\($0.stopReason):\(Int($0.ms ?? 0))ms:\($0.modelCalls)calls:in\($0.input)" },
                  "tools", s.toolStats.map { "\($0.name)×\($0.calls)" }, "model calls", s.modelCalls, "live records", app.traceRecords(session).count, "of", s.records,
                  "bearer in trace:", (try? String(contentsOf: traces.file(for: session), encoding: .utf8))?.contains("realprobe-bearer-123") ?? false)
        } catch { print("PROBE \(account) failed:", error) }
    }
    await supervisor.stopAll()
}
