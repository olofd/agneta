// Goose behind the engine boundary (goose-acp 1.59.2, pinned in Engines/goose.lock).
// Everything here was measured against that build: extensions per session in
// `_meta.enabledExtensions`, instructions and steering through `_goose/unstable/*`,
// the run id in `session_info_update`, tool identity in `_meta.goose.toolCall`,
// export/import for fork, and per-call usage in its session database.
import Foundation
import GRDB

public struct GooseAdapter: EngineAdapter {
    public let executable: URL
    public init(executable: URL) { self.executable = executable }

    public var id: String { "goose" }
    public var displayName: String { "Goose" }
    public var capabilities: EngineCapabilities {
        // One process serves many sessions; its per-session settings travel over ACP.
        EngineCapabilities(steer: true, fork: true, instructionsBetweenTurns: true, processPerSession: false)
    }

    public func launch(_ context: EngineLaunchContext) throws -> EngineLaunch {
        var provider: [String: String]
        var paths: [URL] = []
        var writable: [URL] = []
        var readable: [URL] = [executable.deletingLastPathComponent()]
        let setup = context.provider
        switch setup.kind {
        case .openAI:
            provider = [
                "GOOSE_PROVIDER": "openai", "GOOSE_MODEL": setup.model ?? "gpt-6.1-sol",
                "OPENAI_API_KEY": setup.apiKey ?? ""
            ]
            if let base = setup.baseURL { provider["OPENAI_BASE_URL"] = base }
        case .anthropic:
            provider = [
                "GOOSE_PROVIDER": "anthropic", "GOOSE_MODEL": setup.model ?? "claude-sonnet-5-5",
                "ANTHROPIC_API_KEY": setup.apiKey ?? ""
            ]
            if let base = setup.baseURL { provider["ANTHROPIC_HOST"] = base }
        case .claudeCode:
            guard let subscription = setup.subscription else {
                throw RPCError(code: RPCError.internalError, message: "The account has no sign-in")
            }
            provider = subscription.gooseEnvironment(model: setup.model)
            // Claude Code, Goose's model here, inherits Goose's environment: its tool search off as on its own route
            // (ClaudeCodeAdapter.environment; measured on 1.59.2 with 2.1.326: all 35 tools in the first request, none
            // without). A session on this route always has a process of its own, so this is the session's.
            if let policy = context.session?.policy { provider.merge(ClaudeCodeAdapter.environment(policy)) { $1 } }
            if let extra = provider.removeValue(forKey: "AGNETA_EXTRA_PATH") {
                paths.append(URL(filePath: extra, directoryHint: .isDirectory))
            }
            writable += subscription.credentialFolders
            readable += subscription.runtimeFolders
            readable.append(
                FileManager.default.homeDirectoryForCurrentUser.appending(
                    path: "Library/Keychains", directoryHint: .isDirectory))
        case .chatGPT:
            throw RPCError(code: RPCError.invalidParams, message: "ChatGPT plans run on Codex")
        }
        if let shell = context.shell { provider["GOOSE_SHELL"] = shell.path(percentEncoded: false) }
        let launch = GooseLaunch(executable: executable, home: context.home, provider: provider, paths: paths)
        try launch.prepare()
        if setup.subscription?.route == .claudeCode { try ClaudeCodeSignIn.linkKeychains(into: context.home) }
        return EngineLaunch(
            executable: executable, arguments: [], environment: launch.environment(),
            writable: writable, readable: readable, stateRoot: launch.gooseRoot)
    }

    /// The app's MCP servers plus only the built-ins the policy allows. Nothing from the user's own setup.
    static func extensions(servers: [JSONValue], policy: SessionPolicy) -> [JSONValue] {
        var extensions: [JSONValue] = servers.map { ["type": "mcp", "server": $0] }
        switch policy.tools {
        case .appOnly: break
        case .read:
            extensions.append([
                "type": "platform", "name": "developer", "available_tools": ["tree", "read_image", "shell"]
            ])
        case .workspace:
            extensions.append([
                "type": "platform", "name": "developer",
                "available_tools": ["write", "edit", "shell", "tree", "read_image"]
            ])
        }
        return extensions
    }

    public func newSession(
        cwd: URL, servers: [JSONValue], policy: SessionPolicy, title: JSONValue?, instructions: String?
    ) -> JSONValue {
        var meta: [String: JSONValue] = ["enabledExtensions": .array(Self.extensions(servers: servers, policy: policy))]
        if let title { meta["sessionTitle"] = title }
        return ["cwd": .string(cwd.path(percentEncoded: false)), "mcpServers": .array(servers), "_meta": .object(meta)]
    }

    public func loadSession(_ engineSession: String, cwd: URL, servers: [JSONValue], policy: SessionPolicy) -> JSONValue
    {
        [
            "sessionId": .string(engineSession), "cwd": .string(cwd.path(percentEncoded: false)),
            "mcpServers": .array(servers),
            "_meta": ["enabledExtensions": .array(Self.extensions(servers: servers, policy: policy))]
        ]
    }

    /// Goose's append mode needs a key; a later append with the same key replaces that part.
    public func setInstructions(_ engineSession: String, text: String, appendKey: String?) -> EngineRequest? {
        if let appendKey {
            return EngineRequest(
                "_goose/unstable/session/system-prompt/set",
                [
                    "sessionId": .string(engineSession), "mode": "append", "key": .string(appendKey),
                    "text": .string(text)
                ])
        }
        return EngineRequest(
            "_goose/unstable/session/system-prompt/set",
            ["sessionId": .string(engineSession), "mode": "set", "text": .string(text)])
    }

    /// Goose needs the running turn's id, from `session_info_update`.
    public func steer(_ engineSession: String, run: String?, prompt: JSONValue) -> EngineRequest? {
        guard let run else { return nil }
        return EngineRequest(
            "_goose/unstable/session/steer",
            ["sessionId": .string(engineSession), "expectedRunId": .string(run), "prompt": prompt])
    }

    public func steerResult(_ result: JSONValue) -> (accepted: Bool, run: String?) {
        (true, result["runId"]?.stringValue)
    }

    public func activeRun(in update: JSONValue) -> String?? {
        guard update["sessionUpdate"]?.stringValue == "session_info_update", let goose = update["_meta"]?["goose"],
            let run = goose["activeRunId"]
        else { return nil }
        return .some(run.stringValue)
    }

    /// With a model API, Goose sends every MCP tool with each request (measured on 1.59.2). On a Claude plan its model is
    /// Claude Code (claude-acp), which defers them as it does on its own unless the app asked for them up front.
    public func appToolsUpfront(_ policy: SessionPolicy, kind: AccountKind?) -> Bool? {
        switch kind {
        case .claude: policy.appTools == .always
        case .anthropicKey, .openAIKey: true
        case .chatGPT, nil: nil
        }
    }

    /// Goose names the tool and the model response in `_meta.goose`, and prefixes an MCP server's
    /// tools with the server's name (`app__echo`); the app's own name is the bare one.
    public func toolIdentity(in update: JSONValue) -> (tool: String?, server: String?, message: String?) {
        let goose = update["_meta"]?["goose"]
        let name = goose?["toolCall"]?["toolName"]?.stringValue
        let server = goose?["toolCall"]?["extensionName"]?.stringValue
        var tool = name
        if let name, let server, name.hasPrefix(server + "__") { tool = String(name.dropFirst(server.count + 2)) }
        return (tool, server, goose?["messageId"]?.stringValue)
    }

    /// Measured: export `{sessionId}` returns `{data}`; import `{input}` returns `{sessionId, messageCount}`.
    public func exportSession(_ engineSession: String) -> EngineRequest? {
        EngineRequest("_goose/unstable/session/export", ["sessionId": .string(engineSession)])
    }

    public func importSession(_ exported: JSONValue) -> EngineRequest? {
        exported["data"].map { EngineRequest("_goose/unstable/session/import", ["input": $0]) }
    }

    public func importedSession(_ result: JSONValue) -> String? { result["sessionId"]?.stringValue }

    public func ledger(stateRoot: URL, engineSession: String) -> (any UsageLedger)? {
        GooseLedgerReader(database: stateRoot.appending(path: "data/sessions/sessions.db"), session: engineSession)
    }

    /// Measured: `session/delete` removes a session's rows, but the deleted text stays in the database's free pages
    /// and in stale frames of its WAL log. A checkpoint, a vacuum (which rewrites the file without the free pages)
    /// and a checkpoint that truncates the log leave no file with it. None changes a row, SQLite allows them beside
    /// Goose's own connection, and Goose went on opening and running sessions after them; while it's mid-write
    /// they wait up to 2 s, then report the log in use.
    /// The schema `sessionsStored` reads: goose-acp 1.59.2's (`schema_version` 18). Another can't tell.
    static let storedSchema: Int64 = 18

    /// Read-only: those of `sessions` with their row, or any row of a table keyed by `session_id` (1.59.2: messages,
    /// usage_ledger, session_tags), in Goose's database. Measured: Goose creates the database when it starts, so one
    /// missing (or another schema) means its storage isn't where or what was measured, and nothing can be told. Asked
    /// to delete a session it doesn't have, Goose answers -32603 "Internal error" with data "Session not found"; that
    /// answer isn't relied on, since this reads what its storage says.
    public func sessionsStored(stateRoot: URL, sessions: [String]) -> Set<String>? {
        let file = stateRoot.appending(path: "data/sessions/sessions.db").path(percentEncoded: false)
        guard !sessions.isEmpty else { return [] }
        guard FileManager.default.fileExists(atPath: file),
            URL(filePath: file).realFileURL.path(percentEncoded: false) == file
        else { return nil }
        do {
            var configuration = Configuration()
            configuration.readonly = true
            configuration.busyMode = .timeout(2)
            let queue = try DatabaseQueue(path: file, configuration: configuration)
            defer { try? queue.close() }
            return try queue.read { db -> Set<String>? in
                guard try Int64.fetchOne(db, sql: "SELECT MAX(version) FROM schema_version") == Self.storedSchema,
                    try db.columns(in: "sessions").contains(where: { $0.name == "id" })
                else { return nil }
                let keyed = try String.fetchAll(
                    db,
                    sql: """
                        SELECT m.name FROM sqlite_master m JOIN pragma_table_info(m.name) c
                        WHERE m.type = 'table' AND c.name = 'session_id'
                        """)
                let marks = databaseQuestionMarks(count: sessions.count)
                let selects =
                    ["SELECT id FROM sessions WHERE id IN (\(marks))"]
                    + keyed.map {
                        "SELECT session_id FROM \($0.quotedDatabaseIdentifier) WHERE session_id IN (\(marks))"
                    }
                let arguments = StatementArguments(Array(repeating: sessions, count: selects.count).flatMap { $0 })
                return Set(
                    try String.fetchAll(db, sql: selects.joined(separator: " UNION "), arguments: arguments))
            }
        } catch {
            return nil
        }
    }

    public func sessionsDeleted(stateRoot: URL) -> String? {
        let file = stateRoot.appending(path: "data/sessions/sessions.db").path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: file) else { return nil }
        // Only Goose's own database, never another file a link in its folders, or in their place, points to (VACUUM
        // rewrites it): the state root is Agneta's own path, written as it is.
        guard URL(filePath: file).realFileURL.path(percentEncoded: false) == file else {
            return "its database isn't where Goose keeps it"
        }
        do {
            var configuration = Configuration()
            configuration.busyMode = .timeout(2)
            let queue = try DatabaseQueue(path: file, configuration: configuration)
            defer { try? queue.close() }
            let busy = try queue.writeWithoutTransaction { db -> Int? in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                try db.execute(sql: "VACUUM")
                return try Int.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            return busy == 0 ? nil : "its log is still in use"
        } catch {
            return "\(error)"
        }
    }
}
