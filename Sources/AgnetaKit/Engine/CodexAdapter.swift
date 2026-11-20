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
        EngineCapabilities(
            steer: true, fork: false, instructionsBetweenTurns: false, processPerSession: true, cost: .none,
            runsOwnTools: true)
    }

    /// The account's Codex home: its sign-in and sessions.
    public static func codexHome(account home: URL) -> URL {
        home.appending(path: "codex", directoryHint: .isDirectory)
    }

    /// Agneta's settings for a Codex home; written before sign-in and every launch.
    public static func writeConfig(_ codexHome: URL, shell: URL? = nil) throws {
        try FileManager.default.createDirectory(
            at: codexHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let toml = """
            # Written by Agneta for this account; changes are replaced at the next start.
            # The sign-in in the login Keychain ("Codex Auth", keyed by this folder), never a file here: everything in this
            # folder is readable inside the engine's sandbox, where Codex's own tools read files.
            cli_auth_credentials_store = "keyring"
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
            # Off by default; pinned so they stay off: memories would carry one task into another's, and compressed
            # rollouts (.jsonl.zst) would escape Agneta's deletion and usage reading, which read .jsonl.
            memories = false
            local_thread_store_compression = false

            [analytics]
            enabled = false

            [feedback]
            enabled = false

            [sandbox_workspace_write]
            network_access = false

            """
        let file = codexHome.appending(path: "config.toml")
        // Without a shell (sign-in), the one the last launch wrote stays: it's the account's, and the only way in.
        var info = stat()
        let regular = lstat(file.path(percentEncoded: false), &info) == 0 && info.st_mode & S_IFMT == S_IFREG
        let kept =
            shell == nil && regular
            ? (try? String(contentsOf: file, encoding: .utf8)).flatMap { old in
                old.range(of: shellServerHeader).map { String(old[$0.lowerBound...]) }
            } : nil
        try (toml + (shell.map(Self.shellServerConfig) ?? kept ?? "")).write(
            to: file, atomically: true, encoding: .utf8)
    }

    public func launch(_ context: EngineLaunchContext) throws -> EngineLaunch {
        let home = context.home
        let temporary = home.appending(path: "tmp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let codexHome: URL
        var writable: [URL] = []
        var keychains = false
        var environment: [String: String] = [
            "HOME": home.path(percentEncoded: false), "TMPDIR": temporary.path(percentEncoded: false),
            "PATH": [
                node.deletingLastPathComponent().path(percentEncoded: false), "/usr/bin", "/bin", "/usr/sbin", "/sbin"
            ].joined(separator: ":"),
            "LANG": "en_US.UTF-8", "USER": NSUserName(), "LOGNAME": NSUserName(),
            "CODEX_PATH": cli.path.path(percentEncoded: false), "NO_BROWSER": "1"
        ]
        switch context.provider.kind {
        case .chatGPT:
            guard let subscription = context.provider.subscription else {
                throw RPCError(code: RPCError.internalError, message: "The account has no sign-in")
            }
            codexHome = try OwnFolder.ensure(
                Self.codexHome(account: subscription.home), under: subscription.home.deletingLastPathComponent())
            writable.append(codexHome) // Codex keeps its sessions there
            // The sign-in is in the login Keychain (keyring mode), reached through $HOME/Library/Keychains, as for Claude Code.
            try ClaudeCodeSignIn.linkKeychains(into: home)
            keychains = true
        case .openAI:
            codexHome = try OwnFolder.ensure(
                home.appending(path: "codex", directoryHint: .isDirectory), under: home.deletingLastPathComponent())
            environment["OPENAI_API_KEY"] = context.provider.apiKey ?? ""
            environment["CODEX_API_KEY"] = context.provider.apiKey ?? ""
        case .anthropic, .claudeCode:
            throw RPCError(code: RPCError.invalidParams, message: "Codex serves ChatGPT and OpenAI accounts")
        }
        Self.clearTrusted(codexHome)
        try Self.writeConfig(codexHome, shell: context.shell)
        environment["CODEX_HOME"] = codexHome.path(percentEncoded: false)
        // Codex's own modes (never codex-acp's default, `agent`). Its inner sandbox can't nest inside Agneta's, which
        // does the confining: measured, Codex runs shell commands without asking, and they fail with "sandbox_apply:
        // Operation not permitted" without a tool call; edits ask first and work.
        environment["INITIAL_AGENT_MODE"] =
            context.session?.policy.tools == .workspace ? "workspace-write" : "read-only"
        // Codex's own command tools off, Agneta's shell instead: the server in config.toml offers its tool to this
        // process only (AGNETA_SHELL), running in the session's workspace through this engine's broker token.
        if context.shell != nil, let policy = context.session?.policy, brokersShell(policy) {
            // Web search runs on OpenAI's servers, which no sandbox reaches: on under developer access, as in Codex
            // itself; off when contained (the account's config.toml has it off).
            environment["CODEX_CONFIG"] =
                policy.sandbox == .developer
                ? #"{"features":{"shell_tool":false,"unified_exec":false},"web_search":"live"}"#
                : #"{"features":{"shell_tool":false,"unified_exec":false}}"#
            environment["AGNETA_SHELL"] = "1"
            environment["AGNETA_SHELL_CWD"] = policy.workspace.path(percentEncoded: false)
        }
        // Developer access: its commands run as in a terminal, through Agneta's shell in the widened profile, finding the
        // user's toolchains. The mode stays one that asks before edits, so an app that answers permissions is asked.
        if context.session?.policy.sandbox == .developer {
            environment.merge(
                DeveloperAccess.environment(
                    home: FileManager.default.homeDirectoryForCurrentUser,
                    caches: context.session!.policy.caches(
                        scratch: context.home.appending(path: "scratch", directoryHint: .isDirectory)))
            ) { _, user in user }
            environment["PATH"] =
                node.deletingLastPathComponent().path(percentEncoded: false) + ":" + (environment["PATH"] ?? "")
        }
        var readable = [
            node.deletingLastPathComponent().deletingLastPathComponent(),
            script.deletingLastPathComponent().deletingLastPathComponent(),
            cli.path.deletingLastPathComponent().deletingLastPathComponent()
        ]
        if keychains {
            readable.append(
                FileManager.default.homeDirectoryForCurrentUser.appending(
                    path: "Library/Keychains", directoryHint: .isDirectory))
        }
        var launch = EngineLaunch(
            executable: node, arguments: [script.path(percentEncoded: false)], environment: environment,
            writable: writable, readable: readable, stateRoot: codexHome)
        // What Codex trusts at its next start, though in the folder it writes: a session that could write them would
        // give later sessions its instructions, skills, rules or tool servers.
        launch.readOnly = Self.trustedFiles.map { codexHome.appending(path: $0) }
        return launch
    }

    /// Codex's own instructions describe its own shell, which is off on the contained path: without a word on it, the
    /// model worked around commands rather than use Agneta's (measured in Replica Bench: builds and probes skipped).
    static let shellNote =
        "In this session your shell is the `shell` tool of the `agneta` MCP server (mcp__agneta__shell): it runs a bash command in the workspace and returns its output and exit status. Codex's own command tools aren't available here, so run every command (builds, tests, scripts, git, inspecting files) with it."

    public func newSession(
        cwd: URL, servers: [JSONValue], policy: SessionPolicy, title: JSONValue?, instructions: String?
    ) -> JSONValue {
        var params: JSONValue = ["cwd": .string(cwd.path(percentEncoded: false)), "mcpServers": .array(servers)]
        let instructions =
            brokersShell(policy)
            ? [instructions, Self.shellNote].compactMap { $0 }.joined(separator: "\n\n") : instructions
        // Measured: an object with `mode` ("append" or "override"). Appended: Codex's own base instructions say
        // how to use its tools, and replacing them would cripple it.
        if let instructions {
            params = params.setting(
                "systemPrompt",
                to: [
                    "mode": "append", "content": [["type": "text", "text": .string(instructions)]],
                    "text": .string(instructions)
                ])
        }
        return params
    }

    public func loadSession(_ engineSession: String, cwd: URL, servers: [JSONValue], policy: SessionPolicy) -> JSONValue
    {
        [
            "sessionId": .string(engineSession), "cwd": .string(cwd.path(percentEncoded: false)),
            "mcpServers": .array(servers)
        ]
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

    /// A configured MCP server's tools go to the model up front, as one namespace with every description (measured on
    /// Codex 0.167.0: 35 tools, no `tool_search`). Codex's own tool search is for ChatGPT apps (`codex_apps`).
    public func appToolsUpfront(_ policy: SessionPolicy) -> Bool? { true }

    /// Measured: an app's tool is `mcp.<server>.<tool>`; built-ins by their own name.
    public func toolIdentity(in update: JSONValue) -> (tool: String?, server: String?, message: String?) {
        guard
            let name = update["_meta"]?["codex"]?["toolName"]?.stringValue ?? update["name"]?.stringValue
                ?? update["title"]?.stringValue
        else { return (nil, nil, nil) }
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

    /// The connectors server Codex can bring for ChatGPT accounts, and Agneta's own shell.
    public var reservedToolServers: Set<String> { ["codex_apps", Self.shellServer] }

    /// Agneta's shell as an MCP server (`agneta-shell --mcp`): Codex's own shell can't be pointed elsewhere and its
    /// own sandbox can't nest in Agneta's, so on the contained path its shell tools are off and this one runs each
    /// command through the broker, like Goose's.
    static let shellServer = "agneta"
    /// Under developer access too: there the broker's profile is widened like a terminal's but keeps the ChatGPT
    /// sign-in out, which Codex's own sandbox must read (measured: a developer command listed ~/Library/Keychains).
    public func brokersShell(_ policy: SessionPolicy) -> Bool { policy.tools != .appOnly }

    /// Agneta's shell in the account's config.toml, the same for every session: codex-acp replaces the MCP servers in
    /// CODEX_CONFIG with the session's own (measured: the shell vanished once an app passed a server), while config.toml's
    /// stay beside them. Each Codex process hands it its own broker socket and token, which the server reads from its
    /// environment (`env_vars`); a session without a shell gets no tool from it (AGNETA_SHELL unset). An hour per call
    /// for long builds.
    /// Files in CODEX_HOME that Codex trusts at its next start: never written by its engines.
    static let trustedFiles = [
        "config.toml", ".env", "AGENTS.md", "AGENTS.override.md", "skills", "rules", "prompts", "hooks.json", "hooks"
    ]

    /// What Codex trusts at its start that Agneta never puts there goes before anything runs Codex on the folder,
    /// in case an engine planted it by an earlier route.
    public static func clearTrusted(_ codexHome: URL) {
        for name in trustedFiles where name != "config.toml" {
            try? FileManager.default.removeItem(at: codexHome.appending(path: name))
        }
    }

    /// A ChatGPT account's Codex home as Agneta's own folder, before sign-in, status or sign-out run Codex on it outside
    /// any sandbox: a real folder (never a link an engine planted) with nothing Codex would trust planted in it.
    public static func prepareAccountHome(_ codexHome: URL) throws -> URL {
        let home = try OwnFolder.ensure(
            codexHome, under: codexHome.deletingLastPathComponent().deletingLastPathComponent())
        clearTrusted(home)
        return home
    }

    static var shellServerHeader: String { "[mcp_servers.\(shellServer)]" }

    static func shellServerConfig(_ shell: URL) -> String {
        let path = shell.path(percentEncoded: false).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
            of: "\"", with: "\\\"")
        return """

            \(shellServerHeader)
            command = "\(path)"
            args = ["--mcp"]
            env_vars = ["AGNETA_BROKER_SOCKET", "AGNETA_BROKER_TOKEN_FILE", "AGNETA_SHELL", "AGNETA_SHELL_CWD"]
            startup_timeout_sec = 30
            tool_timeout_sec = 3600

            """
    }

    public func exportSession(_ engineSession: String) -> EngineRequest? { nil }
    public func importSession(_ exported: JSONValue) -> EngineRequest? { nil }
    public func importedSession(_ result: JSONValue) -> String? { nil }
    /// A session's rollout files, live or archived, in the account's CODEX_HOME.
    static func rollouts(codexHome: URL, session: String) -> [URL] {
        ["sessions", "archived_sessions"].flatMap { folder -> [URL] in
            guard
                let walker = FileManager.default.enumerator(
                    at: codexHome.appending(path: folder, directoryHint: .isDirectory),
                    includingPropertiesForKeys: nil)
            else { return [] }
            return walker.compactMap { $0 as? URL }.filter {
                $0.lastPathComponent.hasPrefix("rollout-") && $0.lastPathComponent.hasSuffix("-\(session).jsonl")
            }
        }
    }

    public func ledger(stateRoot: URL, engineSession: String) -> (any UsageLedger)? {
        CodexRolloutLedger(codexHome: stateRoot, session: engineSession)
    }
}
