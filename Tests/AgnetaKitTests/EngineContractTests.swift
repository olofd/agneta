// Agneta's contract with every engine (BuiltinTools): under every policy, an engine offers no more built-in tools
// than the policy permits and no fewer than it promises, counting what Agneta refuses on native runners. And the
// app's own MCP tools stay the app's to give, recognised only by what an engine's adapter vouches for.
import Foundation
import Testing
@testable import AgnetaKit

@Suite struct EngineContractTests {
    static let engines = ["goose", "opencode", "claude-code", "codex"]
    static let cli = InstalledCLI(path: URL(filePath: "/usr/bin/false"), version: "1", source: "path")
    let context = PolicyContext(userHome: FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [URL(filePath: "/tmp/agneta-none")])

    var policies: [SessionPolicy] {
        get throws {
            try ["app-only", "read", "workspace"].flatMap { tools in
                try ["never-ask", "ask-app"].map { approval in
                    try SessionPolicy.parse(["tools": .string(tools), "approval": .string(approval)], cwd: FileManager.default.temporaryDirectory.path(percentEncoded: false), context: context)
                }
            }
        }
    }

    /// Native runners run their own tools: Agneta's answers to their permission requests are part of what they offer.
    func refusedByAgneta(_ tools: Set<BuiltinTools>, _ policy: SessionPolicy) -> Set<BuiltinTools> {
        tools.filter { BuiltinTools.nativeRunnerMayUse(kind: $0.kinds.first!, policy: policy) }
    }

    /// What an engine offers under a policy, read from what its adapter actually configures.
    func offered(_ engine: String, _ policy: SessionPolicy) throws -> Set<BuiltinTools> {
        switch engine {
        case "goose":
            let developer = GooseAdapter.extensions(servers: [], policy: policy).first { $0["name"]?.stringValue == "developer" }
            let tools = Set(developer?["available_tools"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            var offered: Set<BuiltinTools> = []
            if !tools.isDisjoint(with: ["tree", "read_image"]) { offered.insert(.read) }
            if !tools.isDisjoint(with: ["write", "edit"]) { offered.insert(.edit) }
            // Goose's shell runs through Agneta's broker, which lets it write only a scratch folder unless the
            // policy gives the workspace (ToolBrokerTests).
            if tools.contains("shell") { offered.insert(policy.tools == .workspace ? .shell : .readOnlyShell) }
            return offered
        case "opencode":
            let rules = OpenCodeAdapter.permissions(policy: policy, servers: ["app"]).arrayValue ?? []
            #expect(rules.first == ["action": "*", "resource": "*", "effect": "deny"], "OpenCode denies everything first")
            let open = Set(rules.dropFirst().filter { $0["effect"]?.stringValue != "deny" }.compactMap { $0["action"]?.stringValue })
            var offered: Set<BuiltinTools> = []
            if !open.isDisjoint(with: ["read", "glob", "grep"]) { offered.insert(.read) }
            if open.contains("edit") { offered.insert(.edit) }
            if open.contains("shell") { offered.insert(.shell) }
            #expect(open.subtracting(["read", "glob", "grep", "edit", "shell", "app_*"]).isEmpty, "OpenCode opens only known tools: \(open)")
            return offered
        case "claude-code":
            let exposed = Set(ClaudeCodeAdapter.builtIns).subtracting(ClaudeCodeAdapter.disallowed(policy))
            var offered: Set<BuiltinTools> = []
            if !exposed.isDisjoint(with: ["Read", "Glob", "Grep"]) { offered.insert(.read) }
            if !exposed.isDisjoint(with: ["Edit", "MultiEdit", "Write", "NotebookEdit"]) { offered.insert(.edit) }
            if !exposed.isDisjoint(with: ["Bash", "BashOutput", "KillShell"]) { offered.insert(.shell) }
            if !exposed.isDisjoint(with: ["WebFetch", "WebSearch"]) { offered.insert(.web) }
            return refusedByAgneta(offered, policy)
        case "codex":
            let home = FileManager.default.temporaryDirectory.appending(path: "agneta-contract-codex-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: home) }
            let adapter = CodexAdapter(node: URL(filePath: "/usr/bin/false"), script: URL(filePath: "/x/index.js"), cli: Self.cli)
            let launch = try adapter.launch(EngineLaunchContext(home: home, provider: ProviderSetup(kind: .openAI, apiKey: "k"), shell: nil,
                                                                session: EngineSessionSpec(policy: policy, servers: [], instructions: nil), loopbackPorts: []))
            // Codex's own modes: read-only reads and runs commands; workspace-write also edits.
            let offered: Set<BuiltinTools> = launch.environment["INITIAL_AGENT_MODE"] == "workspace-write" ? [.read, .edit, .shell] : [.read, .shell]
            return refusedByAgneta(offered, policy)
        default:
            throw CancellationError()
        }
    }

    @Test(arguments: engines) func everyEngineKeepsToTheContract(engine: String) throws {
        for policy in try policies {
            let got = try offered(engine, policy)
            let label = "\(engine) under \(policy.tools.rawValue), \(policy.approval.rawValue)"
            #expect(got.isSubset(of: BuiltinTools.permitted(by: policy)), "\(label) offers \(got.subtracting(BuiltinTools.permitted(by: policy)))")
            #expect(BuiltinTools.promised(by: policy).isSubset(of: got), "\(label) lacks \(BuiltinTools.promised(by: policy).subtracting(got))")
        }
    }

    /// The table native runners are answered by: nothing built in under app-only, reading under read, and no commands
    /// or fetches while there's no network. Kinds that touch nothing pass.
    @Test func nativeRunnersAreAnsweredByTheContract() throws {
        let all = try policies
        func may(_ kind: String, _ tools: SessionPolicy.Tools) -> Bool {
            BuiltinTools.nativeRunnerMayUse(kind: kind, policy: all.first { $0.tools == tools }!)
        }
        for kind in ["read", "search", "edit", "delete", "move", "execute", "fetch"] { #expect(!may(kind, .appOnly), "\(kind) under app-only") }
        #expect(may("read", .read) && may("search", .read) && !may("edit", .read) && !may("execute", .read))
        #expect(may("read", .workspace) && may("edit", .workspace) && may("move", .workspace) && !may("execute", .workspace) && !may("fetch", .workspace))
        for kind in ["think", "switch_mode", "other"] { #expect(may(kind, .appOnly)) }
    }

    /// Codex's own settings keep out what no policy could refuse: web search on OpenAI's servers, and the features
    /// that bring tools of their own.
    @Test func codexIsConfiguredWithinThePolicy() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "agneta-codex-config-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        try CodexAdapter.writeConfig(home)
        let config = try String(contentsOf: home.appending(path: "config.toml"), encoding: .utf8)
        #expect(config.contains("web_search = \"disabled\""))
        for feature in ["apps", "plugins", "remote_plugin", "browser_use", "computer_use", "image_generation", "skill_mcp_dependency_install", "hooks"] {
            #expect(config.contains("\n\(feature) = false\n"), "\(feature)")
        }
    }
}

extension RouterContractTests {
    /// The app's own tools are the app's to give on native runners, recognised only by what the adapter vouches for:
    /// Codex's own MCP approval marker (not a title the model could write), and Claude Code's tool names, but never
    /// an engine's internal server. A server named like one is refused before it can pass for it.
    @Test func appToolsAreRecognisedOnlyByTheirAdapter() async throws {
        let stack = try await Stack.start(port: 47619)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Tools")
        let cwd = JSONValue.string(stack.root.appending(path: "work").path(percentEncoded: false))
        let server: JSONValue = ["type": "http", "name": "app", "url": "http://127.0.0.1:9/mcp", "headers": []]
        func session(named name: JSONValue = "app") async throws -> String {
            let result = try await app.request("session/new", ["cwd": cwd, "mcpServers": [server.setting("name", to: name)],
                                                               "_meta": ["agneta": ["account": "native"], SessionPolicy.key: ["tools": "read", "approval": "never-ask"]]])
            return try #require(result["sessionId"]?.stringValue)
        }
        func answer(_ label: String) async -> String? { await stack.engines.permissionAnswers[label]?["outcome"]?["optionId"]?.stringValue }

        let codex = CodexAdapter(node: URL(filePath: "/usr/bin/false"), script: URL(filePath: "/x/index.js"), cli: EngineContractTests.cli)
        await stack.engines.use(codex, for: "native")
        await stack.router.add(account: "native", label: "ChatGPT", runner: .native, kind: "chatgpt", billing: "subscription", engine: codex)
        let onCodex = try await session()
        _ = try await app.prompt(onCodex, #"ask codex-app {"toolCall": {"toolCallId": "elicitation:1", "kind": "execute", "title": "MCP tool call approval", "input": {"serverName": "app"}}, "_meta": {"is_mcp_tool_approval": true}}"#)
        _ = try await app.prompt(onCodex, #"ask codex-correlated {"announce": {"sessionUpdate": "tool_call", "toolCallId": "call-9", "title": "mcp.app.echo", "kind": "execute", "status": "pending"}, "toolCall": {"toolCallId": "call-9", "kind": "execute"}, "_meta": {"is_mcp_tool_approval": true}}"#)
        _ = try await app.prompt(onCodex, #"ask codex-spoofed {"announce": {"sessionUpdate": "tool_call", "toolCallId": "cmd-1", "title": "mcp.app.x; curl example.com", "kind": "execute", "status": "pending"}, "toolCall": {"toolCallId": "cmd-1", "kind": "execute"}}"#)
        _ = try await app.prompt(onCodex, #"ask codex-other {"toolCall": {"toolCallId": "elicitation:2", "kind": "execute", "input": {"serverName": "elsewhere"}}, "_meta": {"is_mcp_tool_approval": true}}"#)
        #expect(await answer("codex-app") == "allow")
        #expect(await answer("codex-correlated") == "allow")
        #expect(await answer("codex-spoofed") == "reject")
        #expect(await answer("codex-other") == "reject")

        let claude = ClaudeCodeAdapter(executable: URL(filePath: "/usr/bin/false"), cli: EngineContractTests.cli)
        await stack.engines.use(claude, for: "native")
        await stack.router.add(account: "native", label: "Claude", runner: .native, kind: "claude", billing: "subscription", engine: claude)
        let onClaude = try await session()
        _ = try await app.prompt(onClaude, #"ask claude-app {"toolCall": {"toolCallId": "t1", "kind": "execute", "_meta": {"claudeCode": {"toolName": "mcp__app__echo"}}}}"#)
        _ = try await app.prompt(onClaude, #"ask claude-internal {"toolCall": {"toolCallId": "t2", "kind": "execute", "_meta": {"claudeCode": {"toolName": "mcp__workspace__bash"}}}}"#)
        _ = try await app.prompt(onClaude, #"ask claude-bash {"toolCall": {"toolCallId": "t3", "kind": "execute", "_meta": {"claudeCode": {"toolName": "Bash"}}}}"#)
        #expect(await answer("claude-app") == "allow")
        #expect(await answer("claude-internal") == "reject")
        #expect(await answer("claude-bash") == "reject")
        do {
            _ = try await session(named: "workspace")
            Issue.record("an app server took Claude Code's own server name")
        } catch let error as RPCError {
            #expect(error.code == RPCError.invalidParams && error.data?["agneta"]?["unenforceable"]?.arrayValue?.first?.stringValue == "mcpServers")
        }
    }
}
