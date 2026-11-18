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
        EngineCapabilities(steer: true, fork: false, instructionsBetweenTurns: false, processPerSession: true, reportsCost: false, runsOwnTools: true)
    }

    public func launch(_ context: EngineLaunchContext) throws -> EngineLaunch {
        let home = context.home
        let temporary = home.appending(path: "tmp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var environment: [String: String] = [
            "HOME": home.path(percentEncoded: false), "TMPDIR": temporary.path(percentEncoded: false),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
            // The real user name: Claude Code keys its Keychain entries by it.
            "USER": NSUserName(), "LOGNAME": NSUserName(),
            "CLAUDE_CODE_EXECUTABLE": cli.path.path(percentEncoded: false),
            "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        ]
        var writable: [URL] = []
        var readable: [URL] = [executable.deletingLastPathComponent(), Self.bundle(of: cli.path)]
        let config: URL
        switch context.provider.kind {
        case .claudeCode:
            guard let subscription = context.provider.subscription else { throw RPCError(code: RPCError.internalError, message: "The account has no sign-in") }
            config = subscription.claudeConfig
            try FileManager.default.createDirectory(at: subscription.claudeTemp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            environment["CLAUDE_CODE_TMPDIR"] = subscription.claudeTemp.path(percentEncoded: false)
            writable += [subscription.claudeConfig, subscription.claudeTemp]
            // A plan's sign-in is in the login Keychain, reached through $HOME/Library/Keychains.
            try ClaudeCodeSignIn.linkKeychains(into: home)
            readable.append(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Keychains", directoryHint: .isDirectory))
        case .anthropic:
            config = home.appending(path: "claude", directoryHint: .isDirectory)
            environment["ANTHROPIC_API_KEY"] = context.provider.apiKey ?? ""
            if let base = context.provider.baseURL { environment["ANTHROPIC_BASE_URL"] = base }
        case .openAI, .chatGPT:
            throw RPCError(code: RPCError.invalidParams, message: "Claude Code serves Claude accounts")
        }
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        environment["CLAUDE_CONFIG_DIR"] = ClaudeCodeSignIn.configPath(config)
        var launch = EngineLaunch(executable: executable, arguments: [], environment: environment, writable: writable, readable: readable, stateRoot: config)
        // The account's transcripts of other tasks stay out of reach; this session's own folder,
        // named as Claude Code names it (every non-alphanumeric character of the cwd becomes "-"), stays open.
        if let workspace = context.session?.policy.workspace {
            let projects = config.appending(path: "projects", directoryHint: .isDirectory)
            let own = workspace.realFileURL.path(percentEncoded: false).trimmingSuffix("/")
                .replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
            launch.denied = [projects]
            launch.exceptions = [projects.appending(path: own, directoryHint: .isDirectory)]
        }
        return launch
    }

    /// A session's transcript and its subagents' folder, in each project folder of the account's config.
    static func transcripts(config: URL, session: String) -> [URL] {
        let projects = config.appending(path: "projects", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.flatMap { [$0.appending(path: "\(session).jsonl"), $0.appending(path: session, directoryHint: .isDirectory)] }
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

    /// Claude Code's built-in tools, by the policy's `tools`. The app's MCP tools are always available.
    static let builtIns = ["Bash", "BashOutput", "KillShell", "Edit", "MultiEdit", "Write", "NotebookEdit", "Read", "Glob", "Grep",
                           "WebFetch", "WebSearch", "Task", "TodoWrite", "SlashCommand", "Skill"]
    static func disallowed(_ policy: SessionPolicy) -> [String] {
        switch policy.tools {
        case .appOnly: builtIns
        case .read: builtIns.filter { !["Read", "Glob", "Grep"].contains($0) }
        case .workspace: ["WebFetch", "WebSearch", "Task", "SlashCommand", "Skill"]
        }
    }

    public func newSession(cwd: URL, servers: [JSONValue], policy: SessionPolicy, title: JSONValue?, instructions: String?) -> JSONValue {
        var meta: [String: JSONValue] = [
            "claudeCode": [
                "options": [
                    // Nothing from the user's own settings; no extra model work for suggestions; MCP servers handed
                    // over at start rather than as command-line arguments (where other users could read bearers).
                    "settingSources": [], "promptSuggestions": false, "mcpServersDelivery": "initialize",
                    "disallowedTools": .array(Self.disallowed(policy).map(JSONValue.string)),
                ],
                // Each model call's usage, from the SDK's own messages.
                "emitRawSDKMessages": [["type": "assistant"], ["type": "result"]],
            ],
        ]
        if let instructions { meta["systemPrompt"] = .string(instructions) }
        return ["cwd": .string(cwd.path(percentEncoded: false)), "mcpServers": .array(servers), "_meta": .object(meta)]
    }

    public func loadSession(_ engineSession: String, cwd: URL, servers: [JSONValue], policy: SessionPolicy) -> JSONValue {
        ["sessionId": .string(engineSession), "cwd": .string(cwd.path(percentEncoded: false)), "mcpServers": .array(servers)]
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

    public func exportSession(_ engineSession: String) -> EngineRequest? { nil }
    public func importSession(_ exported: JSONValue) -> EngineRequest? { nil }
    public func importedSession(_ result: JSONValue) -> String? { nil }
    public func ledger(stateRoot: URL, engineSession: String) -> (any UsageLedger)? { nil }

    /// `_claude/sdkMessage`. An assistant message is one model call: its id, model, input and cache tokens are
    /// exact, but its usage is the stream's opening count, so output is only the first few tokens (measured on
    /// Haiku: 40 recorded against 210 in the turn's result). A result carries `modelUsage`, the session's
    /// running totals per model, side calls included; the trace takes each turn's share from it.
    public func modelCall(fromNotification method: String, params: JSONValue?) -> [String: JSONValue]? {
        guard method == "_claude/sdkMessage" else { return nil }
        let sdk = params?["message"] ?? params?["sdkMessage"] ?? params
        switch sdk?["type"]?.stringValue {
        case "assistant":
            guard let message = sdk?["message"], let usage = message["usage"] else { return nil }
            return [
                "id": message["id"] ?? .null, "model": message["model"] ?? .null,
                "input_tokens": usage["input_tokens"] ?? .null, "output_tokens": usage["output_tokens"] ?? .null,
                "cache_read_tokens": usage["cache_read_input_tokens"] ?? .null, "cache_write_tokens": usage["cache_creation_input_tokens"] ?? .null,
                "output_partial": true, "cost": .null, "cost_source": "claude-code",
            ]
        case "result":
            guard let models = sdk?["modelUsage"]?.objectValue, !models.isEmpty else { return nil }
            var totals: [String: JSONValue] = [:]
            for (model, usage) in models {
                totals[model] = ["input": usage["inputTokens"] ?? .null, "output": usage["outputTokens"] ?? .null,
                                 "cacheRead": usage["cacheReadInputTokens"] ?? .null, "cacheWrite": usage["cacheCreationInputTokens"] ?? .null,
                                 "cost": usage["costUSD"] ?? .null]
            }
            return ["session_totals": .object(totals), "cost_source": "claude-code"]
        default:
            return nil
        }
    }
}
