// Agneta's contract with every engine (BuiltinTools): under every policy, an engine offers no more built-in tools
// than the policy permits and no fewer than it promises, counting what Agneta refuses on native runners. And the
// app's own MCP tools stay the app's to give, recognised only by what an engine's adapter vouches for.
import Foundation
import Testing

@testable import AgnetaKit

@Suite struct EngineContractTests {
    static let engines = ["goose", "opencode", "claude-code", "codex"]
    static let cli = InstalledCLI(path: URL(filePath: "/usr/bin/false"), version: "1", source: "path")
    let context = PolicyContext(
        userHome: FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [URL(filePath: "/tmp/agneta-none")])

    var policies: [SessionPolicy] {
        get throws {
            try ["app-only", "read", "workspace"].flatMap { tools in
                try ["never-ask", "ask-app"].map { approval in
                    try SessionPolicy.parse(
                        ["tools": .string(tools), "approval": .string(approval)],
                        cwd: FileManager.default.temporaryDirectory.path(percentEncoded: false), context: context)
                }
            }
        }
    }

    /// Native runners run their own tools: Agneta's answers to their permission requests are part of what they offer.
    func refusedByAgneta(_ tools: Set<BuiltinTools>, _ policy: SessionPolicy) -> Set<BuiltinTools> {
        tools.filter { tool in tool.kinds.allSatisfy { BuiltinTools.nativeRunnerMayUse(kind: $0, policy: policy) } }
    }

    /// What an engine offers under a policy, read from what its adapter actually configures.
    func offered(_ engine: String, _ policy: SessionPolicy) throws -> Set<BuiltinTools> {
        switch engine {
        case "goose":
            let developer = GooseAdapter.extensions(servers: [], policy: policy).first {
                $0["name"]?.stringValue == "developer"
            }
            let tools = Set(developer?["available_tools"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            var offered: Set<BuiltinTools> = []
            // Goose reads files through its shell (`tree` lists folders and `read_image` shows images), its reading
            // tool where `read` is kept; without it, the shell is there for `execute`, and reads what commands can.
            if tools.contains("shell"), policy.allows(.read) { offered.insert(.read) }
            if !tools.isDisjoint(with: ["write", "edit"]) { offered.insert(.edit) }
            // Goose's shell runs through Agneta's broker, which lets it write only a scratch folder unless the
            // policy gives the workspace (ToolBrokerTests).
            if tools.contains("shell") { offered.insert(policy.tools == .workspace ? .shell : .readOnlyShell) }
            return offered
        case "opencode":
            let rules = OpenCodeAdapter.permissions(policy: policy, servers: ["app"]).arrayValue ?? []
            #expect(
                rules.first == ["action": "*", "resource": "*", "effect": "deny"], "OpenCode denies everything first")
            let open = Set(
                rules.dropFirst().filter { $0["effect"]?.stringValue != "deny" }.compactMap {
                    $0["action"]?.stringValue
                })
            var offered: Set<BuiltinTools> = []
            if !open.isDisjoint(with: ["read", "glob", "grep"]) { offered.insert(.read) }
            if open.contains("edit") { offered.insert(.edit) }
            if open.contains("shell") { offered.insert(.shell) }
            #expect(
                open.subtracting(["read", "glob", "grep", "edit", "shell", "app_*"]).isEmpty,
                "OpenCode opens only known tools: \(open)")
            return offered
        case "claude-code":
            // Claude Code offers exactly the `tools` it's given (measured on 2.1.325), less what's disallowed.
            let exposed = Set(try #require(ClaudeCodeAdapter.tools(policy))).subtracting(
                ClaudeCodeAdapter.disallowed(policy))
            var offered: Set<BuiltinTools> = []
            if !exposed.isDisjoint(with: ["Read", "Glob", "Grep"]) { offered.insert(.read) }
            if !exposed.isDisjoint(with: ["Edit", "MultiEdit", "Write", "NotebookEdit"]) { offered.insert(.edit) }
            if !exposed.isDisjoint(with: ["Bash", "BashOutput", "KillShell", "PowerShell", "Monitor"]) {
                offered.insert(.shell)
            }
            if !exposed.isDisjoint(with: ["WebFetch", "WebSearch"]) { offered.insert(.web) }
            return refusedByAgneta(offered, policy)
        case "codex":
            let home = FileManager.default.temporaryDirectory.appending(
                path: "agneta-contract-codex-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: home) }
            let adapter = CodexAdapter(
                node: URL(filePath: "/usr/bin/false"), script: URL(filePath: "/x/index.js"), cli: Self.cli)
            let launch = try adapter.launch(
                EngineLaunchContext(
                    home: home, provider: ProviderSetup(kind: .openAI, apiKey: "k"),
                    shell: URL(filePath: "/usr/bin/true"),
                    session: EngineSessionSpec(policy: policy, servers: [], instructions: nil), loopbackPorts: []))
            let config: JSONValue = try JSONCoding.decode(Data(try #require(launch.environment["CODEX_CONFIG"]).utf8))
            #expect(config["features"]?["shell_tool"] == false && config["features"]?["unified_exec"] == false)
            // Its commands run through Agneta's shell, under the session's tool profile (read-only below workspace
            // tools), and that's how it reads files: `view_image` only shows images. `apply_patch` is always offered,
            // and answered by Agneta; web search runs on OpenAI's servers, asking nobody.
            var offered = refusedByAgneta([.edit], policy)
            if launch.environment["AGNETA_SHELL"] == "1" {
                offered.insert(policy.tools == .workspace ? .shell : .readOnlyShell)
                if policy.allows(.read) { offered.insert(.read) }
            }
            if config["web_search"] == "live" { offered.insert(.web) }
            return offered
        default:
            throw CancellationError()
        }
    }

    @Test(arguments: engines) func everyEngineKeepsToTheContract(engine: String) throws {
        for policy in try policies {
            let got = try offered(engine, policy)
            let label = "\(engine) under \(policy.tools.rawValue), \(policy.approval.rawValue)"
            #expect(
                got.isSubset(of: BuiltinTools.permitted(by: policy)),
                "\(label) offers \(got.subtracting(BuiltinTools.permitted(by: policy)))")
            #expect(
                BuiltinTools.promised(by: policy).isSubset(of: got),
                "\(label) lacks \(BuiltinTools.promised(by: policy).subtracting(got))")
        }
    }

    /// The table native runners are answered by: nothing built in under app-only, reading under read, and no commands
    /// or fetches while there's no network. Kinds that touch nothing pass; a missing kind, or one ACP doesn't define,
    /// is refused even under the widest policy.
    @Test func nativeRunnersAreAnsweredByTheContract() throws {
        let all = try policies
        func may(_ kind: String?, _ tools: SessionPolicy.Tools) -> Bool {
            BuiltinTools.nativeRunnerMayUse(kind: kind, policy: all.first { $0.tools == tools }!)
        }
        for kind in ["read", "search", "edit", "delete", "move", "execute", "fetch"] {
            #expect(!may(kind, .appOnly), "\(kind) under app-only")
        }
        #expect(may("read", .read) && may("search", .read) && !may("edit", .read) && !may("execute", .read))
        #expect(
            may("read", .workspace) && may("edit", .workspace) && may("move", .workspace) && !may("execute", .workspace)
                && !may("fetch", .workspace))
        for kind in ["think", "switch_mode"] { #expect(may(kind, .appOnly)) }
        for kind in [nil, "", "shell", "network"] as [String?] {
            #expect(!may(kind, .workspace), "\(kind ?? "no kind") under workspace")
        }
        // `other` proves nothing (claude-agent-acp reports Monitor, which runs commands, that way): it passes only
        // for a tool known to run nothing, by name.
        let workspace = all.first { $0.tools == .workspace }!
        #expect(BuiltinTools.nativeRunnerMayUse(kind: "other", tool: "ToolSearch", policy: workspace))
        for tool in ["Monitor", "Workflow", "SendMessage", "Unheard"] as [String?] + [nil] {
            #expect(
                !BuiltinTools.nativeRunnerMayUse(kind: "other", tool: tool, policy: workspace),
                "other: \(tool ?? "no name")")
        }
    }

    /// Developer access runs the engine's own tools, as in a terminal: every kind passes, Claude Code gets its own tool
    /// set but for what reaches the claude.ai account, and Codex keeps a mode that asks before edits; files Codex trusts
    /// at its next start stay read-only.
    @Test func developerAccessRunsTheEnginesOwnTools() throws {
        let cwd = FileManager.default.temporaryDirectory.path(percentEncoded: false)
        var developer = try SessionPolicy.parse(["tools": "workspace"], cwd: cwd, context: context)
        developer.sandbox = .developer
        for kind in ["execute", "fetch", "other", "edit"] {
            #expect(BuiltinTools.nativeRunnerMayUse(kind: kind, tool: "Monitor", policy: developer))
        }
        #expect(ClaudeCodeAdapter.tools(developer) == nil)
        #expect(
            ClaudeCodeAdapter.disallowed(developer).contains("Artifact")
                && !ClaudeCodeAdapter.disallowed(developer).contains("Bash"))
        let home = FileManager.default.temporaryDirectory.appending(
            path: "agneta-contract-dev-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let adapter = CodexAdapter(
            node: URL(filePath: "/usr/bin/false"), script: URL(filePath: "/x/index.js"), cli: Self.cli)
        let launch = try adapter.launch(
            EngineLaunchContext(
                home: home, provider: ProviderSetup(kind: .openAI, apiKey: "k"), shell: nil,
                session: EngineSessionSpec(policy: developer, servers: [], instructions: nil), loopbackPorts: []))
        #expect(launch.environment["INITIAL_AGENT_MODE"] == "workspace-write")
        let codexHome = home.appending(path: "codex", directoryHint: .isDirectory)
        for file in ["config.toml", ".env", "AGENTS.md", "skills"] {
            #expect(launch.readOnly.map(\.realFileURL).contains(codexHome.appending(path: file).realFileURL), "\(file)")
        }
    }

    /// Claude Code gets the same options on every open, a resumed session included (given none, the adapter loads
    /// the workspace's own settings), and every session is set to the mode that asks (it starts in `auto`).
    @Test func claudeCodeKeepsItsOptionsOnResume() throws {
        let adapter = ClaudeCodeAdapter(executable: URL(filePath: "/usr/bin/false"), cli: Self.cli)
        let policy = try policies.first { $0.tools == .workspace }!
        let cwd = URL(filePath: "/tmp/w")
        let opened = adapter.newSession(cwd: cwd, servers: [], policy: policy, title: nil, instructions: "Be brief")
        let loaded = adapter.loadSession("s1", cwd: cwd, servers: [], policy: policy, instructions: "Be brief")
        #expect(opened["_meta"] == loaded["_meta"])
        #expect(loaded["_meta"]?["claudeCode"]?["options"]?["settingSources"] == [])
        #expect(loaded["_meta"]?["claudeCode"]?["options"]?["strictMcpConfig"] == true)
        // Bash goes through the broker on the contained path; Monitor never.
        #expect(loaded["_meta"]?["claudeCode"]?["options"]?["tools"]?.arrayValue?.contains("Bash") == true)
        #expect(loaded["_meta"]?["claudeCode"]?["options"]?["tools"]?.arrayValue?.contains("Monitor") == false)
        #expect(loaded["_meta"]?["claudeCode"]?["options"]?["disallowedTools"]?.arrayValue?.contains("Monitor") == true)
        #expect(loaded["_meta"]?["systemPrompt"] == "Be brief")
        let prepared = adapter.prepareSession("s1")
        #expect(prepared.map(\.method) == ["session/set_mode"] && prepared.first?.params["modeId"] == "default")
    }

    /// `agneta/appTools` `always` turns Claude Code's tool search off for the session (`options.env`, the same on every
    /// open) and drops ToolSearch, which would only load deferred tools; the built-ins are otherwise the policy's.
    /// Without it the options are as before. The other engines load the app's tools up front either way, but for Goose on
    /// a Claude plan, whose model is Claude Code (below).
    @Test func claudeCodeLoadsAppToolsUpFrontWhenAsked() throws {
        let adapter = ClaudeCodeAdapter(executable: URL(filePath: "/usr/bin/false"), cli: Self.cli)
        let cwd = URL(filePath: "/tmp/w")
        for var policy in try policies {
            let deferred = try #require(ClaudeCodeAdapter.tools(policy))
            #expect(deferred.contains("ToolSearch") && ClaudeCodeAdapter.environment(policy).isEmpty)
            let plain = adapter.newSession(cwd: cwd, servers: [], policy: policy, title: nil, instructions: nil)
            #expect(plain["_meta"]?["claudeCode"]?["options"]?["env"] == nil)
            #expect(adapter.appToolsUpfront(policy, kind: .claude) == false)

            policy.appTools = .always
            #expect(try #require(ClaudeCodeAdapter.tools(policy)) == deferred.filter { $0 != "ToolSearch" })
            let opened = adapter.newSession(cwd: cwd, servers: [], policy: policy, title: nil, instructions: nil)
            let loaded = adapter.loadSession("s1", cwd: cwd, servers: [], policy: policy, instructions: nil)
            #expect(opened["_meta"] == loaded["_meta"])
            #expect(loaded["_meta"]?["claudeCode"]?["options"]?["env"] == ["ENABLE_TOOL_SEARCH": "false"])
            #expect(adapter.appToolsUpfront(policy, kind: .anthropicKey) == true)
        }
        // Developer access keeps Claude Code's own tool set; the environment still turns tool search off.
        var developer = try #require(try policies.first { $0.tools == .workspace })
        developer.sandbox = .developer
        developer.appTools = .always
        #expect(ClaudeCodeAdapter.tools(developer) == nil)
        #expect(ClaudeCodeAdapter.environment(developer) == ["ENABLE_TOOL_SEARCH": "false"])
        let goose = GooseAdapter(executable: URL(filePath: "/usr/bin/false"))
        let others: [(any EngineAdapter, AccountKind)] = [
            (goose, .openAIKey), (goose, .anthropicKey),
            (OpenCodeAdapter(executable: URL(filePath: "/usr/bin/false")), .anthropicKey),
            (
                CodexAdapter(
                    node: URL(filePath: "/usr/bin/false"), script: URL(filePath: "/x/index.js"), cli: Self.cli),
                .chatGPT
            )
        ]
        for (engine, kind) in others {
            #expect(engine.appToolsUpfront(developer, kind: kind) == true, "\(engine.id) on \(kind)")
        }
        #expect(goose.appToolsUpfront(developer, kind: .claude) == true)
        developer.appTools = .engine
        #expect(goose.appToolsUpfront(developer, kind: .claude) == false)
    }

    /// Codex defers MCP tools on every model in its catalog; `always` names the app's servers as namespaces that bypass
    /// deferral (`features.code_mode.direct_only_tool_namespaces`), beside the shell's own settings, in CODEX_CONFIG.
    @Test func codexNamesTheAppsServersDirectWhenAsked() throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "agneta-contract-codex-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let adapter = CodexAdapter(
            node: URL(filePath: "/usr/bin/false"), script: URL(filePath: "/x/index.js"), cli: Self.cli)
        let servers: [JSONValue] = [["type": "http", "name": "app", "url": "http://127.0.0.1:1/mcp"]]
        func raw(_ policy: SessionPolicy, shell: URL?) throws -> String? {
            try adapter.launch(
                EngineLaunchContext(
                    home: home, provider: ProviderSetup(kind: .openAI, apiKey: "k"), shell: shell,
                    session: EngineSessionSpec(policy: policy, servers: servers, instructions: nil), loopbackPorts: [])
            ).environment["CODEX_CONFIG"]
        }
        func config(_ policy: SessionPolicy, shell: URL?) throws -> JSONValue? {
            try raw(policy, shell: shell).map { try JSONCoding.decode(Data($0.utf8)) }
        }
        var workspace = try #require(try policies.first { $0.tools == .workspace })
        let shell = URL(filePath: "/usr/bin/true")
        // Byte for byte what Agneta sent before `agneta/appTools`, contained and under developer access (web search on).
        #expect(try raw(workspace, shell: shell) == #"{"features":{"shell_tool":false,"unified_exec":false}}"#)
        var developer = workspace
        developer.sandbox = .developer
        #expect(
            try raw(developer, shell: shell)
                == #"{"features":{"shell_tool":false,"unified_exec":false},"web_search":"live"}"#)
        developer.appTools = .always
        #expect(
            try config(developer, shell: shell)
                == [
                    "features": [
                        "shell_tool": false, "unified_exec": false,
                        "code_mode": ["direct_only_tool_namespaces": ["mcp__app"]]
                    ],
                    "web_search": "live"
                ])
        #expect(try config(workspace, shell: nil) == nil)
        #expect(adapter.appToolsUpfront(workspace, kind: .openAIKey) == false)
        workspace.appTools = .always
        #expect(
            try config(workspace, shell: shell)
                == [
                    "features": [
                        "shell_tool": false, "unified_exec": false,
                        "code_mode": ["direct_only_tool_namespaces": ["mcp__app"]]
                    ]
                ])
        #expect(
            try config(workspace, shell: nil) == [
                "features": ["code_mode": ["direct_only_tool_namespaces": ["mcp__app"]]]
            ])
        #expect(adapter.appToolsUpfront(workspace, kind: .chatGPT) == true)
        // Named as Codex names a server's namespace (measured for `my-app` and `a.b`).
        #expect(
            ["app", "my-app", "a.b", "mcp__x", "", "é"].map(CodexAdapter.namespace(of:)) == [
                "mcp__app", "mcp__my_app", "mcp__a_b", "mcp__x", "mcp___", "mcp___"
            ])
        // The feature that would defer them anyway stays off.
        let toml = try String(contentsOf: home.appending(path: "codex/config.toml"), encoding: .utf8)
        #expect(toml.contains("code_mode_only_strict_3p_tools = false"))
    }

    /// Goose on a Claude plan runs Claude Code as its model (claude-acp), which inherits Goose's environment: `always`
    /// turns its tool search off there too, and nothing changes without it.
    @Test func gooseOnAPlanPassesToolSearchOffToClaudeCode() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agneta-contract-plan-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        let subscription = SubscriptionAccount(
            route: .claudeCode, home: root.appending(path: "account", directoryHint: .isDirectory))
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: subscription.claudeTemp)
        }
        let adapter = GooseAdapter(executable: URL(filePath: "/usr/bin/false"))
        var policy = try #require(try policies.first { $0.tools == .appOnly })
        func environment() throws -> [String: String] {
            try adapter.launch(
                EngineLaunchContext(
                    home: root.appending(path: "engine", directoryHint: .isDirectory),
                    provider: ProviderSetup(kind: .claudeCode, subscription: subscription), shell: nil,
                    session: EngineSessionSpec(policy: policy, servers: [], instructions: nil), loopbackPorts: [])
            ).environment
        }
        #expect(try environment()["GOOSE_PROVIDER"] == "claude-acp")
        #expect(try environment()["ENABLE_TOOL_SEARCH"] == nil)
        policy.appTools = .always
        #expect(try environment()["ENABLE_TOOL_SEARCH"] == "false")
    }

    /// Policies narrowed by `builtins`, at every tools level, contained and with developer access.
    func narrowed(_ builtins: [BuiltinGroup], tools: String = "workspace", developer: Bool = false) throws
        -> SessionPolicy
    {
        var policy = try SessionPolicy.parse(
            ["tools": .string(tools), "builtins": .array(builtins.map { .string($0.rawValue) })],
            cwd: FileManager.default.temporaryDirectory.path(percentEncoded: false), context: context)
        if developer { policy.sandbox = .developer }
        return policy
    }

    /// Every engine keeps to the contract under every narrowing it accepts: no more than the narrowed policy permits,
    /// no less than it promises. An engine that refuses one says why.
    @Test(arguments: engines) func everyEngineKeepsToANarrowing(engine: String) throws {
        let adapters: [String: any EngineAdapter] = [
            "goose": GooseAdapter(executable: URL(filePath: "/usr/bin/false")),
            "opencode": OpenCodeAdapter(executable: URL(filePath: "/usr/bin/false")),
            "claude-code": ClaudeCodeAdapter(executable: URL(filePath: "/usr/bin/false"), cli: Self.cli),
            "codex": CodexAdapter(
                node: URL(filePath: "/usr/bin/false"), script: URL(filePath: "/x/index.js"), cli: Self.cli)
        ]
        let adapter = try #require(adapters[engine])
        let kind: AccountKind = engine == "codex" ? .openAIKey : .anthropicKey
        let choices: [[BuiltinGroup]] = [
            [], [.read], [.read, .execute], [.read, .edit], [.read, .edit, .execute], [.skills], [.read, .skills],
            [.read, .edit, .skills], [.read, .execute, .skills], [.edit, .execute, .skills]
        ]
        for tools in ["app-only", "read", "workspace"] {
            for groups in choices {
                let policy = try narrowed(groups, tools: tools)
                let label = "\(engine) under \(tools) keeping \(groups.map(\.rawValue))"
                if let reason = adapter.builtinsRefusal(policy, kind: kind) {
                    #expect(!reason.isEmpty, "\(label)")
                    continue
                }
                let got = try offered(engine, policy)
                #expect(got.isSubset(of: BuiltinTools.permitted(by: policy)), "\(label) offers \(got)")
                #expect(BuiltinTools.promised(by: policy).isSubset(of: got), "\(label) lacks some of what it promises")
                let groups = try #require(adapter.builtinGroups(policy, kind: kind), "\(label)")
                #expect(groups.isSubset(of: policy.builtins!), "\(label) reports \(groups)")
            }
        }
    }

    /// Claude Code: a narrowing is the exact `tools` list, contained and under developer access alike; developer access
    /// keeps the account-reaching tools, Monitor and PowerShell out (`disallowedTools`), and ToolSearch follows
    /// `agneta/appTools`. The clean-room set (read, edit, execute) is what was measured on 2.1.326.
    @Test func claudeCodeOffersOnlyTheGroupsKept() throws {
        let adapter = ClaudeCodeAdapter(executable: URL(filePath: "/usr/bin/false"), cli: Self.cli)
        let developer = try narrowed([.read, .edit, .execute], developer: true)
        let exact = ["Read", "Glob", "Grep", "Edit", "Write", "NotebookEdit", "Bash", "TaskStop", "ToolSearch"]
        #expect(ClaudeCodeAdapter.tools(developer) == exact)
        let denied = ClaudeCodeAdapter.disallowed(developer)
        for tool in [
            "WebFetch", "WebSearch", "Agent", "Task", "Skill", "Workflow", "SendMessage", "Monitor", "PowerShell",
            "Artifact", "RemoteTrigger", "PushNotification", "CronCreate", "EnterWorktree"
        ] {
            #expect(denied.contains(tool), "\(tool)")
        }
        #expect(!denied.contains("Bash") && !denied.contains("Read"))
        #expect(adapter.builtinGroups(developer, kind: .claude) == [.read, .edit, .execute])
        var upfront = developer
        upfront.appTools = .always
        #expect(ClaudeCodeAdapter.tools(upfront) == exact.filter { $0 != "ToolSearch" })
        // Every group: still an allowlist, and still nothing that reaches the account or runs outside the broker.
        let all = try narrowed(BuiltinGroup.allCases, developer: true)
        let every = try #require(ClaudeCodeAdapter.tools(all))
        #expect(Set(["WebFetch", "WebSearch", "Agent", "Skill", "ExitPlanMode"]).isSubset(of: Set(every)))
        #expect(every.allSatisfy { BuiltinGroup.named[$0] != nil || BuiltinGroup.infrastructure.contains($0) })
        for tool in ["Monitor", "PowerShell", "Artifact", "SendUserFile"] {
            #expect(ClaudeCodeAdapter.disallowed(all).contains(tool) && !every.contains(tool))
        }
        // Contained: the policy's own set, less what's left out; nothing kept means only tool search.
        #expect(
            ClaudeCodeAdapter.tools(try narrowed([.read, .execute]))
                == ["Read", "Glob", "Grep", "ToolSearch", "Bash", "TaskStop"])
        #expect(ClaudeCodeAdapter.tools(try narrowed([.read, .edit, .execute, .subagents]))?.last == "Agent")
        #expect(ClaudeCodeAdapter.tools(try narrowed([])) == ["ToolSearch"])
        #expect(ClaudeCodeAdapter.tools(try narrowed([], developer: true)) == ["ToolSearch"])
        #expect(!ClaudeCodeAdapter.shellBrokered(try narrowed([.read, .edit])))
        // Kept groups beyond what a contained session gets add nothing.
        #expect(
            ClaudeCodeAdapter.tools(try narrowed(BuiltinGroup.allCases)) == ClaudeCodeAdapter.tools(try policies.last!))
        let opened = adapter.newSession(
            cwd: URL(filePath: "/tmp/w"), servers: [], policy: developer, title: nil, instructions: nil)
        let loaded = adapter.loadSession(
            "s1", cwd: URL(filePath: "/tmp/w"), servers: [], policy: developer, instructions: nil)
        #expect(opened["_meta"] == loaded["_meta"])
        #expect(loaded["_meta"]?["claudeCode"]?["options"]?["tools"] == .array(exact.map(JSONValue.string)))
    }

    /// Codex: each group left out is a setting off (measured on 0.167.0); the shell goes with `execute`; `apply_patch`
    /// can't be turned off, so workspace tools without `edit` are refused. No narrowing leaves the settings as they were.
    @Test func codexTurnsOffTheGroupsLeftOut() throws {
        let adapter = CodexAdapter(
            node: URL(filePath: "/usr/bin/false"), script: URL(filePath: "/x/index.js"), cli: Self.cli)
        let plain = try policies.last!
        #expect(CodexAdapter.overrides(plain) == #"{"features":{"shell_tool":false,"unified_exec":false}}"#)
        // An app-only session gets Codex's own shell off too (it had no settings, and Codex offered exec_command).
        let appOnlyHome = FileManager.default.temporaryDirectory.appending(
            path: "agneta-contract-apponly-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: appOnlyHome) }
        let appOnly = try adapter.launch(
            EngineLaunchContext(
                home: appOnlyHome, provider: ProviderSetup(kind: .openAI, apiKey: "k"),
                shell: URL(filePath: "/usr/bin/true"),
                session: EngineSessionSpec(policy: try policies.first!, servers: [], instructions: nil),
                loopbackPorts: []))
        #expect(appOnly.environment["CODEX_CONFIG"] == #"{"features":{"shell_tool":false,"unified_exec":false}}"#)
        #expect(appOnly.environment["AGNETA_SHELL"] == nil)
        // Reading files is its shell's: `read` without `execute` is refused, and not reported where there's no shell.
        #expect(adapter.builtinsRefusal(try narrowed([.read, .edit]), kind: .chatGPT) != nil)
        #expect(adapter.builtinsRefusal(try narrowed([.read], tools: "read"), kind: .chatGPT) != nil)
        #expect(adapter.builtinGroups(try policies.first!, kind: .chatGPT)?.contains(.read) == false)
        let kept = try narrowed([.read, .edit, .execute], developer: true)
        let config: JSONValue = try JSONCoding.decode(Data(try #require(CodexAdapter.overrides(kept)).utf8))
        #expect(config["web_search"] == "disabled" && config["agents"]?["enabled"] == false)
        #expect(config["features"]?["multi_agent"] == false && config["features"]?["goals"] == false)
        #expect(config["features"]?["sleep_tool"] == false && config["features"]?["shell_tool"] == false)
        #expect(config["features"]?["view_image"] == nil)
        #expect(config["skills"]?["bundled"]?["enabled"] == false)
        #expect(config["tools"]?["experimental_request_user_input"]?["enabled"] == false)
        #expect(adapter.builtinGroups(kept, kind: .chatGPT) == [.read, .edit, .execute])
        // One key-sorted object with `agneta/appTools`' direct namespaces, byte for byte.
        #expect(
            CodexAdapter.overrides(kept, shell: true, direct: ["mcp__app"])
                == #"{"agents":{"enabled":false},"features":{"code_mode":{"direct_only_tool_namespaces":["mcp__app"]},"#
                + #""goals":false,"multi_agent":false,"shell_tool":false,"sleep_tool":false,"unified_exec":false},"#
                + #""skills":{"bundled":{"enabled":false},"include_instructions":false},"#
                + #""tools":{"experimental_request_user_input":{"enabled":false}},"web_search":"disabled"}"#)
        // Without a broker (tests only: every Codex session has one) and without `builtins`, nothing, as before.
        #expect(CodexAdapter.overrides(plain, shell: false) == nil)
        let web: JSONValue = try JSONCoding.decode(
            Data(try #require(CodexAdapter.overrides(try narrowed([.read, .edit, .web], developer: true))).utf8))
        #expect(web["web_search"] == "live" && web["features"]?["view_image"] == nil)
        let none: JSONValue = try JSONCoding.decode(
            Data(try #require(CodexAdapter.overrides(try narrowed([], tools: "read"))).utf8))
        #expect(none["features"]?["view_image"] == false)
        #expect(adapter.builtinsRefusal(try narrowed([.read, .execute]), kind: .chatGPT) != nil)
        #expect(adapter.builtinsRefusal(try narrowed([.read, .execute], tools: "read"), kind: .chatGPT) == nil)
        // Without `execute`, Agneta's shell isn't offered, and the session is told nothing about it.
        let noShell = try narrowed([.read], tools: "read")
        #expect(!adapter.brokersShell(noShell))
        let home = FileManager.default.temporaryDirectory.appending(
            path: "agneta-contract-narrow-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let launch = try adapter.launch(
            EngineLaunchContext(
                home: home, provider: ProviderSetup(kind: .openAI, apiKey: "k"), shell: URL(filePath: "/usr/bin/true"),
                session: EngineSessionSpec(policy: noShell, servers: [], instructions: nil), loopbackPorts: []))
        #expect(launch.environment["AGNETA_SHELL"] == nil && launch.environment["CODEX_CONFIG"] != nil)
        let params = adapter.newSession(cwd: home, servers: [], policy: noShell, title: nil, instructions: nil)
        #expect(params["systemPrompt"] == nil)
    }

    /// Goose and OpenCode: the developer extension's tools and the permission rules, narrowed. Goose always offers its
    /// skills, and on a Claude plan runs Claude Code, so it refuses a narrowing there or without skills.
    @Test func brokeredEnginesNarrowTheirOwnTools() throws {
        let goose = GooseAdapter(executable: URL(filePath: "/usr/bin/false"))
        func available(_ policy: SessionPolicy) -> [String]? {
            GooseAdapter.extensions(servers: [], policy: policy).first { $0["name"]?.stringValue == "developer" }?[
                "available_tools"]?.arrayValue?.compactMap(\.stringValue)
        }
        #expect(available(try narrowed([.read, .edit, .skills])) == ["write", "edit", "tree", "read_image"])
        #expect(available(try narrowed([.execute, .skills], tools: "read")) == ["shell"])
        #expect(available(try narrowed([.skills])) == nil)
        // Reading files is the shell's: `tree` and `read_image` alone aren't reported as `read`, and are refused.
        #expect(goose.builtinGroups(try narrowed([.read, .skills]), kind: .openAIKey) == [.skills])
        #expect(
            goose.builtinGroups(try narrowed([.read, .execute, .skills]), kind: .openAIKey) == [
                .read, .execute, .skills
            ])
        #expect(goose.builtinsRefusal(try narrowed([.read, .edit, .skills]), kind: .openAIKey) != nil)
        #expect(goose.builtinsRefusal(try narrowed([.read, .skills], tools: "app-only"), kind: .openAIKey) == nil)
        #expect(goose.builtinGroups(try policies.first!, kind: .openAIKey) == [.skills])
        #expect(goose.builtinsRefusal(try narrowed([.read, .edit, .execute]), kind: .openAIKey) != nil)
        #expect(goose.builtinsRefusal(try narrowed([.read, .execute, .skills]), kind: .openAIKey) == nil)
        #expect(goose.builtinsRefusal(try narrowed(BuiltinGroup.allCases), kind: .claude) != nil)
        #expect(goose.builtinsRefusal(try policies.last!, kind: .claude) == nil)

        // A shared engine has no shell, so no reading either on Goose, with or without a narrowing.
        let read = try SessionPolicy.parse(
            ["tools": "read"], cwd: FileManager.default.temporaryDirectory.path(percentEncoded: false), context: context
        )
        #expect(Router.builtins(read, engine: goose, kind: .openAIKey, dedicated: false) == ["skills"])
        #expect(
            Router.builtins(read, engine: goose, kind: .openAIKey, dedicated: true) == ["read", "execute", "skills"])
        #expect(
            Router.builtins(try narrowed([.read, .execute, .skills]), engine: goose, kind: .openAIKey, dedicated: false)
                == ["skills"])

        let opencode = OpenCodeAdapter(executable: URL(filePath: "/usr/bin/false"))
        func open(_ policy: SessionPolicy) -> [String] {
            (OpenCodeAdapter.permissions(policy: policy, servers: []).arrayValue ?? []).dropFirst().compactMap {
                $0["action"]?.stringValue
            }
        }
        #expect(open(try narrowed([.read, .execute])) == ["read", "glob", "grep", "shell"])
        #expect(open(try narrowed([.edit])) == ["edit"])
        #expect(open(try narrowed([])) == [])
        #expect(opencode.builtinGroups(try narrowed([.read, .edit]), kind: .openAIKey) == [.read, .edit])
        #expect(opencode.builtinsRefusal(try narrowed([]), kind: .openAIKey) == nil)
    }

    /// `builtins` is a list of known groups, or absent; anything else is refused, naming the field. Native runners'
    /// requests outside the kept groups are refused, under developer access too, by name where known, else by kind.
    @Test func builtinsParseStrictlyAndAnswerNativeRunners() throws {
        let cwd = FileManager.default.temporaryDirectory.path(percentEncoded: false)
        #expect(try SessionPolicy.parse(["tools": "read"], cwd: cwd, context: context).builtins == nil)
        #expect(try SessionPolicy.parse(["builtins": []], cwd: cwd, context: context).builtins == [])
        #expect(
            try SessionPolicy.parse(["builtins": ["read", "web", "read"]], cwd: cwd, context: context).builtins
                == [.read, .web])
        for value: JSONValue in ["read", ["network"], ["Read"], [1], ["read", .null], ["read": true]] {
            do {
                _ = try SessionPolicy.parse(["builtins": value], cwd: cwd, context: context)
                Issue.record("\(value) was taken")
            } catch let rejection as PolicyRejection {
                #expect(rejection.field == "builtins", "\(value)")
                #expect(rejection.rpcError.data?["agneta"]?["unenforceable"] == ["builtins"])
            }
        }
        let developer = try narrowed([.read, .edit, .execute], developer: true)
        func may(_ kind: String?, _ tool: String?, _ policy: SessionPolicy) -> Bool {
            BuiltinTools.nativeRunnerMayUse(kind: kind, tool: tool, policy: policy, brokered: true)
        }
        #expect(may("execute", "Bash", developer) && may("edit", "Write", developer) && may("read", nil, developer))
        #expect(may("other", "ToolSearch", developer))
        #expect(!may("fetch", "WebFetch", developer) && !may("fetch", nil, developer))
        #expect(!may("think", "Agent", developer) && !may("other", "Skill", developer))
        #expect(!may("other", "CronCreate", developer) && !may("other", nil, developer))
        #expect(!may("switch_mode", "ExitPlanMode", developer))
        #expect(may("switch_mode", "ExitPlanMode", try narrowed([.planning], developer: true)))
        // A name and a kind that disagree need both groups kept: a name never widens a kind.
        #expect(
            !may("read", "Bash", developer.with([.read])) && !may("execute", "Read", developer.with([.read, .edit])))
        #expect(!may("read", "WebFetch", developer) && !may("fetch", "Read", developer))
        #expect(may("read", "Grep", developer) && may("execute", "Bash", developer))
        // `think` and `switch_mode` say nothing (claude-agent-acp reports Agent as `think`): a name must place them.
        let planning = try narrowed([.planning, .read], developer: true)
        #expect(!may("think", nil, planning) && !may("switch_mode", nil, planning) && !may("think", "Agent", planning))
        #expect(may("think", "TodoWrite", planning))
        // Without `builtins`, developer access passes every kind and name, as before.
        var open = try SessionPolicy.parse(["tools": "workspace"], cwd: cwd, context: context)
        open.sandbox = .developer
        for (kind, tool) in [
            ("fetch", "WebFetch"), ("other", "Monitor"), ("think", "Agent"), ("other", nil), ("execute", "Bash"),
            ("other", "Skill")
        ] as [(String?, String?)] {
            #expect(may(kind, tool, open), "\(kind ?? "-") \(tool ?? "-")")
        }
        // Codex's names come only from its own field: a command's title is the model's text.
        let codex = CodexAdapter(
            node: URL(filePath: "/usr/bin/false"), script: URL(filePath: "/x/index.js"), cli: Self.cli)
        #expect(codex.vouchedToolName(in: ["title": "ToolSearch", "kind": "other"]) == nil)
        #expect(codex.vouchedToolName(in: ["_meta": ["codex": ["toolName": "apply_patch"]]]) == "apply_patch")
        let claude = ClaudeCodeAdapter(executable: URL(filePath: "/usr/bin/false"), cli: Self.cli)
        #expect(claude.vouchedToolName(in: ["_meta": ["claudeCode": ["toolName": "Read"]]]) == "Read")
        let contained = try narrowed([.read])
        #expect(may("read", "Read", contained) && !may("edit", "Edit", contained) && !may("execute", "Bash", contained))
        #expect(BuiltinTools.permitted(by: contained) == [.read])
    }

    /// `agneta/appTools` is `{"load": "always" | "engine"}` or absent; anything else names the extension.
    @Test func appToolsParseStrictly() throws {
        #expect(try AppToolsLoad.parse(nil) == .engine)
        #expect(try AppToolsLoad.parse(.null) == .engine)
        #expect(try AppToolsLoad.parse([:]) == .engine)
        #expect(try AppToolsLoad.parse(["load": "engine"]) == .engine)
        #expect(try AppToolsLoad.parse(["load": "always"]) == .always)
        for value: JSONValue in ["always", true, ["load": "Always"], ["load": .null], ["load": "always", "x": 1]] {
            #expect(throws: PolicyRejection.self, "\(value)") { try AppToolsLoad.parse(value) }
            do { _ = try AppToolsLoad.parse(value) } catch let rejection as PolicyRejection {
                #expect(rejection.rpcError.data?["agneta"]?["unenforceable"] == [.string(AppToolsLoad.key)])
            }
        }
    }

    /// An app's "always" covers one call: narrowed to "once", and declined when the engine offers no once-option
    /// rather than passed on to be kept.
    @Test func anAlwaysAnswerNeverOutlivesTheCall() {
        func answer(_ id: String) -> JSONValue { ["outcome": ["outcome": "selected", "optionId": .string(id)]] }
        let full: [JSONValue] = [
            ["optionId": "a", "kind": "allow_always"], ["optionId": "o", "kind": "allow_once"],
            ["optionId": "r", "kind": "reject_once"]
        ]
        #expect(Router.onlyOnce(answer("a"), options: full)["outcome"]?["optionId"]?.stringValue == "o")
        let noOnce: [JSONValue] = [["optionId": "a", "kind": "allow_always"], ["optionId": "r", "kind": "reject_once"]]
        #expect(Router.onlyOnce(answer("a"), options: noOnce)["outcome"]?["optionId"]?.stringValue == "r")
        #expect(
            Router.onlyOnce(answer("a"), options: [["optionId": "a", "kind": "allow_always"]])["outcome"]?["outcome"]?
                .stringValue == "cancelled")
        #expect(Router.onlyOnce(answer("o"), options: full)["outcome"]?["optionId"]?.stringValue == "o")
    }

    /// Codex's own settings keep out what no policy could refuse: web search on OpenAI's servers, and the features
    /// that bring tools of their own.
    @Test func codexIsConfiguredWithinThePolicy() throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "agneta-codex-config-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        try CodexAdapter.writeConfig(home)
        let config = try String(contentsOf: home.appending(path: "config.toml"), encoding: .utf8)
        #expect(config.contains("web_search = \"disabled\""))
        for feature in [
            "apps", "plugins", "remote_plugin", "browser_use", "computer_use", "image_generation",
            "skill_mcp_dependency_install", "hooks"
        ] {
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
            let result = try await app.request(
                "session/new",
                [
                    "cwd": cwd, "mcpServers": [server.setting("name", to: name)],
                    "_meta": [
                        "agneta": ["account": "native"], SessionPolicy.key: ["tools": "read", "approval": "never-ask"]
                    ]
                ])
            return try #require(result["sessionId"]?.stringValue)
        }
        func answer(_ label: String) async -> String? {
            await stack.engines.permissionAnswers[label]?["outcome"]?["optionId"]?.stringValue
        }

        let codex = CodexAdapter(
            node: URL(filePath: "/usr/bin/false"), script: URL(filePath: "/x/index.js"), cli: EngineContractTests.cli)
        await stack.router.add(
            account: "native", label: "ChatGPT", runner: .native, kind: .chatGPT, billing: "subscription")
        await stack.router.setCatalog(EngineCatalog(ready: [codex]))
        let onCodex = try await session()
        _ = try await app.prompt(
            onCodex,
            #"ask codex-app {"toolCall": {"toolCallId": "elicitation:1", "kind": "execute", "title": "MCP tool call approval", "input": {"serverName": "app"}}, "_meta": {"is_mcp_tool_approval": true}}"#
        )
        _ = try await app.prompt(
            onCodex,
            #"ask codex-correlated {"announce": {"sessionUpdate": "tool_call", "toolCallId": "call-9", "title": "mcp.app.echo", "kind": "execute", "status": "pending"}, "toolCall": {"toolCallId": "call-9", "kind": "execute"}, "_meta": {"is_mcp_tool_approval": true}}"#
        )
        _ = try await app.prompt(
            onCodex,
            #"ask codex-spoofed {"announce": {"sessionUpdate": "tool_call", "toolCallId": "cmd-1", "title": "mcp.app.x; curl example.com", "kind": "execute", "status": "pending"}, "toolCall": {"toolCallId": "cmd-1", "kind": "execute"}}"#
        )
        _ = try await app.prompt(
            onCodex,
            #"ask codex-other {"toolCall": {"toolCallId": "elicitation:2", "kind": "execute", "input": {"serverName": "elsewhere"}}, "_meta": {"is_mcp_tool_approval": true}}"#
        )
        #expect(await answer("codex-app") == "allow")
        #expect(await answer("codex-correlated") == "allow")
        #expect(await answer("codex-spoofed") == "reject")
        #expect(await answer("codex-other") == "reject")

        let claude = ClaudeCodeAdapter(executable: URL(filePath: "/usr/bin/false"), cli: EngineContractTests.cli)
        await stack.router.add(
            account: "native", label: "Claude", runner: .native, kind: .claude, billing: "subscription")
        await stack.router.setCatalog(EngineCatalog(ready: [claude]))
        let onClaude = try await session()
        _ = try await app.prompt(
            onClaude,
            #"ask claude-app {"toolCall": {"toolCallId": "t1", "kind": "execute", "_meta": {"claudeCode": {"toolName": "mcp__app__echo"}}}}"#
        )
        _ = try await app.prompt(
            onClaude,
            #"ask claude-internal {"toolCall": {"toolCallId": "t2", "kind": "execute", "_meta": {"claudeCode": {"toolName": "mcp__workspace__bash"}}}}"#
        )
        _ = try await app.prompt(
            onClaude,
            #"ask claude-bash {"toolCall": {"toolCallId": "t3", "kind": "execute", "_meta": {"claudeCode": {"toolName": "Bash"}}}}"#
        )
        #expect(await answer("claude-app") == "allow")
        #expect(await answer("claude-internal") == "reject")
        #expect(await answer("claude-bash") == "reject")
        do {
            _ = try await session(named: "workspace")
            Issue.record("an app server took Claude Code's own server name")
        } catch let error as RPCError {
            #expect(
                error.code == RPCError.invalidParams
                    && error.data?["agneta"]?["unenforceable"]?.arrayValue?.first?.stringValue == "mcpServers")
        }
    }
}

extension SessionPolicy {
    /// The same policy keeping other groups.
    fileprivate func with(_ builtins: Set<BuiltinGroup>) -> SessionPolicy {
        var policy = self
        policy.builtins = builtins
        return policy
    }
}
