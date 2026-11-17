// Codex behind the engine boundary: the user's own Codex (`codex app-server`,
// found by CLILocator) driven through `codex-acp` (Apache-2.0, bundled) on a
// bundled Node. Each account has its own CODEX_HOME with Agneta's config.toml
// (credentials in a file, analytics, feedback and update checks off). Codex
// runs inside Agneta's sandbox like every engine, which keeps reads and writes
// to the session's folders; Agneta answers its permission requests from the
// policy (native runner). docs/ENGINES.md.
import Foundation

public struct CodexAdapter: EngineAdapter {
    public let node: URL
    /// codex-acp's `dist/index.js`.
    public let script: URL
    /// The user's Codex.
    public let cli: InstalledCLI

    public init(node: URL, script: URL, cli: InstalledCLI) {
        self.node = node
        self.script = script
        self.cli = cli
    }

    public var id: String { "codex" }
    public var displayName: String { "Codex" }
    public var capabilities: EngineCapabilities {
        EngineCapabilities(steer: true, fork: false, instructionsBetweenTurns: false, processPerSession: true, reportsCost: false)
    }

    /// The account's Codex home: its sign-in and sessions.
    public static func codexHome(account home: URL) -> URL { home.appending(path: "codex", directoryHint: .isDirectory) }

    /// Agneta's settings for a Codex home; written before sign-in and every launch.
    public static func writeConfig(_ codexHome: URL) throws {
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let toml = """
        # Written by Agneta for this account; changes are replaced at the next start.
        cli_auth_credentials_store = "file"
        check_for_update_on_startup = false
        # Searched on OpenAI's servers without a permission request, so no policy could refuse it.
        web_search = "disabled"

        # Tools beyond the policy, which Agneta isn't asked about and Codex's sandbox can't confine inside Agneta's:
        # the ChatGPT account's connectors, plugins, the browser and the computer, image generation, installs, a
        # background daemon and hooks. Its shell, edits and the app's MCP tools stay.
        [features]
        apps = false
        plugins = false
        remote_plugin = false
        plugin_discovery_prefetch = false
        plugin_sharing = false
        browser_use = false
        browser_use_external = false
        browser_use_full_cdp_access = false
        in_app_browser = false
        computer_use = false
        image_generation = false
        skill_mcp_dependency_install = false
        tool_suggest = false
        daemon_auto_start = false
        hooks = false

        [analytics]
        enabled = false

        [feedback]
        enabled = false

        [sandbox_workspace_write]
        network_access = false

        """
        try toml.write(to: codexHome.appending(path: "config.toml"), atomically: true, encoding: .utf8)
    }

    public func launch(_ context: EngineLaunchContext) throws -> EngineLaunch {
        let home = context.home
        let temporary = home.appending(path: "tmp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let codexHome: URL
        var writable: [URL] = []
        var environment: [String: String] = [
            "HOME": home.path(percentEncoded: false), "TMPDIR": temporary.path(percentEncoded: false),
            "PATH": [node.deletingLastPathComponent().path(percentEncoded: false), "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":"),
            "LANG": "en_US.UTF-8", "USER": NSUserName(), "LOGNAME": NSUserName(),
            "CODEX_PATH": cli.path.path(percentEncoded: false), "NO_BROWSER": "1",
        ]
        switch context.provider.kind {
        case .chatGPT:
            guard let subscription = context.provider.subscription else { throw RPCError(code: RPCError.internalError, message: "The account has no sign-in") }
            codexHome = Self.codexHome(account: subscription.home)
            writable.append(codexHome) // Codex refreshes its sign-in and keeps sessions there
        case .openAI:
            codexHome = home.appending(path: "codex", directoryHint: .isDirectory)
            environment["OPENAI_API_KEY"] = context.provider.apiKey ?? ""
            environment["CODEX_API_KEY"] = context.provider.apiKey ?? ""
        case .anthropic, .claudeCode:
            throw RPCError(code: RPCError.invalidParams, message: "Codex serves ChatGPT and OpenAI accounts")
        }
        try Self.writeConfig(codexHome)
        environment["CODEX_HOME"] = codexHome.path(percentEncoded: false)
        // Codex's own modes (never codex-acp's default, `agent`). Its inner sandbox can't nest inside Agneta's, which
        // does the confining: measured, Codex runs shell commands without asking, and they fail with "sandbox_apply:
        // Operation not permitted" without a tool call; edits ask first and work.
        environment["INITIAL_AGENT_MODE"] = context.session?.policy.tools == .workspace ? "workspace-write" : "read-only"
        let readable = [node.deletingLastPathComponent().deletingLastPathComponent(), script.deletingLastPathComponent().deletingLastPathComponent(),
                        cli.path.deletingLastPathComponent().deletingLastPathComponent()]
        return EngineLaunch(executable: node, arguments: [script.path(percentEncoded: false)], environment: environment,
                            writable: writable, readable: readable, stateRoot: codexHome)
    }

    public func newSession(cwd: URL, servers: [JSONValue], policy: SessionPolicy, title: JSONValue?, instructions: String?) -> JSONValue {
        var params: JSONValue = ["cwd": .string(cwd.path(percentEncoded: false)), "mcpServers": .array(servers)]
        // Measured: an object with `mode` ("append" or "override"). Appended: Codex's own base instructions say
        // how to use its tools, and replacing them would cripple it.
        if let instructions {
            params = params.setting("systemPrompt", to: ["mode": "append", "content": [["type": "text", "text": .string(instructions)]], "text": .string(instructions)])
        }
        return params
    }

    public func loadSession(_ engineSession: String, cwd: URL, servers: [JSONValue], policy: SessionPolicy) -> JSONValue {
        ["sessionId": .string(engineSession), "cwd": .string(cwd.path(percentEncoded: false)), "mcpServers": .array(servers)]
    }

    public func setInstructions(_ engineSession: String, text: String, appendKey: String?) -> EngineRequest? { nil }

    /// Agneta gates every call from Codex's questions. Full access and custom permission profiles stop asking, and
    /// `agent` ("Auto review") hands the questions to Codex's own model reviewer, which could let a command run
    /// outside Codex's sandbox without Agneta seeing it.
    public func permitsMode(_ mode: String) -> Bool { ["read-only", "workspace-write"].contains(mode) }

    public func steer(_ engineSession: String, run: String?, prompt: JSONValue) -> EngineRequest? {
        EngineRequest("_session/steering", ["sessionId": .string(engineSession), "prompt": prompt])
    }

    public func steerResult(_ result: JSONValue) -> (accepted: Bool, run: String?) {
        (result["outcome"]?.stringValue.map { $0 != "promptRequired" } ?? true, nil)
    }

    public func activeRun(in update: JSONValue) -> String?? { nil }

    /// Measured: an app's tool is `mcp.<server>.<tool>`; built-ins by their own name.
    public func toolIdentity(in update: JSONValue) -> (tool: String?, server: String?, message: String?) {
        guard let name = update["_meta"]?["codex"]?["toolName"]?.stringValue ?? update["name"]?.stringValue ?? update["title"]?.stringValue else { return (nil, nil, nil) }
        let parts = name.split(separator: ".", maxSplits: 2).map(String.init)
        if parts.count == 3, parts[0] == "mcp" { return (parts[2], parts[1], nil) }
        return (name, nil, nil)
    }

    /// Codex asks before an MCP tool call through an elicitation, which codex-acp turns into a permission request of
    /// kind `execute` marked `is_mcp_tool_approval`, with the server's name or only the call's id. Nothing else
    /// counts: a command's title is the command, which the model writes, so a title like `mcp.app.x` proves nothing.
    public func permissionServer(_ params: JSONValue?, calls: [String: String]) -> String? {
        guard params?["_meta"]?["is_mcp_tool_approval"]?.boolValue == true else { return nil }
        return params?["toolCall"]?["input"]?["serverName"]?.stringValue
            ?? params?["toolCall"]?["toolCallId"]?.stringValue.flatMap { calls[$0] }
    }

    /// The connectors server Codex can bring for ChatGPT accounts.
    public var reservedToolServers: Set<String> { ["codex_apps"] }

    public func exportSession(_ engineSession: String) -> EngineRequest? { nil }
    public func importSession(_ exported: JSONValue) -> EngineRequest? { nil }
    public func importedSession(_ result: JSONValue) -> String? { nil }
    public func ledger(stateRoot: URL, engineSession: String) -> (any UsageLedger)? {
        CodexRolloutLedger(codexHome: stateRoot, session: engineSession)
    }
}
