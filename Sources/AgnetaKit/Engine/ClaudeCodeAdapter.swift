// Claude Code behind the engine boundary: the user's own Claude Code (the
// Claude app's bundled copy or a CLI install, found by CLILocator) driven
// through `claude-agent-acp` (pinned in Engines/runtimes.lock, downloaded on
// first use: its binary embeds Anthropic's proprietary Agent SDK). Plan mode
// uses the account's own CLAUDE_CONFIG_DIR, whose Keychain entry Claude Code
// keys by that folder; API-key mode passes ANTHROPIC_API_KEY. Decisions and
// sources: docs/ENGINES.md.
import Foundation

public struct ClaudeCodeAdapter: EngineAdapter {
    /// The `claude-agent-acp` executable.
    public let executable: URL
    /// The user's Claude Code.
    public let cli: InstalledCLI

    public init(executable: URL, cli: InstalledCLI) {
        self.executable = executable
        self.cli = cli
    }

    public var id: String { "claude-code" }
    public var displayName: String { "Claude Code" }
    public var capabilities: EngineCapabilities {
        // Instructions go in at session start (`_meta.systemPrompt`); fork is native to the adapter but not yet wired.
        EngineCapabilities(
            steer: true, fork: false, instructionsBetweenTurns: false, processPerSession: true, cost: .turnEnd,
            runsOwnTools: true)
    }

    public func launch(_ context: EngineLaunchContext) throws -> EngineLaunch {
        let home = context.home
        let temporary = home.appending(path: "tmp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var environment: [String: String] = [
            "HOME": home.path(percentEncoded: false), "TMPDIR": temporary.path(percentEncoded: false),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
            // The real user name: Claude Code keys its Keychain entries by it.
            "USER": NSUserName(), "LOGNAME": NSUserName(),
            "CLAUDE_CODE_EXECUTABLE": cli.path.path(percentEncoded: false),
            "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
        ]
        var writable: [URL] = []
        var readable: [URL] = [executable.deletingLastPathComponent(), Self.bundle(of: cli.path)]
        let config: URL
        switch context.provider.kind {
        case .claudeCode:
            guard let subscription = context.provider.subscription else {
                throw RPCError(code: RPCError.internalError, message: "The account has no sign-in")
            }
            config = subscription.claudeConfig
            try subscription.prepareFolders()
            environment["CLAUDE_CODE_TMPDIR"] = subscription.claudeTemp.path(percentEncoded: false)
            writable += [subscription.claudeConfig, subscription.claudeTemp]
            // A plan's sign-in is in the login Keychain, reached through $HOME/Library/Keychains.
            try ClaudeCodeSignIn.linkKeychains(into: home)
            readable.append(
                FileManager.default.homeDirectoryForCurrentUser.appending(
                    path: "Library/Keychains", directoryHint: .isDirectory))
        case .anthropic:
            config = home.appending(path: "claude", directoryHint: .isDirectory)
            environment["ANTHROPIC_API_KEY"] = context.provider.apiKey ?? ""
            if let base = context.provider.baseURL { environment["ANTHROPIC_BASE_URL"] = base }
        case .openAI, .chatGPT:
            throw RPCError(code: RPCError.invalidParams, message: "Claude Code serves Claude accounts")
        }
        try FileManager.default.createDirectory(
            at: config, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        environment["CLAUDE_CONFIG_DIR"] = ClaudeCodeSignIn.configPath(config)
        var brokered: (temp: URL, dotfiles: [URL])?
        if let shell = context.shell, let policy = context.session?.policy, Self.shellBrokered(policy) {
            brokered = try Self.brokerShell(shell, home: home, environment: &environment)
        }
        // Developer access: Claude Code's other tools find the user's toolchains too (its commands get them from the broker).
        if context.session?.policy.sandbox == .developer {
            environment.merge(
                DeveloperAccess.environment(
                    home: FileManager.default.homeDirectoryForCurrentUser,
                    caches: context.session!.policy.caches(
                        scratch: context.home.appending(path: "scratch", directoryHint: .isDirectory)))
            ) { _, user in user }
        }
        if let brokered { writable.append(brokered.temp) }
        var launch = EngineLaunch(
            executable: executable, arguments: [], environment: environment, writable: writable, readable: readable,
            stateRoot: config)
        if let brokered {
            launch.toolWritable = [brokered.temp]
            launch.temporary = [brokered.temp]
            launch.readOnly = brokered.dotfiles
        }
        // The account's transcripts of other tasks stay out of reach; this session's own folder,
        // named as Claude Code names it (every non-alphanumeric character of the cwd becomes "-"), stays open.
        if let workspace = context.session?.policy.workspace {
            let projects = config.appending(path: "projects", directoryHint: .isDirectory)
            let own = Self.projectFolder(workspace)
            launch.denied = [projects]
            launch.exceptions = [projects.appending(path: own, directoryHint: .isDirectory)]
        }
        // Settings Claude Code reads when Agneta runs it outside any sandbox (sign-in, its status, sign-out): a helper
        // command or environment there would run as the user. Never written by its engines; cleared before those runs.
        if context.provider.kind == .claudeCode {
            launch.readOnly += ClaudeCodeSignIn.trustedSettings.map { config.appending(path: $0) }
        }
        return launch
    }

    /// The project folder Claude Code keeps a workspace's transcripts in: every non-alphanumeric character of its real
    /// path becomes "-".
    static func projectFolder(_ workspace: URL) -> String {
        workspace.realFileURL.path(percentEncoded: false).trimmingSuffix("/")
            .replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
    }

    /// A session's transcript and its subagents' folder, in each project folder of the account's config.
    static func transcripts(config: URL, session: String) -> [URL] {
        let projects = config.appending(path: "projects", directoryHint: .isDirectory)
        let folders =
            (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.flatMap {
            [$0.appending(path: "\(session).jsonl"), $0.appending(path: session, directoryHint: .isDirectory)]
        }
        .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// The `.app` folder around the Claude app's bundled copy, or the CLI's own folder.
    static func bundle(of binary: URL) -> URL {
        var url = binary
        while url.path(percentEncoded: false) != "/" {
            if url.pathExtension == "app" { return url }
            url = url.deletingLastPathComponent()
        }
        return binary.deletingLastPathComponent()
    }

    /// Whether the session's Bash runs through Agneta's broker: whenever it has workspace or read tools. Developer
    /// access too: there the broker's profile is widened like a terminal's (the user's home as HOME, the internet),
    /// but it keeps the engine's sign-in out, which the engine's own sandbox must read (measured: a developer command
    /// listed ~/Library/Keychains when it ran in the engine's sandbox).
    public static func shellBrokered(_ policy: SessionPolicy) -> Bool { policy.tools != .appOnly }

    /// Bash through the broker. Claude Code wraps each whole command (snapshot sourcing, `eval`, and recording the
    /// current folder) in `CLAUDE_CODE_SHELL_PREFIX`, split at its last ` -` into `'agneta-shell' -c '<command>'`,
    /// agneta-shell's own usage (measured in 2.1.325), so the command runs under the session's tool profile, never in
    /// the engine's sandbox. The outer shell is bash, which reads no startup files for `-c`; the engine home's
    /// startup files (read by a login shell, which Claude Code falls back to without a snapshot) are kept unwritable.
    /// Its temporary folder is the engine's own, short (it holds Unix sockets: sockaddr_un allows 104 bytes), and
    /// writable by the commands too: they write the current-folder file and background output there.
    static func brokerShell(_ shell: URL, home: URL, environment: inout [String: String]) throws -> (
        temp: URL, dotfiles: [URL]
    ) {
        let digest = home.path(percentEncoded: false).utf8.reduce(UInt64(1469598103934665603)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
        let temp = try OwnFolder.ensure(
            FileManager.default.temporaryDirectory.appending(
                path: "agneta-e\(String(digest, radix: 36).prefix(8))", directoryHint: .isDirectory),
            under: FileManager.default.temporaryDirectory)
        environment["CLAUDE_CODE_SHELL_PREFIX"] = shell.path(percentEncoded: false) + " -c"
        environment["CLAUDE_CODE_SHELL"] = "/bin/bash"
        environment["CLAUDE_CODE_TMPDIR"] = temp.path(percentEncoded: false)
        let dotfiles = [
            ".bash_profile", ".bash_login", ".profile", ".bashrc", ".bash_logout", ".zshenv", ".zprofile", ".zshrc",
            ".zlogin", ".inputrc"
        ]
        .map { home.appending(path: $0) }
        return (temp, dotfiles)
    }

    /// The built-in tools a policy offers, by Claude Code's own names, passed as the SDK's `tools`: Claude Code offers
    /// exactly these, so a tool a later version adds stays off until it's named here (the app's MCP tools aren't
    /// affected; measured on 2.1.325). Commands aren't among them: Claude Code runs the ones it judges read-only
    /// without asking, inside the engine's sandbox, which reaches port 443 (measured), so Bash waits for the broker.
    /// `ToolSearch` only loads deferred tools, the app's among them, so it goes when nothing is deferred
    /// (`agneta/appTools` `always`). Developer access gets Claude Code's own set.
    static func tools(_ policy: SessionPolicy) -> [String]? {
        if policy.sandbox == .developer { return nil }
        // Bash (and stopping its background commands) only through the broker; Monitor never on this path.
        let shell = shellBrokered(policy) ? ["Bash", "TaskStop", "Agent"] : []
        let search = policy.appTools == .always ? [] : ["ToolSearch"]
        switch policy.tools {
        case .appOnly: return search
        case .read: return ["Read", "Glob", "Grep"] + search + shell
        case .workspace: return ["Read", "Glob", "Grep", "Edit", "Write", "NotebookEdit"] + search + shell
        }
    }

    /// Claude Code's own variables for the session's query, merged over the engine's environment by the adapter
    /// (`options.env`). Tool search defers every MCP tool by default: only names reach the model, each loaded with
    /// ToolSearch before its first call (measured on 2.1.326, with 3 tools as with 35). `ENABLE_TOOL_SEARCH=false` sends
    /// every one with its description and schema from the first request, and no deferral placeholder; leaving
    /// ToolSearch out of `tools` alone loads them too but keeps a placeholder `defer_loading` entry, and `auto` loads
    /// them below its threshold while still telling the model they're deferred (both measured), so neither is used.
    static func environment(_ policy: SessionPolicy) -> [String: String] {
        policy.appTools == .always ? ["ENABLE_TOOL_SEARCH": "false"] : [:]
    }

    /// A second net under the allowlist: the built-ins that run commands or code, fetch, or act beyond the session
    /// (2.1.325's names, with the old ones kept for older versions). Under developer access only what reaches the
    /// user's claude.ai account or devices stays off.
    static let neverByDefault = [
        "Bash", "PowerShell", "Monitor", "BashOutput", "KillShell", "TaskStop", "WebFetch", "WebSearch", "Agent",
        "Task", "Skill", "SlashCommand", "Workflow", "LSP", "EnterWorktree", "ExitWorktree", "CronCreate", "CronDelete",
        "CronList", "RemoteTrigger", "ScheduleWakeup", "SendMessage", "ListAgents", "Artifact", "SendUserFile",
        "PushNotification", "Projects", "ClaudeDesign", "ReadNotifications", "SendUserMessage"
    ]
    static func disallowed(_ policy: SessionPolicy) -> [String] {
        // Developer access: everything a terminal's Claude Code has, apart from what reaches the user's claude.ai account
        // or devices rather than this machine (artifacts, projects, designs, notifications, remote agents): a session
        // works for the app, and what it makes or sends goes back to the app.
        // Monitor and PowerShell run commands natively inside the engine's profile, which on a plan reaches the sign-in's
        // Keychain: off until they're shown to go through Agneta's broker as Bash does.
        if policy.sandbox == .developer {
            return [
                "RemoteTrigger", "Artifact", "Projects", "ClaudeDesign", "SendUserMessage", "SendUserFile",
                "PushNotification", "Monitor", "PowerShell"
            ]
        }
        return shellBrokered(policy)
            ? neverByDefault.filter { !["Bash", "TaskStop", "KillShell", "BashOutput", "Agent", "Task"].contains($0) }
            : neverByDefault
    }

    /// The session options, the same on new, load and fork: a resumed session given none falls back to the
    /// adapter's defaults, which load the workspace's own `.claude/settings.json` (hooks, env, permissions the agent
    /// can write; measured on 0.107.2).
    func meta(_ policy: SessionPolicy, instructions: String?) -> JSONValue {
        var options: [String: JSONValue] = [
            // Nothing from the user's own settings or MCP configuration; no extra model work for suggestions; MCP
            // servers handed over at start rather than as command-line arguments (where other users could read bearers).
            "settingSources": [], "strictMcpConfig": true, "promptSuggestions": false,
            "mcpServersDelivery": "initialize",
            "disallowedTools": .array(Self.disallowed(policy).map(JSONValue.string))
        ]
        if let tools = Self.tools(policy) { options["tools"] = .array(tools.map(JSONValue.string)) }
        let environment = Self.environment(policy)
        if !environment.isEmpty { options["env"] = .object(environment.mapValues(JSONValue.string)) }
        var meta: [String: JSONValue] = [
            "claudeCode": [
                "options": .object(options),
                // Each model call's usage, from the SDK's own messages.
                "emitRawSDKMessages": [["type": "assistant"], ["type": "result"]]
            ]
        ]
        if let instructions { meta["systemPrompt"] = .string(instructions) }
        return .object(meta)
    }

    public func newSession(
        cwd: URL, servers: [JSONValue], policy: SessionPolicy, title: JSONValue?, instructions: String?
    ) -> JSONValue {
        [
            "cwd": .string(cwd.path(percentEncoded: false)), "mcpServers": .array(servers),
            "_meta": meta(policy, instructions: instructions)
        ]
    }

    public func loadSession(_ engineSession: String, cwd: URL, servers: [JSONValue], policy: SessionPolicy) -> JSONValue
    {
        loadSession(engineSession, cwd: cwd, servers: servers, policy: policy, instructions: nil)
    }

    public func loadSession(
        _ engineSession: String, cwd: URL, servers: [JSONValue], policy: SessionPolicy, instructions: String?
    ) -> JSONValue {
        [
            "sessionId": .string(engineSession), "cwd": .string(cwd.path(percentEncoded: false)),
            "mcpServers": .array(servers),
            "_meta": meta(policy, instructions: instructions)
        ]
    }

    /// The adapter starts sessions in `auto`, where Claude Code decides its own permissions and asks nothing
    /// (measured on 0.107.2: Bash and Monitor ran without a request), and `permissionMode` in the options is
    /// ignored: every opened session is set to `default`, so each tool call is asked about.
    public func prepareSession(_ engineSession: String) -> [EngineRequest] {
        [EngineRequest("session/set_mode", ["sessionId": .string(engineSession), "modeId": "default"])]
    }

    public func setInstructions(_ engineSession: String, text: String, appendKey: String?) -> EngineRequest? { nil }

    /// `acceptEdits`, `auto` and `bypassPermissions` stop asking; Agneta gates every call from those questions.
    public func permitsMode(_ mode: String) -> Bool { ["default", "plan"].contains(mode) }

    public func steer(_ engineSession: String, run: String?, prompt: JSONValue) -> EngineRequest? {
        EngineRequest("_session/steering", ["sessionId": .string(engineSession), "prompt": prompt])
    }

    public func steerResult(_ result: JSONValue) -> (accepted: Bool, run: String?) {
        (result["outcome"]?.stringValue.map { $0 != "promptRequired" } ?? true, nil)
    }

    public func activeRun(in update: JSONValue) -> String?? { nil }

    /// `_meta.claudeCode.toolName`: `Read`, or `mcp__app__echo` for an app's tool.
    public func toolIdentity(in update: JSONValue) -> (tool: String?, server: String?, message: String?) {
        guard let name = update["_meta"]?["claudeCode"]?["toolName"]?.stringValue else { return (nil, nil, nil) }
        let parts = name.components(separatedBy: "__")
        if parts.count >= 3, parts[0] == "mcp" { return (parts.dropFirst(2).joined(separator: "__"), parts[1], nil) }
        return (name, nil, nil)
    }

    /// Claude Code's own sandboxed tools and claude-agent-acp's client-backed ones are MCP servers of theirs
    /// (`mcp__workspace__bash`, `mcp__acp__…`).
    public var reservedToolServers: Set<String> { ["workspace", "acp"] }

    public func brokersShell(_ policy: SessionPolicy) -> Bool { Self.shellBrokered(policy) }

    /// Deferred behind tool search unless the app asked for them up front: tool search is on by default as measured on
    /// 2.1.326 (behind a gateway too since 2.1.304, Claude Code's docs say; an older version there loads them up front).
    public func appToolsUpfront(_ policy: SessionPolicy, kind: AccountKind?) -> Bool? { policy.appTools == .always }

    public func exportSession(_ engineSession: String) -> EngineRequest? { nil }
    public func importSession(_ exported: JSONValue) -> EngineRequest? { nil }
    public func importedSession(_ result: JSONValue) -> String? { nil }
    /// The session's own transcript, in the account's config (`stateRoot`): each call's final usage.
    public func ledger(stateRoot: URL, engineSession: String) -> (any UsageLedger)? {
        ledger(stateRoot: stateRoot, engineSession: engineSession, workspace: nil)
    }

    public func ledger(stateRoot: URL, engineSession: String, workspace: URL?) -> (any UsageLedger)? {
        ClaudeCodeTranscriptLedger(
            config: stateRoot, session: engineSession, preferredFolder: workspace.map(Self.projectFolder))
    }

    /// `_claude/sdkMessage`. An assistant message is one model call: its id, model, input and cache tokens are
    /// exact, but its usage is the stream's opening count, so output is only the first few tokens (measured on
    /// Haiku: 40 recorded against 210 in the turn's result). The transcript gives the call's final row
    /// (`ClaudeCodeTranscriptLedger`); this one stands in if it doesn't come. A subagent's calls carry the tool call
    /// that started it (`parent_tool_use_id`). A result carries `modelUsage`, the session's running totals per model,
    /// side calls included; the trace takes each turn's share from it.
    public func modelCall(fromNotification method: String, params: JSONValue?) -> [String: JSONValue]? {
        guard method == "_claude/sdkMessage" else { return nil }
        let sdk = params?["message"] ?? params?["sdkMessage"] ?? params
        switch sdk?["type"]?.stringValue {
        case "assistant":
            guard let message = sdk?["message"], let usage = message["usage"] else { return nil }
            return [
                "id": message["id"] ?? .null, "model": message["model"] ?? .null,
                "input_tokens": usage["input_tokens"] ?? .null, "output_tokens": usage["output_tokens"] ?? .null,
                "cache_read_tokens": usage["cache_read_input_tokens"] ?? .null,
                "cache_write_tokens": usage["cache_creation_input_tokens"] ?? .null,
                "output_partial": true, "cost": .null, "cost_source": "claude-code", "basis": "engine-stream",
                "parent": sdk?["parent_tool_use_id"] ?? .null
            ]
        case "result":
            guard let models = sdk?["modelUsage"]?.objectValue, !models.isEmpty else { return nil }
            var totals: [String: JSONValue] = [:]
            for (model, usage) in models {
                totals[model] = [
                    "input": usage["inputTokens"] ?? .null, "output": usage["outputTokens"] ?? .null,
                    "cacheRead": usage["cacheReadInputTokens"] ?? .null,
                    "cacheWrite": usage["cacheCreationInputTokens"] ?? .null,
                    "cost": usage["costUSD"] ?? .null
                ]
            }
            return ["session_totals": .object(totals), "cost_source": "claude-code"]
        default:
            return nil
        }
    }
}
