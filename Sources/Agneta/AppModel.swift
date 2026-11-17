// Agneta's state for its UI: accounts, app access, running tasks, sign-in.
// Underneath, the runtime (AgnetaKit's AgnetaRuntime) owns the router, the
// engines and everything Agneta records; this model observes it, tells it which
// accounts to serve, and keeps what the windows show. The UI only reads this
// model and calls its methods.
import AgnetaKit
import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor @Observable
final class AppModel {
    struct Task: Identifiable, Equatable {
        var id: String
        var app: String
        var appIdentifier: String?
        var account: String
        var title: String
        var started: Date
        var running: Bool
        var stopping = false
        var stopWarning: String?
        var cost: Double?
        var lastStopReason: String?
    }

    struct Approval: Identifiable, Sendable {
        /// The router's pairing request id.
        let id: UUID
        var app: String
        var identifier: String?
        var verified: Bool
        var code: String
        var choices: [AccountRecord]
        var allowed: Set<String>
        /// What the app asks to do: the most built-in tools, and folders of the user's beyond its own workspace.
        var tools: SessionPolicy.Tools = .appOnly
        var folders: [URL] = []
    }

    struct SignIn {
        var kind: AccountKind
        var text: String
        var page: URL?
        var needsCode = false
        var finished = false
        var failed: String?
    }

    // MARK: State

    private(set) var accounts: [AccountRecord] = []
    private(set) var grants: [String: Router.Grant] = [:]
    private(set) var tasks: [Task] = []
    /// Ended tasks, newest first (Settings → Activity).
    private(set) var history: [TaskRecord] = []
    private(set) var needsSignIn: Set<String> = []
    /// Accounts a provider limit stopped, with when it resets if the provider said.
    private(set) var limited: [String: Date?] = [:]
    /// The plan's own usage per account, when its engine reports it (Codex), e.g. "57% of this week's limit".
    private(set) var planUsage: [String: String] = [:]
    /// Days of task history kept; 0 keeps none.
    private(set) var historyDays = 30
    /// Set while Reset Agneta runs, and the failed step if it stopped.
    private(set) var resetting = false
    private(set) var resetProblem: String?
    /// The database couldn't be opened (for example, written by a newer Agneta).
    private(set) var storeProblem: String?
    /// What the last launch cleaned up after a crash, for one quiet line in Activity.
    private(set) var recovered: (engines: Int, tasks: Int) = (0, 0)
    /// The pairing request on screen; edits change its allowed accounts.
    var approval: Approval? {
        get { approvals.current }
        set { approvals.current = newValue }
    }
    private var approvals = ApprovalQueue<Approval, Router.PairingAnswer>()
    /// A request the user hasn't answered is refused after this long, as a dialog nobody saw shouldn't wait forever.
    static let approvalTimeout: Duration = .seconds(300)
    var signIn: SignIn?
    private(set) var serverProblem: String?
    /// A task's record couldn't be written (the disk is full, say): tasks run on, but their traces are incomplete.
    private(set) var traceProblem: String?
    let port: UInt16
    /// Why an isolated instance has no usable port (AGNETA_PORT missing or unsafe): it then listens on none.
    private var portProblem: String?

    let bundleID = Bundle.main.bundleIdentifier ?? "com.objectivecoder.agneta.dev"
    var isDevelopment: Bool { bundleID.hasSuffix(".dev") }

    let store: AgnetaStore
    private let keychain: Keychain
    /// Running under AGNETA_HOME: everything stays inside that folder.
    private let isolated: Bool
    /// Agneta's own log: events, ids and timing, never content.
    let log: OperationalLog
    /// The runtime: nil while Reset runs, and replaced after it. Whatever waited holds on to the one it began with.
    private var runtime: AgnetaRuntime?
    private var database: AgnetaDatabase? { runtime?.database }
    private var traces: Traces? { runtime?.traces }
    private var diagnostics: DiagnosticsMCP?
    /// The token diagnostic tools use, while they're allowed (Settings → Advanced).
    private(set) var diagnosticsToken: String?
    private(set) var diagnosticsProblem: String?
    /// The diagnostics MCP server's port: two above the apps' port.
    var diagnosticsPort: UInt16 { port + 2 }
    var diagnosticsURL: String { "http://127.0.0.1:\(diagnosticsPort)/mcp" }
    private var supervisor: EngineSupervisor? { runtime?.supervisor }
    private var server: WebSocketServer?
    private var codeAnswer: CheckedContinuation<String?, Never>?
    private var signInTask: _Concurrency.Task<Void, Never>?
    /// The sign-in on screen: a cancelled one finishing late must not touch a newer one's sheet.
    private var signInAttempt = UUID()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let id = Bundle.main.bundleIdentifier ?? "com.objectivecoder.agneta.dev"
        let environment = ProcessInfo.processInfo.environment
        // Any build can run isolated (tests, design review, a release's smoke test): its own data root,
        // Keychain service and ports, so nothing touches the user's own Agneta or another instance. Only whoever
        // starts the program can set this; an app opened from Finder never has it.
        if let home = environment["AGNETA_HOME"] {
            let root = URL(filePath: home, directoryHint: .isDirectory)
            store = AgnetaStore(root: root)
            keychain = Keychain(service: IsolatedInstance.keychainService(bundleID: id, home: root))
            do { port = try IsolatedInstance.port(environment["AGNETA_PORT"]) } catch {
                port = 0
                portProblem = "\(error)"
            }
            isolated = true
        } else {
            store = AgnetaStore(root: support.appending(path: id, directoryHint: .isDirectory))
            keychain = Keychain(service: id)
            port = id.hasSuffix(".dev") ? 47331 : 47321
            isolated = false
        }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        log = OperationalLog(folder: isolated ? store.root.appending(path: "Logs", directoryHint: .isDirectory)
                                              : library.appending(path: "Logs/\(id.hasSuffix(".dev") ? "Agneta Dev" : "Agneta")", directoryHint: .isDirectory))
    }

    var dataFolder: URL { store.root }

    // MARK: Paths inside the app bundle

    private var bundleFolder: URL { Bundle.main.bundleURL.appending(path: "Contents/MacOS", directoryHint: .isDirectory) }
    var gooseURL: URL { bundleFolder.appending(path: "goose-acp") }
    var openCodeURL: URL { bundleFolder.appending(path: "opencode") }
    /// The installed claude-agent-acp (downloaded on first use, version from the bundled runtimes.lock).
    var claudeAdapterURL: URL? {
        guard let data = try? Data(contentsOf: runtimeLock), let version = (try? JSONCoding.decode(data))?["claude-agent-acp"]?["version"]?.stringValue else { return nil }
        let url = store.runtimesFolder.appending(path: "claude-agent-acp/\(version)/claude-agent-acp")
        return FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// The user's Claude Code and Codex installs, newest first. Looked up at launch and when Settings opens
    /// (the lookup runs each one's `--version`), never while drawing.
    private(set) var claudeCodeInstalls: [InstalledCLI] = []
    private(set) var codexInstalls: [InstalledCLI] = []

    func refreshInstalls() {
        _Concurrency.Task {
            let found = await Self.lookUpInstalls()
            guard found.0 != claudeCodeInstalls || found.1 != codexInstalls else { return }
            (claudeCodeInstalls, codexInstalls) = found
            for engine in availableEngines { await supervisor?.register(engine) }
        }
    }

    /// Off the main thread and the task pool: each install's `--version` may take up to 5 s.
    nonisolated static func lookUpInstalls() async -> ([InstalledCLI], [InstalledCLI]) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: (CLILocator.claudeCode(), CLILocator.codex())) }
        }
    }

    /// The install the user chose in Settings (by path), else the newest; only ones new enough for Agneta.
    private(set) var chosenCLI: [String: String] = [:]
    func chosen(_ name: String, from installs: [InstalledCLI]) -> InstalledCLI? {
        let usable = installs.filter(\.supported)
        return usable.first { $0.id == chosenCLI[name] } ?? usable.first
    }

    /// New engines use this install from now on; running ones keep theirs.
    func choose(_ name: String, install: InstalledCLI) {
        chosenCLI[name] = install.id
        try? database?.set(install.id, for: "cli.\(name)")
        log.log("cli-chosen", ["cli": .string(name), "version": install.version.map(JSONValue.string) ?? .null, "source": .string(install.source)])
        _Concurrency.Task { for engine in availableEngines { await supervisor?.register(engine) } }
    }

    /// The engines this Agneta can run now: its own, plus Claude Code when the user has it.
    var availableEngines: [any EngineAdapter] {
        var engines: [any EngineAdapter] = [GooseAdapter(executable: gooseURL)]
        if FileManager.default.isExecutableFile(atPath: openCodeURL.path(percentEncoded: false)) { engines.append(OpenCodeAdapter(executable: openCodeURL)) }
        if let adapter = claudeAdapterURL, let cli = chosen("claude", from: claudeCodeInstalls) { engines.append(ClaudeCodeAdapter(executable: adapter, cli: cli)) }
        let node = bundleFolder.appending(path: "node"), script = Bundle.main.bundleURL.appending(path: "Contents/Resources/codex-acp/dist/index.js")
        if FileManager.default.isExecutableFile(atPath: node.path(percentEncoded: false)), FileManager.default.fileExists(atPath: script.path(percentEncoded: false)),
           let cli = chosen("codex", from: codexInstalls) {
            engines.append(CodexAdapter(node: node, script: script, cli: cli))
        }
        return engines
    }

    /// Engines an account can use: API keys run on any engine; plans on the engine their sign-in belongs to.
    func engines(for account: AccountRecord) -> [any EngineAdapter] {
        switch account.kind {
        case .openAIKey: availableEngines.filter { $0.id != "claude-code" }
        case .anthropicKey: availableEngines.filter { $0.id != "codex" }
        case .chatGPT: availableEngines.filter { $0.id == "codex" }
        case .claude: availableEngines.filter { ["goose", "claude-code"].contains($0.id) }
        }
    }

    /// New tasks on this account run on this engine; running ones keep theirs.
    func setEngine(_ account: AccountRecord, _ engine: String) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }), engines(for: account).contains(where: { $0.id == engine }) else { return }
        accounts[index].engine = engine
        log.log("engine-changed", ["account": .string(account.id), "engine": .string(engine)])
        save(accounts[index])
    }
    var shellToolURL: URL { bundleFolder.appending(path: "agneta-shell") }
    var runtimeLock: URL { Bundle.main.url(forResource: "runtimes", withExtension: "lock") ?? bundleFolder.appending(path: "runtimes.lock") }
    var testClientURL: URL? { Bundle.main.url(forResource: "AgnetaTestClient", withExtension: "app") }

    // MARK: Start and stop

    func start() async {
        // An interrupted reset finishes before anything else starts.
        let reset = makeReset()
        if reset.isInterrupted {
            await finishReset(reset)
            guard resetProblem == nil else { return }
        }
        log.log("start", ["version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"),
                          "development": .bool(isDevelopment), "isolated": .bool(isolated), "port": .int(Int64(port))])
        // The engines are registered again once the user's chosen Claude Code and Codex are known.
        let runtime: AgnetaRuntime
        do {
            runtime = try await AgnetaRuntime(.init(store: store, engines: availableEngines, shellTool: shellToolURL, appWorkspaces: appWorkspaces),
                                              log: log) { [weak self] request in await self?.askForApproval(request) }
        } catch let error as StoreError {
            storeProblem = error.description
            log.error("store-unavailable", ["reason": .string(error.description)])
            return
        } catch {
            storeProblem = "Agneta couldn't open its data (\(error.localizedDescription))."
            log.error("store-unavailable", ["reason": .string(error.localizedDescription)])
            return
        }
        self.runtime = runtime
        recovered = runtime.recovered
        let database = runtime.database
        accounts = (try? database.accounts()) ?? []
        grants = (try? database.grants()) ?? [:]
        historyDays = await runtime.historyDays
        for name in ["claude", "codex"] { if let path = try? database.setting("cli.\(name)") { chosenCLI[name] = path } }
        (claudeCodeInstalls, codexInstalls) = await Self.lookUpInstalls()
        for engine in availableEngines { await runtime.supervisor.register(engine) }
        await runtime.observe { [weak self] event in _Concurrency.Task { @MainActor in self?.handle(event) } }
        reloadHistory()
        for account in accounts { await configure(account) }

        if let portProblem {
            serverProblem = portProblem
            log.error("server-unavailable", ["reason": .string(portProblem)])
        } else {
            await listen(runtime.router)
        }
        if let token = keychain.get(Self.diagnosticsAccount) { await startDiagnostics(token) }
    }

    /// Opens the connection apps use, served by `router`.
    private func listen(_ router: Router) async {
        do {
            let server = try WebSocketServer(port: port)
            try await server.start()
            self.server = server
            _Concurrency.Task.detached { for await connection in server.connections { _Concurrency.Task { await router.serve(connection) } } }
        } catch {
            serverProblem = "Agneta couldn't open its connection for apps (port \(port) may be in use)."
            log.error("server-unavailable", ["port": .int(Int64(port)), "reason": .string("\(error)")])
        }
    }

    func stopEverything() async {
        log.log("stop", ["runningTasks": .int(Int64(tasks.count))])
        defer { log.flush() }
        diagnostics?.stop()
        server?.stop()
        // Quitting stops running work; the runtime records it.
        await runtime?.stopAll()
    }

    // MARK: Account settings

    func rename(_ account: AccountRecord, to label: String) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].label = label
        save(accounts[index])
    }

    /// A paused account starts nothing new; a turn already running finishes (Router.setPaused).
    func setPaused(_ account: AccountRecord, _ isPaused: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].paused = isPaused
        save(accounts[index])
    }

    /// The model new tasks on this account start with (nil: the provider's default). Running engines keep theirs.
    func setDefaultModel(_ account: AccountRecord, _ model: String?) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[index].model = trimmed?.isEmpty == false ? trimmed : nil
        save(accounts[index])
    }

    private func save(_ account: AccountRecord) {
        try? database?.save(account)
        _Concurrency.Task { await configure(account) }
    }

    private func installer() -> RuntimeInstaller { RuntimeInstaller(lockFile: runtimeLock, runtimes: store.runtimesFolder) }

    /// Tells the supervisor and router how to serve an account: its engine and its provider.
    /// Reset may replace the router and supervisor while this waits (an adapter download), and the user may sign the
    /// account out: it stops at the first wait after either, so a deleted account is never added back.
    private func configure(_ account: AccountRecord) async {
        guard let runtime else { return }
        func current() -> Bool { self.runtime === runtime && accounts.contains { $0.id == account.id } }
        let home = store.home(of: account)
        let provider: ProviderSetup
        var runner = Router.ToolRunner.brokered
        var billing = "api-key"
        switch account.kind {
        case .chatGPT:
            provider = ProviderSetup(kind: .chatGPT, model: account.model, subscription: SubscriptionAccount(route: .chatGPT, home: home))
            billing = "subscription"
            // ChatGPT plans run on Codex only; an account from before runs there now (signing in again if Codex hasn't).
            if account.engine != "codex", let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].engine = "codex"
                save(accounts[index])
                return await configure(accounts[index])
            }
        case .claude:
            let adapter = try? await installer().install("claude-agent-acp")
            guard current() else { return }
            for engine in availableEngines { await runtime.supervisor.register(engine) }
            provider = ProviderSetup(kind: .claudeCode, model: account.model,
                                     subscription: SubscriptionAccount(route: .claudeCode, home: home, adapter: adapter,
                                                                       claudeCode: chosen("claude", from: claudeCodeInstalls)?.path))
            runner = .native // Claude Code runs its own tools; Agneta gates each call
            billing = "subscription"
        case .anthropicKey:
            provider = ProviderSetup(kind: .anthropic, model: account.model, apiKey: keychain.get(account.id))
        case .openAIKey:
            provider = ProviderSetup(kind: .openAI, model: account.model, apiKey: keychain.get(account.id))
        }
        guard current() else { return }
        for secret in provider.secrets { runtime.traces.mask.register(secret) }
        // Claude Code and Codex run their own tools; Agneta answers their permission requests from the policy.
        if ["claude-code", "codex"].contains(account.engine) { runner = .native }
        await runtime.serve(account: account.id, label: account.label, setup: AccountSetup(engine: account.engine, provider: provider),
                            runner: runner, kind: account.kind.rawValue, billing: billing, paused: account.paused)
    }

    // MARK: Events from the router

    /// What the runtime reports, already recorded: this keeps what the windows show.
    private func handle(_ event: AgnetaRuntime.Event) {
        switch event {
        case .historyChanged:
            reloadHistory()
        case .traceProblem(_, let reason):
            traceProblem = reason
        case .router(let event):
            handle(event)
        }
    }

    private func handle(_ event: Router.Event) {
        switch event {
        case .paired(let hash, let grant):
            log.log("paired", ["grant": .string(grant.id), "app": .string(grant.app), "verified": .bool(grant.verified), "accounts": .int(Int64(grant.accounts.count)),
                               "tools": .string(grant.tools.rawValue), "folders": .int(Int64(grant.folders.count)), "remembered": .bool(grant.remembered)])
            // Saved by the router before the token went out; an "Allow Once" grant is never saved or listed.
            if grant.remembered { grants[hash] = grant }
        case .sessionStarted(let info):
            log.log("task-started", ["task": .string(info.id), "app": .string(info.app), "account": .string(info.account), "resumed": .bool(info.resumed)])
            tasks.append(Task(id: info.id, app: info.app, appIdentifier: info.appIdentifier, account: info.account, title: info.title, started: info.started, running: false, stopWarning: info.stopWarning))
        case .turnStarted(let id):
            if let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index].running = true }
        case .turnEnded(let id, let reason):
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].running = false
                // A turn that got through means the account's limit has passed.
                if reason != "error" { limited[tasks[index].account] = nil }
            }
            log.log("turn-ended", ["task": .string(id), "stopReason": .string(reason)])
        case .sessionEnded(let id, let ending):
            tasks.removeAll { $0.id == id }
            log.log("task-ended", ["task": .string(id), "ending": .string(ending.rawValue)])
        case .planUsage(let account, let limits):
            planUsage[account] = PlanUsage.describe(limits)
        case .pairingWithdrawn(let request):
            settleApproval(request, with: nil)
        case .needsSignIn(let account):
            needsSignIn.insert(account)
            log.log("needs-sign-in", ["account": .string(account)])
        case .rateLimited(let account, let resetsAt, _):
            limited[account] = resetsAt
            log.log("rate-limited", ["account": .string(account), "resetsAt": resetsAt.map { .string(TraceWriter.timestamp($0)) } ?? .null])
        case .usage(let id, _, let cost):
            if let index = tasks.firstIndex(where: { $0.id == id }), let cost { tasks[index].cost = cost }
        }
    }

    // MARK: Tasks

    func stop(_ task: Task) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].stopping = true
        guard let runtime else { return }
        _Concurrency.Task { await runtime.stop(task: task.id) }
    }

    func label(ofAccount id: String) -> String { accounts.first { $0.id == id }?.label ?? id }
    func account(_ id: String) -> AccountRecord? { accounts.first { $0.id == id } }

    // MARK: App access

    private func askForApproval(_ pairing: Router.PairingRequest) async -> Router.PairingAnswer? {
        await withCheckedContinuation { continuation in
            // One account to start with: the user adds more deliberately.
            let request = Approval(id: pairing.id, app: pairing.app, identifier: pairing.peer?.identifier, verified: pairing.code == nil,
                                   code: pairing.code ?? "", choices: accounts, allowed: Set(accounts.first { !$0.paused }.map { [$0.id] } ?? []),
                                   tools: pairing.tools, folders: pairing.folders)
            if approvals.add(id: pairing.id, request, answer: { continuation.resume(returning: $0) }) {
                WindowPresenter.shared.showApproval(self, request: pairing.id)
            }
            _Concurrency.Task { [weak self] in
                try? await _Concurrency.Task.sleep(for: Self.approvalTimeout)
                self?.settleApproval(pairing.id, with: nil)
            }
        }
    }

    /// The user's answer to the request on screen: nil for Don't Allow, else Allow Once (`remember` false) or Always Allow.
    func answerApproval(remember: Bool?) {
        guard let pending = approvals.current else { return }
        // In account order, so "the first allowed account" (the default for new sessions) is stable.
        let answer = remember.map { Router.PairingAnswer(accounts: accounts.map(\.id).filter { pending.allowed.contains($0) }, remember: $0) }
        settleApproval(pending.id, with: answer)
    }

    /// Answers a pairing request, shown or waiting; nil is Don't Allow. Answering one already answered does nothing.
    func settleApproval(_ id: UUID, with answer: Router.PairingAnswer?) {
        guard approvals.answer(id, with: answer) else { return }
        WindowPresenter.shared.closeApproval()
        if let next = approvals.current {
            DispatchQueue.main.async { WindowPresenter.shared.showApproval(self, request: next.id) }
        }
    }

    func removeAccess(_ grantID: String) {
        grants = grants.filter { $0.value.id != grantID }
        guard let runtime else { return }
        let log = log
        _Concurrency.Task {
            do { try await runtime.revoke(grant: grantID) } catch {
                log.error("revoke-not-saved", ["grant": .string(grantID), "reason": .string("\(error)")])
            }
        }
    }

    // MARK: Accounts

    /// Signs in a new account, or `again` signs an existing one in again (same account, folder and settings).
    func startSignIn(_ kind: AccountKind, again existing: AccountRecord? = nil) {
        abandonSignIn()
        let attempt = UUID()
        signInAttempt = attempt
        var record = existing ?? AccountRecord(kind: kind, label: kind.provider)
        if existing == nil, accounts.contains(where: { $0.kind == kind }) { record.label = "\(kind.provider) \(accounts.filter { $0.kind.provider == kind.provider }.count + 1)" }
        let home = store.home(of: record)
        signIn = SignIn(kind: kind, text: "Starting…")
        WindowPresenter.shared.showSignIn(self, attempt: attempt)
        signInTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            let progress: SignInProgress = { step in _Concurrency.Task { @MainActor in self.show(step, attempt: attempt) } }
            do {
                switch kind {
                case .chatGPT:
                    // A ChatGPT plan runs on the user's own Codex, signed in with Codex's own login.
                    guard let cli = chosen("codex", from: codexInstalls) else {
                        throw SignInError.provider(codexInstalls.isEmpty ? "Codex isn't installed. Install Codex, then try again"
                                                   : "Your Codex is older than \(CLILocator.codexMinimum), which Agneta needs. Update Codex, then try again")
                    }
                    try await CodexSignIn(cli: cli.path, codexHome: CodexAdapter.codexHome(account: home))
                        .run(progress: progress)
                    record.engine = "codex"
                case .claude:
                    // The user's own Claude Code signs in; the adapter its engines run it through is fetched now too.
                    guard let cli = chosen("claude", from: claudeCodeInstalls) else {
                        throw SignInError.provider("Claude Code isn't installed. Install the Claude app or Claude Code, then try again")
                    }
                    _ = try await installer().install("claude-agent-acp", progress: progress)
                    try await ClaudeCodeSignIn(cli: cli.path, configDirectory: home.appending(path: "claude", directoryHint: .isDirectory))
                        .run(progress: progress, code: { await self.waitForCode() })
                default: return
                }
                guard signInAttempt == attempt, !_Concurrency.Task.isCancelled else { return }
                log.log("signed-in", ["account": .string(record.id), "kind": .string(kind.rawValue)])
                // A new Claude plan runs on the user's own Claude Code when it's on this Mac (model choice, exact usage).
                if existing == nil, kind == .claude, availableEngines.contains(where: { $0.id == "claude-code" }) { record.engine = "claude-code" }
                if let index = accounts.firstIndex(where: { $0.id == record.id }) { accounts[index] = record } else { accounts.append(record) }
                needsSignIn.remove(record.id)
                try? database?.save(record)
                await configure(record)
                signIn?.finished = true
                signIn?.text = "\(kind.provider) is connected."
            } catch {
                if signInFailed(error, attempt: attempt) {
                    log.error("sign-in-failed", ["kind": .string(kind.rawValue), "reason": .string(String(describing: type(of: error)))])
                }
            }
        }
    }

    /// Shows a sign-in's failure on its own sheet; a cancelled or replaced one shows nothing. True when shown.
    @discardableResult
    private func signInFailed(_ error: Error, attempt: UUID) -> Bool {
        guard signInAttempt == attempt else { return false }
        if error is CancellationError || (error as? SignInError) == .cancelled {
            signIn = nil
            return false
        }
        signIn?.failed = "\(error)"
        return true
    }

    private func show(_ step: SignInStep, attempt: UUID) {
        guard signIn != nil, signInAttempt == attempt else { return }
        switch step {
        case .openBrowser(let url):
            signIn?.page = url
            NSWorkspace.shared.open(url)
        case .browserOpened(let url):
            signIn?.page = url
        case .confirmCode(let code, let page, _):
            signIn?.page = page
            signIn?.text = "Confirm the code \(code) on the page that opened."
            NSWorkspace.shared.open(page)
        case .pasteCode(let text):
            signIn?.needsCode = true
            signIn?.text = text
        case .waiting(let text):
            signIn?.text = text
        case .signedIn:
            break
        }
    }

    private func waitForCode() async -> String? {
        await withCheckedContinuation { codeAnswer = $0 }
    }

    func submitCode(_ code: String) {
        signIn?.needsCode = false
        signIn?.text = "Checking the code…"
        codeAnswer?.resume(returning: code)
        codeAnswer = nil
    }

    func cancelSignIn() {
        abandonSignIn()
        signIn = nil
        WindowPresenter.shared.closeSignIn()
    }

    /// Stops the sign-in under way: its code prompt answered (nobody will type it), its task cancelled, its attempt retired.
    private func abandonSignIn() {
        codeAnswer?.resume(returning: nil)
        codeAnswer = nil
        signInTask?.cancel()
        signInTask = nil
        signInAttempt = UUID()
    }

    /// The sign-in window closed: closing it is cancelling, unless that sign-in finished or another replaced it.
    func signInWindowClosed(_ attempt: UUID) {
        guard signInAttempt == attempt, signIn?.finished != true else { return }
        abandonSignIn()
        signIn = nil
    }

    func addAPIKey(_ kind: AccountKind, key: String) async throws {
        let record = AccountRecord(kind: kind, label: kind == .anthropicKey ? "Claude API" : "OpenAI API")
        try keychain.set(key, for: record.id)
        accounts.append(record)
        try database?.save(record)
        await configure(record)
    }

    func signOut(_ account: AccountRecord) {
        log.log("signed-out", ["account": .string(account.id), "kind": .string(account.kind.rawValue)])
        accounts.removeAll { $0.id == account.id }
        try? database?.deleteAccount(account.id)
        keychain.delete(account.id)
        guard let runtime else { return }
        let home = store.home(of: account)
        _Concurrency.Task {
            await runtime.remove(account: account.id)
            if account.kind == .claude { await self.signOutOfClaudeCode(homes: [home]) }
            try? FileManager.default.removeItem(at: home)
        }
    }

    // MARK: History

    private func reloadHistory() {
        guard let runtime else { return }
        _Concurrency.Task { history = await runtime.history() }
    }

    func clearHistory() {
        guard let runtime else { return }
        _Concurrency.Task { await runtime.clearHistory() }
    }

    func setHistoryDays(_ days: Int) {
        historyDays = days
        guard let runtime else { return }
        _Concurrency.Task { await runtime.setHistoryDays(days) }
    }

    // MARK: Diagnostics for tools

    static let diagnosticsAccount = "diagnostics-token"

    /// Lets diagnostic tools (Claude Code, scripts) read task traces over MCP with a new token.
    func allowDiagnostics() async {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = "agd_" + Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
        do { try keychain.set(token, for: Self.diagnosticsAccount) } catch {
            diagnosticsProblem = "Agneta couldn't store the token in the Keychain."
            return
        }
        diagnostics?.stop()
        diagnostics = nil
        await startDiagnostics(token)
    }

    func stopDiagnostics() {
        log.log("diagnostics-off")
        diagnostics?.stop()
        diagnostics = nil
        diagnosticsToken = nil
        keychain.delete(Self.diagnosticsAccount)
    }

    private func startDiagnostics(_ token: String) async {
        guard let traces, portProblem == nil else { return }
        let server = DiagnosticsMCP(traces: traces, root: store.root, token: token, log: log)
        do {
            try await server.start(port: diagnosticsPort)
            diagnostics = server
            diagnosticsToken = token
            diagnosticsProblem = nil
            log.log("diagnostics-on", ["port": .int(Int64(diagnosticsPort))])
        } catch {
            diagnosticsToken = token
            diagnosticsProblem = "Port \(diagnosticsPort) is in use, so diagnostic tools can't connect."
        }
    }

    // MARK: Reset

    private var logsFolder: URL { log.folder }

    private func makeReset() -> Reset {
        if isolated { return Reset(root: store.root, folders: [store.root, appWorkspaces], keychain: keychain) }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: bundleID, directoryHint: .isDirectory)
        return Reset(root: store.root, folders: [store.root, appWorkspaces, caches, logsFolder], keychain: keychain)
    }

    /// Each paired app's own workspace (`<this>/<grant id>`), beside Agneta's data rather than in it: sessions may
    /// never reach Agneta's data, but an app's workspace is where its sessions work.
    var appWorkspaces: URL {
        store.root.deletingLastPathComponent().appending(path: store.root.lastPathComponent + " Workspaces", directoryHint: .isDirectory)
    }

    /// Reset Agneta: refuse new tasks, stop every engine, delete Agneta's
    /// Keychain items, data, caches, logs, preferences and login item, then show first run.
    func resetAgneta() async {
        let reset = makeReset()
        log.log("reset-started")
        log.flush()
        resetting = true
        resetProblem = nil
        do { try reset.begin() } catch {
            resetProblem = "Agneta couldn't start the reset (\(error.localizedDescription))."
            resetting = false
            return
        }
        diagnostics?.stop()
        diagnostics = nil
        diagnosticsToken = nil
        server?.stop()
        server = nil
        await runtime?.shutdown()
        runtime = nil
        accounts = []; grants = [:]; tasks = []; history = []; needsSignIn = []
        approvals.refuseAll()
        WindowPresenter.shared.closeApproval()
        abandonSignIn()
        signIn = nil; serverProblem = nil; storeProblem = nil
        await finishReset(reset)
        guard resetProblem == nil else { return }
        await start()
        WindowPresenter.shared.showWelcome(self)
    }

    /// The steps after engines are stopped; also resumes an interrupted reset at launch.
    private func finishReset(_ reset: Reset) async {
        resetting = true
        defer { resetting = false }
        // A reset interrupted at launch may have left engines from that run.
        if database == nil, let leftover = try? AgnetaDatabase(file: store.databaseFile) {
            let recorded = (try? leftover.recordedEngines()) ?? []
            _ = await EngineReaper.reap(recorded)
            try? leftover.close()
        }
        await signOutOfClaudeCode(homes: accountHomes)
        do {
            try reset.wipe()
        } catch {
            resetProblem = error.description
            log.error("reset-failed", ["step": .string(error.description)])
            return
        }
        if !isolated {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            if SMAppService.mainApp.status == .enabled { try? await SMAppService.mainApp.unregister() }
        }
        reset.finish()
        resetProblem = nil
        log.log("reset-finished")
    }

    /// Claude Code keeps each account's sign-in in the login Keychain, keyed by the account's folder.
    /// Its own logout removes it; deleting the folder alone would leave it behind.
    private func signOutOfClaudeCode(homes: [URL]) async {
        let claudeHomes = homes.filter { FileManager.default.fileExists(atPath: $0.appending(path: "claude").path(percentEncoded: false)) }
        guard !claudeHomes.isEmpty, let cli = chosen("claude", from: claudeCodeInstalls) else { return }
        for home in claudeHomes {
            await ClaudeCodeSignIn(cli: cli.path, configDirectory: home.appending(path: "claude", directoryHint: .isDirectory)).signOut()
        }
    }

    /// Every account folder on disk (Reset, including one resumed after an interruption).
    private var accountHomes: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: store.accountsFolder, includingPropertiesForKeys: nil)) ?? []).filter(\.hasDirectoryPath)
    }

    func retryReset() {
        _Concurrency.Task { await resetAgneta() }
    }

    // MARK: Status

    var status: String {
        if resetting { return "Resetting…" }
        if resetProblem != nil { return "Reset didn't finish" }
        if storeProblem != nil { return "Agneta needs an update" }
        if let problem = serverProblem { return problem.isEmpty ? "Something needs you" : "Apps can't connect" }
        if let first = accounts.first(where: { needsSignIn.contains($0.id) }) { return "\(first.label) needs you" }
        let running = tasks.filter(\.running).count
        if running > 0 { return running == 1 ? "1 task running" : "\(running) tasks running" }
        if !tasks.isEmpty { return tasks.count == 1 ? "1 task open" : "\(tasks.count) tasks open" }
        return accounts.isEmpty ? "Connect an AI account" : "All set"
    }

    var subtitle: String {
        let apps = Set(grants.values.map(\.app)).count
        let accountsText = accounts.count == 1 ? "1 account" : "\(accounts.count) accounts"
        return apps == 0 ? accountsText : "\(accountsText) · \(apps == 1 ? "1 app" : "\(apps) apps")"
    }

    var needsAttention: Bool { serverProblem != nil || !needsSignIn.isEmpty || resetProblem != nil || storeProblem != nil }

    /// The one thing that needs the user, as a title, a sentence and one action.
    var attentionMessage: (title: String, detail: String, action: String, run: () -> Void)? {
        if let problem = resetProblem {
            return ("Reset didn't finish", problem, "Try Again", { self.retryReset() })
        }
        if let problem = storeProblem {
            return ("Agneta needs an update", "\(problem) Install the latest Agneta; your data is kept as it is.", "Show Data",
                    { NSWorkspace.shared.activateFileViewerSelecting([self.store.databaseFile]) })
        }
        if let problem = serverProblem {
            return ("Apps can't connect", problem, "Settings", { WindowPresenter.shared.showSettings(self, section: .general) })
        }
        if let problem = traceProblem {
            return ("Task records are incomplete", "Agneta couldn't save a task's record (\(problem)). Tasks keep running; check that the disk has space.",
                    "Dismiss", { self.traceProblem = nil })
        }
        if let account = accounts.first(where: { needsSignIn.contains($0.id) }) {
            let kind = account.kind
            // The engine's own sign-in when the account runs on Codex; Agneta's otherwise.
            let action: () -> Void = { self.startSignIn(kind, again: account) }
            return ("Sign in to \(account.label) again", "Its sign-in expired. Tasks on this account wait until you sign in.", "Sign In", action)
        }
        return nil
    }

    // MARK: Developer

    /// Sample data for design snapshots (AGNETA_SHOWCASE).
    func loadSample() {
        accounts = [AccountRecord(id: "a", kind: .claude, label: "Claude", email: "work@example.com"),
                    AccountRecord(id: "b", kind: .chatGPT, label: "ChatGPT", email: "me@example.com"),
                    AccountRecord(id: "c", kind: .openAIKey, label: "OpenAI API")]
        tasks = [Task(id: "1", app: "Example App", appIdentifier: nil, account: "a", title: "Summarizing meeting notes", started: Date().addingTimeInterval(-840), running: true),
                 Task(id: "2", app: "Example App", appIdentifier: nil, account: "b", title: "Naming a project", started: Date(), running: true)]
        grants = ["h": Router.Grant(app: "Example App", identifier: "com.example.app", verified: true, accounts: ["a", "b"])]
        let sample = UUID()
        _ = approvals.add(id: sample, Approval(id: sample, app: "Example App", identifier: "com.example.app", verified: true, code: "123456",
                                               choices: accounts, allowed: ["a"], tools: .workspace,
                                               folders: [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Example Project")]),
                          answer: { _ in })
        signIn = SignIn(kind: .claude, text: "When Claude shows you a code, paste it here.", page: URL(string: "https://claude.com"), needsCode: true)
        history = [TaskRecord(id: "3", app: "Example App", account: "a", title: "Drafting release notes", started: Date().addingTimeInterval(-7_200),
                              ended: Date().addingTimeInterval(-6_100), outcome: .finished, turns: 6, cost: 0.42),
                   TaskRecord(id: "4", app: "Example App", account: "b", title: "Naming a folder", started: Date().addingTimeInterval(-90_000),
                              ended: Date().addingTimeInterval(-89_970), outcome: .finished, turns: 1),
                   TaskRecord(id: "5", app: "Example App", account: "a", title: "Checking a spreadsheet", started: Date().addingTimeInterval(-200_000),
                              ended: Date().addingTimeInterval(-199_000), outcome: .stopped, turns: 3, cost: 0.18)]
    }


    /// Starts the bundled sandboxed test client, which pairs and runs one small task.
    func runTestTask() {
        guard let client = testClientURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        // No folder of the user's: the test app works in the workspace Agneta gives it when it pairs.
        configuration.arguments = ["--port", String(port), "--prompt", "Reply with a friendly five-word greeting."]
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: client, configuration: configuration)
    }
}
