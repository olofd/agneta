// What outlives a setting or a deletion, and mustn't: plan sign-ins Reset can't remove are reported, conversations a
// shared engine didn't delete stay queued until it does, and a shared engine started before its provider's settings
// changed doesn't serve the next session.
import Foundation
import Testing

@testable import AgnetaKit

@Suite struct PlanSignOutTests {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "agneta-signout-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory
    ).realFileURL

    /// An account folder as a plan sign-in leaves it: Claude Code's config folder, or Codex's home.
    func home(_ name: String, _ program: String) throws -> URL {
        let home = root.appending(path: "Accounts/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: home.appending(path: program, directoryHint: .isDirectory), withIntermediateDirectories: true)
        return home
    }

    /// A stand-in CLI that records its arguments and exits with `status`.
    func program(_ name: String, status: Int) throws -> URL {
        let bin = root.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let url = bin.appending(path: name)
        let calls = root.appending(path: "\(name)-calls.txt").path(percentEncoded: false)
        try "#!/bin/sh\necho \"$* ${CLAUDE_CONFIG_DIR}${CODEX_HOME}\" >> '\(calls)'\nexit \(status)\n".write(
            to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    func calls(_ name: String) -> String {
        (try? String(contentsOf: root.appending(path: "\(name)-calls.txt"), encoding: .utf8)) ?? ""
    }

    /// No install to sign out with: every plan sign-in is reported as remaining, and the user is told how to remove it.
    @Test func withoutAProgramTheSignInIsReported() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = try home("c", "claude"), codex = try home("x", "codex"),
            key = root.appending(path: "Accounts/k", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: key, withIntermediateDirectories: true)
        let leftovers = await PlanSignOut.signOut(homes: [claude, codex, key], claudeCode: nil, codex: nil)
        #expect(
            leftovers == [
                PlanSignOut.Leftover(kind: .claude, home: claude, reason: .noProgram),
                PlanSignOut.Leftover(kind: .chatGPT, home: codex, reason: .noProgram)
            ])
        let text = try #require(PlanSignOut.explanation(leftovers))
        #expect(
            text.contains("Keychain Access") && text.contains("“Claude Code-credentials”")
                && text.contains("“Codex Auth”"))
        #expect(text.contains("no supported Claude Code was found"))
        #expect(PlanSignOut.explanation([]) == nil)
    }

    /// Each account's own logout runs for its folder; a logout that fails is reported, one that succeeds isn't.
    @Test func aFailedLogoutIsReported() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = try home("c", "claude"), codex = try home("x", "codex")
        let leftovers = await PlanSignOut.signOut(
            homes: [claude, codex], claudeCode: try program("claude", status: 1), codex: try program("codex", status: 0)
        )
        #expect(leftovers == [PlanSignOut.Leftover(kind: .claude, home: claude, reason: .logoutFailed)])
        #expect(
            calls("claude").contains(
                "auth logout \(ClaudeCodeSignIn.configPath(claude.appending(path: "claude", directoryHint: .isDirectory)))"
            ))
        #expect(
            calls("codex").contains(
                "logout \(codex.appending(path: "codex", directoryHint: .isDirectory).path(percentEncoded: false))"))
        #expect(PlanSignOut.explanation(leftovers)?.contains("Claude Code's logout didn't succeed") == true)
    }
}

/// Clearing history when a shared engine can't delete the conversation now: it stays queued in Agneta's records (not
/// only in a task that went with the trace), the user hears why, and signing the provider out drops it.
@Suite struct ConversationQueueTests {
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var left: [(Int, String?)] = []
        func add(_ event: AgnetaRuntime.Event) {
            if case .conversationsLeft(let count, let problem) = event {
                lock.withLock { left.append((count, problem)) }
            }
        }
        var last: (Int, String?)? { lock.withLock { left.last } }
    }

    @Test func aConversationNotDeletedStaysQueuedAndIsReported() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agneta-forget-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory
        ).realFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgnetaStore(root: root.appending(path: "agneta", directoryHint: .isDirectory))
        func open() async throws -> AgnetaRuntime {
            try await AgnetaRuntime(.init(store: store, shellTool: URL(filePath: "/usr/bin/true"))) { _ in
                Router.PairingAnswer(accounts: [], remember: false)
            }
        }
        var runtime = try await open()
        let events = Events()
        await runtime.observe { events.add($0) }
        // Served, but its engine isn't here: the shared engine can't be asked.
        await runtime.serve(
            account: "dev", label: "Dev", provider: ProviderSetup(kind: .openAI, apiKey: "k"), runner: .brokered,
            kind: .openAIKey, billing: "api-key", paused: false)

        // An ended task whose conversation is in the account's shared Goose.
        try runtime.database.taskStarted(
            TaskRecord(id: "t1", app: "App", account: "dev", title: "Hi", started: Date().addingTimeInterval(-60)))
        try runtime.database.taskEnded("t1", outcome: .finished)
        let meta: JSONValue = [
            "type": "meta", "account": ["id": "dev"],
            "engine": [
                "id": "goose", "dedicated": false, "session": "s1",
                "key": .string(EngineKeys.shared(account: "dev", engine: "goose"))
            ]
        ]
        try FileManager.default.createDirectory(
            at: runtime.traces.file(for: "t1").deletingLastPathComponent(), withIntermediateDirectories: true)
        try (JSONCoding.encode(meta) + Data("\n".utf8)).write(to: runtime.traces.file(for: "t1"))
        let conversation = Router.SharedConversation(account: "dev", engine: "goose", session: "s1")

        await runtime.clearHistory()
        await runtime.conversationsSettled()
        #expect(await runtime.history().isEmpty && runtime.traces.meta(task: "t1") == nil)
        #expect(await runtime.pendingConversations == [conversation])
        #expect(events.last?.0 == 1 && events.last?.1?.contains("isn't here") == true)

        // Kept across launches, and asked for again when the provider is served.
        await runtime.shutdown()
        runtime = try await open()
        await runtime.observe { events.add($0) }
        #expect(await runtime.pendingConversations == [conversation])
        await runtime.serve(
            account: "dev", label: "Dev", provider: ProviderSetup(kind: .openAI, apiKey: "k"), runner: .brokered,
            kind: .openAIKey, billing: "api-key", paused: false)
        await runtime.conversationsSettled()
        #expect(await runtime.pendingConversations == [conversation])

        // Signed out: the account's engine state goes with its folder, and nothing is left to ask for.
        await runtime.remove(account: "dev")
        #expect(await runtime.pendingConversations.isEmpty)
        #expect(events.last?.0 == 0 && events.last?.1 == nil)
        await runtime.shutdown()
    }
}

/// An engine that is a shell script answering `initialize`, shared by an account's app-only sessions as Goose is.
struct SharedProbeAdapter: EngineAdapter {
    let probe = ProbeAdapter(
        script: """
            IFS= read -r line
            id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
            printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{},"agentInfo":{"name":"probe"}}}\\n' "$id"
            exec cat > /dev/null
            """)
    var id: String { "probe" }
    var displayName: String { "Probe" }
    var capabilities: EngineCapabilities {
        EngineCapabilities(steer: false, fork: false, instructionsBetweenTurns: false, processPerSession: false)
    }
    func launch(_ context: EngineLaunchContext) throws -> EngineLaunch { try probe.launch(context) }
    func newSession(cwd: URL, servers: [JSONValue], policy: SessionPolicy, title: JSONValue?, instructions: String?)
        -> JSONValue
    { probe.newSession(cwd: cwd, servers: servers, policy: policy, title: title, instructions: instructions) }
    func loadSession(_ engineSession: String, cwd: URL, servers: [JSONValue], policy: SessionPolicy) -> JSONValue {
        probe.loadSession(engineSession, cwd: cwd, servers: servers, policy: policy)
    }
    func setInstructions(_ engineSession: String, text: String, appendKey: String?) -> EngineRequest? { nil }
    func steer(_ engineSession: String, run: String?, prompt: JSONValue) -> EngineRequest? { nil }
    func steerResult(_ result: JSONValue) -> (accepted: Bool, run: String?) { (false, nil) }
    func activeRun(in update: JSONValue) -> String?? { nil }
    func toolIdentity(in update: JSONValue) -> (tool: String?, server: String?, message: String?) { (nil, nil, nil) }
    func exportSession(_ engineSession: String) -> EngineRequest? { nil }
    func importSession(_ exported: JSONValue) -> EngineRequest? { nil }
    func importedSession(_ result: JSONValue) -> String? { nil }
    func ledger(stateRoot: URL, engineSession: String) -> (any UsageLedger)? { nil }
}

/// A shared engine keeps the setup it started with (Goose its GOOSE_MODEL). When the provider's settings change, the
/// next session gets one started afresh: an idle engine stops at once, a busy one when its last session ends.
@Suite struct SharedEngineRenewalTests {
    @Test func aSettingsChangeRetiresTheAccountsSharedEngines() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agneta-renew-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory
        ).realFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let agneta = root.appending(path: "agneta", directoryHint: .isDirectory)
        let workspace = root.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let supervisor = EngineSupervisor(
            .init(shellTool: URL(filePath: "/usr/bin/true"), root: agneta),
            accounts: ["a": ProviderSetup(kind: .openAI, model: "custom", apiKey: "k")])
        let policy = try SessionPolicy.parse(
            ["tools": "app-only"], cwd: workspace.path(percentEncoded: false),
            context: PolicyContext(userHome: FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [agneta]))
        let engine = SharedProbeAdapter()
        func open() async throws -> EngineLease {
            try await supervisor.open(
                account: "a", engine: engine, policy: policy, mcpPorts: [], key: nil, session: nil)
        }

        let first = try await open()
        #expect(!first.dedicated)
        await supervisor.release(first)
        #expect(await supervisor.processCount == 1) // shared: it stays for the next session

        // The same setup again (a rename, a pause) keeps it.
        await supervisor.add(account: "a", provider: ProviderSetup(kind: .openAI, model: "custom", apiKey: "k"))
        let holding = try await open()
        #expect(holding.pid == first.pid)

        // The custom model cleared while a session holds the engine: it serves that session on, then stops.
        await supervisor.add(account: "a", provider: ProviderSetup(kind: .openAI, apiKey: "k"))
        #expect(await supervisor.processCount == 1)
        await supervisor.release(holding)
        #expect(await supervisor.processCount == 0)
        let second = try await open()
        #expect(second.pid != first.pid)
        await supervisor.release(second)

        // Defaults changed (AgnetaRuntime.setDefaults): an idle engine stops at once.
        await supervisor.renew(account: "a")
        #expect(await supervisor.processCount == 0)
        let third = try await open()
        #expect(third.pid != second.pid)
        await supervisor.release(third)
        await supervisor.stopAll()
    }
}

/// A Codex task leaves history through Codex itself (`codex delete --force <id>` on the account's folder), which also
/// removes its copies in Codex's databases; a stand-in records what it's asked.
@Test func codexDeletesItsOwnSession() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "agneta-codex-delete-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory
    ).realFileURL
    defer { try? FileManager.default.removeItem(at: root) }
    let codexHome = root.appending(path: "Accounts/a1/codex", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    let log = root.appending(path: "asked.txt"), program = root.appending(path: "codex")
    try "#!/bin/sh\necho \"$CODEX_HOME $*\" >> '\(log.path(percentEncoded: false))'\n".write(
        to: program, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path(percentEncoded: false))
    let session = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
    #expect(await CodexSignIn(cli: program, codexHome: codexHome).delete(session: session))
    let asked = try String(contentsOf: log, encoding: .utf8)
    #expect(
        asked.contains("delete --force \(session)")
            && asked.contains(codexHome.path(percentEncoded: false).trimmingSuffix("/")), "\(asked)")
}
