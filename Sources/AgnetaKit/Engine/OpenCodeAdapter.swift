// OpenCode behind the engine boundary (v2.3.0, pinned in Engines/opencode.lock;
// source read in docs/ENGINES.md). OpenCode reads its whole
// configuration per process and its ACP bridge passes no per-session settings,
// so every session gets its own process, configured at launch: an `agneta`
// agent whose system prompt is the session's instructions, permission rules
// from the session policy, the app's MCP servers with Code Mode off, and
// everything that would reach beyond the session turned off.
import Foundation

public struct OpenCodeAdapter: EngineAdapter {
    public let executable: URL
    public init(executable: URL) { self.executable = executable }

    public var id: String { "opencode" }
    public var displayName: String { "OpenCode" }
    public var capabilities: EngineCapabilities {
        // Steering over ACP (`_session/steering`). Instructions and fork need OpenCode's HTTP API, which its
        // ACP bridge keeps private; until Agneta talks to it, they're not offered.
        EngineCapabilities(steer: true, fork: false, instructionsBetweenTurns: false, processPerSession: true)
    }

    static let agent = "agneta"

    public func launch(_ context: EngineLaunchContext) throws -> EngineLaunch {
        let home = context.home
        let folders = ["config", "data", "state", "cache", "tmp", "opencode"].map {
            home.appending(path: $0, directoryHint: .isDirectory)
        }
        for folder in folders {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let stateRoot = home.appending(path: "opencode", directoryHint: .isDirectory)
        let config = Self.configuration(provider: context.provider, session: context.session, shell: context.shell)
        var text = ""
        TraceJSON.encode(config, into: &text)
        var environment: [String: String] = [
            "HOME": home.path(percentEncoded: false),
            "XDG_CONFIG_HOME": folders[0].path(percentEncoded: false),
            "XDG_DATA_HOME": folders[1].path(percentEncoded: false),
            "XDG_STATE_HOME": folders[2].path(percentEncoded: false),
            "XDG_CACHE_HOME": folders[3].path(percentEncoded: false),
            "TMPDIR": folders[4].path(percentEncoded: false),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            // The whole configuration, and nothing from the user's own setup or the project.
            "OPENCODE_CONFIG_CONTENT": text,
            "OPENCODE_DISABLE_PROJECT_CONFIG": "1", "OPENCODE_DISABLE_CLAUDE_CODE": "1",
            // No network beyond the provider: the bundled model catalogue, no updates, no file watching.
            "OPENCODE_DISABLE_MODELS_FETCH": "1", "OPENCODE_DISABLE_AUTOUPDATE": "1",
            "OPENCODE_DISABLE_FILEWATCHER": "1",
            "OPENCODE_DB": stateRoot.appending(path: "opencode.db").path(percentEncoded: false)
        ]
        switch context.provider.kind {
        case .openAI: if let key = context.provider.apiKey { environment["OPENAI_API_KEY"] = key }
        case .anthropic: if let key = context.provider.apiKey { environment["ANTHROPIC_API_KEY"] = key }
        case .chatGPT, .claudeCode:
            throw RPCError(
                code: RPCError.invalidParams,
                message: "OpenCode in Agneta serves API-key accounts; plans run on Claude Code, Codex or Goose")
        }
        // `opencode acp` starts a private `opencode serve` on loopback and talks to it (measured: without
        // listening there it exits with "Standalone server exited before reporting readiness").
        return EngineLaunch(
            executable: executable, arguments: ["acp"], environment: environment, writable: [],
            readable: [executable.deletingLastPathComponent()], stateRoot: stateRoot, ownLoopbackServer: true)
    }

    /// OpenCode's v2 configuration for one session.
    static func configuration(provider: ProviderSetup, session: EngineSessionSpec?, shell: URL?) -> JSONValue {
        var config: [String: JSONValue] = [
            "update": "disable", "share": "disabled", "snapshots": false, "lsp": false, "formatter": false,
            "plugins": []
        ]
        // The provider: OpenCode's own for OpenAI and Anthropic keys; an OpenAI-compatible one for a base URL.
        let model: String
        switch provider.kind {
        case .anthropic where provider.baseURL == nil:
            model = "anthropic/\(provider.model ?? "claude-sonnet-5-5")"
        case .openAI where provider.baseURL == nil:
            model = "openai/\(provider.model ?? "gpt-6.1-sol")"
        default:
            let id = provider.model ?? "default"
            config["providers"] = [
                "agneta": [
                    "package": "@ai-sdk/openai-compatible", "name": "Agneta",
                    "settings": ["baseURL": .string(provider.baseURL ?? ""), "apiKey": .string(provider.apiKey ?? "")],
                    "models": .object([id: ["name": .string(id)]])
                ]
            ]
            model = "agneta/\(id)"
        }
        config["model"] = .string(model)

        guard let session else { return .object(config) }
        // The app's tool servers, called directly (not through Code Mode), each by the app's own name.
        var servers: [String: JSONValue] = [:]
        for server in session.servers {
            guard let name = server["name"]?.stringValue, let url = server["url"] else { continue }
            var headers: [String: JSONValue] = [:]
            for header in server["headers"]?.arrayValue ?? [] {
                if let key = header["name"]?.stringValue { headers[key] = header["value"] ?? "" }
            }
            servers[name] = [
                "type": "remote", "url": url, "headers": .object(headers), "oauth": false, "codemode": false
            ]
        }
        config["mcp"] = ["servers": .object(servers)]
        if let shell { config["shell"] = .string(shell.path(percentEncoded: false)) }
        let rules = permissions(policy: session.policy, servers: Array(servers.keys).sorted())
        config["permissions"] = rules
        config["agents"] = .object([
            agent: [
                "system": .string(
                    session.instructions ?? "You help with the task you're given, using the tools you have."),
                "permissions": rules, "mode": "primary"
            ],
            // OpenCode otherwise spends a model call naming each session, on the user's account (measured).
            "title": ["disabled": true]
        ])
        return .object(config)
    }

    /// The policy as OpenCode rules (the last matching rule wins; nothing matching means ask):
    /// deny everything, then allow what the policy allows, asking the app when it wants to decide.
    static func permissions(policy: SessionPolicy, servers: [String]) -> JSONValue {
        let decide: JSONValue = policy.approval == .neverAsk ? "allow" : "ask"
        // Measured on 2.3.0: the blanket deny removes OpenCode's tools from the model's list (an app-only session
        // has no shell), except `skill` and, in editing sessions, `opencode_worktree_remove`, which ignore
        // permission rules. Skills come only from the private home, where there are none, and the sandbox
        // keeps worktree changes inside the workspace.
        var rules: [JSONValue] = [["action": "*", "resource": "*", "effect": "deny"]]
        for server in servers { rules.append(["action": .string("\(server)_*"), "resource": "*", "effect": decide]) }
        if policy.tools != .appOnly {
            for action in ["read", "glob", "grep"] {
                rules.append(["action": .string(action), "resource": "*", "effect": "allow"])
            }
        }
        if policy.tools == .workspace {
            for action in ["edit", "shell"] {
                rules.append(["action": .string(action), "resource": "*", "effect": decide])
            }
        }
        return .array(rules)
    }

    public func newSession(
        cwd: URL, servers: [JSONValue], policy: SessionPolicy, title: JSONValue?, instructions: String?
    ) -> JSONValue {
        // The servers are in the process's configuration (with Code Mode off), not registered per folder.
        ["cwd": .string(cwd.path(percentEncoded: false)), "mcpServers": []]
    }

    public func loadSession(_ engineSession: String, cwd: URL, servers: [JSONValue], policy: SessionPolicy) -> JSONValue
    {
        ["sessionId": .string(engineSession), "cwd": .string(cwd.path(percentEncoded: false)), "mcpServers": []]
    }

    /// The session stays in Agneta's agent: another (OpenCode's own build or plan) would drop the session's instructions
    /// and bring its own behaviour.
    public func permitsMode(_ mode: String) -> Bool { mode == Self.agent }

    /// The session runs as Agneta's agent, which carries its instructions and rules.
    public func prepareSession(_ engineSession: String) -> [EngineRequest] {
        [
            EngineRequest(
                "session/set_config_option",
                ["sessionId": .string(engineSession), "configId": "mode", "value": .string(Self.agent)])
        ]
    }

    public func setInstructions(_ engineSession: String, text: String, appendKey: String?) -> EngineRequest? { nil }

    public func steer(_ engineSession: String, run: String?, prompt: JSONValue) -> EngineRequest? {
        EngineRequest("_session/steering", ["sessionId": .string(engineSession), "prompt": prompt])
    }

    /// `{outcome: "injected"}`, or `{outcome: "promptRequired", reason: "noRunningTurn"}`.
    public func steerResult(_ result: JSONValue) -> (accepted: Bool, run: String?) {
        (result["outcome"]?.stringValue == "injected", nil)
    }

    public func activeRun(in update: JSONValue) -> String?? { nil }

    /// OpenCode sends every MCP tool with each request (measured on 2.3.0): `agneta/appTools` changes nothing here.
    public func appToolsUpfront(_ policy: SessionPolicy) -> Bool? { true }

    /// OpenCode names an MCP tool `<server>_<tool>` (measured: `app_echo`) and its own tools without a server.
    public func toolIdentity(in update: JSONValue) -> (tool: String?, server: String?, message: String?) {
        guard let name = update["name"]?.stringValue else { return (nil, nil, nil) }
        if !name.hasPrefix("opencode_"), let split = name.firstIndex(of: "_") {
            return (String(name[name.index(after: split)...]), String(name[..<split]), nil)
        }
        return (name, nil, nil)
    }

    public func exportSession(_ engineSession: String) -> EngineRequest? { nil }
    public func importSession(_ exported: JSONValue) -> EngineRequest? { nil }
    public func importedSession(_ result: JSONValue) -> String? { nil }

    public func ledger(stateRoot: URL, engineSession: String) -> (any UsageLedger)? {
        OpenCodeLedgerReader(database: stateRoot.appending(path: "opencode.db"), session: engineSession)
    }
}
