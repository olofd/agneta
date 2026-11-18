// Agneta's state for its UI: providers (accounts), app access, running tasks, history, reset and diagnostics.
// Underneath, the runtime (AgnetaKit's AgnetaRuntime) owns the router, the engines' processes and everything Agneta
// records; this model starts it, tells it which accounts to serve, and keeps what the windows show. Three parts have
// types of their own, which it holds: the engines on this Mac (EngineLibrary), apps asking for access (Approvals) and
// signing in to a plan (SignInFlow). The UI only reads these and calls their methods.
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
    /// The database couldn't be opened (for example, made by another build of Agneta).
    private(set) var storeProblem: String?
    /// Every engine: where each comes from, downloads, and each provider's default (EngineLibrary).
    let library: EngineLibrary
    /// What the last launch cleaned up after a crash, for one quiet line in Activity.
    private(set) var recovered: (engines: Int, tasks: Int) = (0, 0)
    /// The pairing request on screen; edits change its allowed accounts.
    /// Apps asking for access, one at a time.
    let approvals = Approvals()
    /// Signing in to a plan.
    let signIn: SignInFlow
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
    var isIsolated: Bool { isolated }
    /// Sparkle, for release builds (Updates.swift).
    let updates = Updates()
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
        let libraryFolder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        log = OperationalLog(folder: isolated ? store.root.appending(path: "Logs", directoryHint: .isDirectory)
                                              : libraryFolder.appending(path: "Logs/\(id.hasSuffix(".dev") ? "Agneta Dev" : "Agneta")", directoryHint: .isDirectory))
        library = EngineLibrary(runtimes: store.runtimesFolder, log: log)
        signIn = SignInFlow(library: library, log: log)
        library.kindsInUse = { [weak self] in Set(self?.accounts.map(\.kind) ?? []) }
        approvals.present = { [weak self] id in if let self { WindowPresenter.shared.showApproval(self, request: id) } }
        approvals.dismiss = { WindowPresenter.shared.closeApproval() }
        approvals.order = { [weak self] in self?.accounts.map(\.id) ?? [] }
        approvals.allowance = { [weak self] engines in self?.library.allowance(engines) ?? .all }
    }

    var dataFolder: URL { store.root }

    // MARK: Paths inside the app bundle

    private var bundleFolder: URL { Bundle.main.bundleURL.appending(path: "Contents/MacOS", directoryHint: .isDirectory) }
    var shellToolURL: URL { bundleFolder.appending(path: "agneta-shell") }
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
        let runtime: AgnetaRuntime
        do {
            runtime = try await AgnetaRuntime(.init(store: store, shellTool: shellToolURL, appWorkspaces: appWorkspaces),
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
        await library.start(runtime)
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

    /// Quitting: stops listening now, and returns the rest (stopping engines and recording their tasks), which needs
    /// nothing from the main actor. AppKit may wait for the quit's answer inside a main-queue job (when terminate
    /// was called from one: a menu action, Sparkle), and there no main-actor work can run until it's answered.
    func beginStopping() -> @Sendable () async -> Void {
        log.log("stop", ["runningTasks": .int(Int64(tasks.count))])
        diagnostics?.stop()
        server?.stop()
        let runtime = runtime, log = log
        return {
            // Quitting stops running work; the runtime records it.
            await runtime?.stopAll()
            log.flush()
        }
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
        case .claude:
            let adapter = try? await library.install("claude-code")
            guard current() else { return }
            provider = ProviderSetup(kind: .claudeCode, model: account.model,
                                     subscription: SubscriptionAccount(route: .claudeCode, home: home, adapter: adapter,
                                                                       claudeCode: library.program("claude")?.path))
            runner = .native // Claude Code runs its own tools; Agneta gates each call
            billing = "subscription"
        case .anthropicKey:
            provider = ProviderSetup(kind: .anthropic, model: account.model, apiKey: keychain.get(account.id))
        case .openAIKey:
            provider = ProviderSetup(kind: .openAI, model: account.model, apiKey: keychain.get(account.id))
        }
        guard current() else { return }
        for secret in provider.secrets { runtime.traces.mask.register(secret) }
        // Claude Code and Codex run their own tools whatever the account; the router decides per session, since each
        // task picks its engine (Router.runner(account:engine:)).
        await runtime.serve(account: account.id, label: account.label, provider: provider, runner: runner, kind: account.kind,
                            billing: billing, paused: account.paused)
        // Its default engine downloads now if it isn't here.
        library.refresh()
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
            // Saved by the router before the token went out; an "Allow Once" grant is never saved or listed. Pairing again
            // replaced the app's earlier token, if it had one.
            if grant.remembered {
                grants = grants.filter { $0.value.id != grant.id }
                grants[hash] = grant
            }
        case .grantChanged(let hash, let grant):
            log.log("app-access-changed", ["grant": .string(grant.id), "accounts": .int(Int64(grant.accounts.count)),
                                           "engines": { if case .only(let some) = grant.engines { .int(Int64(some.count)) } else { "all" } }()])
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
            approvals.settle(request, with: nil)
        case .needsSignIn(let account):
            needsSignIn.insert(account)
            log.log("needs-sign-in", ["account": .string(account)])
        case .rateLimited(let account, let resetsAt, _):
            limited[account] = resetsAt
            log.log("rate-limited", ["account": .string(account), "resetsAt": resetsAt.map { .string(TraceWriter.timestamp($0)) } ?? .null])
        case .usage(let id, _, let cost):
            if let index = tasks.firstIndex(where: { $0.id == id }), let cost { tasks[index].cost = cost }
        case .engineWanted(let engine):
            // A task asked for an engine that downloads first: it's told to try again shortly while this runs.
            library.download(engine, reason: "task")
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

    /// One provider ticked to start with (the user adds more deliberately), and every engine: the app picks per task.
    private func askForApproval(_ pairing: Router.PairingRequest) async -> Router.PairingAnswer? {
        let verified = pairing.code == nil
        let replaces = grants.values.contains {
            Router.sameApp($0, app: pairing.app, identifier: verified ? pairing.peer?.identifier : nil, team: verified ? pairing.peer?.team : nil, verified: verified)
        }
        return await approvals.ask(pairing, allowed: Set(accounts.first { !$0.paused }.map { [$0.id] } ?? []), engines: Set(library.catalog.entries.keys),
                                   replaces: replaces)
    }

    /// Changes which providers and engines an app may use (Settings → Apps). Its sessions that no longer fit stop.
    func setAccess(_ grant: Router.Grant, accounts allowed: Set<String>, engines: Set<String>) {
        guard let runtime, !allowed.isEmpty else { return }
        let accountIDs = accounts.map(\.id).filter(allowed.contains), allowance = library.allowance(engines)
        // Shown at once; the router's grantChanged confirms it (or Remove Access wins meanwhile).
        for (hash, shown) in grants where shown.id == grant.id {
            grants[hash]?.accounts = accountIDs
            grants[hash]?.engines = allowance
        }
        let log = log
        _Concurrency.Task {
            do { try await runtime.setAccess(grant: grant.id, accounts: accountIDs, engines: allowance) } catch {
                log.error("app-access-not-saved", ["grant": .string(grant.id), "reason": .string("\(error)")])
            }
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
        var record = existing ?? AccountRecord(kind: kind, label: kind.provider)
        if existing == nil, accounts.contains(where: { $0.kind == kind }) { record.label = "\(kind.provider) \(accounts.filter { $0.kind.provider == kind.provider }.count + 1)" }
        let attempt = signIn.start(kind, home: store.home(of: record), account: record.id) { [weak self] in
            guard let self else { return }
            if let index = accounts.firstIndex(where: { $0.id == record.id }) { accounts[index] = record } else { added(record) }
            needsSignIn.remove(record.id)
            try? database?.save(record)
            await configure(record)
        }
        WindowPresenter.shared.showSignIn(self, attempt: attempt)
    }

    /// Adds an API-key account. It names no engine: it runs on its provider's (Settings → Engines).
    func addAPIKey(_ kind: AccountKind, key: String) async throws {
        let record = AccountRecord(kind: kind, label: kind == .anthropicKey ? "Claude API" : "OpenAI API")
        try keychain.set(key, for: record.id)
        added(record)
        try database?.save(record)
        await configure(record)
    }

    /// A new provider. An app asking for access while there was none to offer gets it ticked.
    private func added(_ record: AccountRecord) {
        accounts.append(record)
        approvals.providerAdded(record.id)
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
            if account.kind == .chatGPT { await self.signOutOfCodex(homes: [home]) }
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
        library.reset()
        approvals.refuseAll()
        signIn.clear()
        serverProblem = nil; storeProblem = nil
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
        await signOutOfCodex(homes: accountHomes)
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
        guard !claudeHomes.isEmpty, let cli = library.program("claude") else { return }
        for home in claudeHomes {
            await ClaudeCodeSignIn(cli: cli.path, configDirectory: home.appending(path: "claude", directoryHint: .isDirectory)).signOut()
        }
    }

    /// Codex keeps each ChatGPT account's sign-in in the login Keychain, keyed by the account's CODEX_HOME. Its own
    /// logout removes it.
    private func signOutOfCodex(homes: [URL]) async {
        let codexHomes = homes.map(CodexAdapter.codexHome(account:)).filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard !codexHomes.isEmpty else { return }
        // Codex's own logout removes its Keychain entry; without a Codex install it can't run, and the entry stays.
        guard let cli = library.program("codex") else {
            log.error("codex-sign-out-skipped", ["accounts": .int(Int64(codexHomes.count)), "reason": "no supported Codex install"])
            return
        }
        for home in codexHomes { await CodexSignIn(cli: cli.path, codexHome: home).signOut() }
    }

    /// Every account folder on disk (Reset, including one resumed after an interruption).
    private var accountHomes: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: store.accountsFolder, includingPropertiesForKeys: nil)) ?? []).filter(\.hasDirectoryPath)
    }

    /// Asks before Reset Agneta: Cancel is the default, resetting takes a deliberate click.
    func confirmReset() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Reset Agneta?"
        alert.informativeText = """
            Running tasks stop. Agneta deletes, on this Mac: your providers' sign-ins and API keys, every app's access, task history, logs, downloaded components and preferences.

            It doesn't cancel subscriptions or delete anything your AI providers keep. Apps will ask to connect again.
            """
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset Agneta")
        alert.buttons.last?.hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn { _Concurrency.Task { await resetAgneta() } }
    }

    func retryReset() {
        _Concurrency.Task { await resetAgneta() }
    }

    // MARK: Status

    var status: String {
        if resetting { return "Resetting…" }
        if resetProblem != nil { return "Reset didn't finish" }
        if storeProblem != nil { return "Agneta needs a reset" }
        if let problem = serverProblem { return problem.isEmpty ? "Something needs you" : "Apps can't connect" }
        if let first = accounts.first(where: { needsSignIn.contains($0.id) }) { return "\(first.label) needs you" }
        let running = tasks.filter(\.running).count
        if running > 0 { return running == 1 ? "1 task running" : "\(running) tasks running" }
        if !tasks.isEmpty { return tasks.count == 1 ? "1 task open" : "\(tasks.count) tasks open" }
        return accounts.isEmpty ? "Connect a provider" : "All set"
    }

    var subtitle: String {
        let apps = Set(grants.values.map(\.app)).count
        let accountsText = accounts.count == 1 ? "1 provider" : "\(accounts.count) providers"
        return apps == 0 ? accountsText : "\(accountsText) · \(apps == 1 ? "1 app" : "\(apps) apps")"
    }

    var needsAttention: Bool { serverProblem != nil || !needsSignIn.isEmpty || resetProblem != nil || storeProblem != nil }

    /// The one thing that needs the user, as a title, a sentence and one action.
    var attentionMessage: (title: String, detail: String, action: String, run: () -> Void)? {
        if let problem = resetProblem {
            return ("Reset didn't finish", problem, "Try Again", { self.retryReset() })
        }
        if let problem = storeProblem {
            // Before 1.0 no build reads another's data: Reset starts fresh.
            return ("Agneta needs a reset", "\(problem) Reset Agneta to start fresh; you'll connect your providers and allow your apps again.", "Reset…",
                    { self.confirmReset() })
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
            return ("Sign in to \(account.label) again", "Its sign-in expired. Tasks on it wait until you sign in.", "Sign In", action)
        }
        return nil
    }

    // MARK: Developer

    /// Sample data for design snapshots (AGNETA_SHOWCASE).
    func loadSample() {
        library.useSample()
        accounts = [AccountRecord(id: "a", kind: .claude, label: "Claude", email: "work@example.com"),
                    AccountRecord(id: "b", kind: .chatGPT, label: "ChatGPT", email: "me@example.com"),
                    AccountRecord(id: "c", kind: .openAIKey, label: "OpenAI API")]
        tasks = [Task(id: "1", app: "Example App", appIdentifier: nil, account: "a", title: "Summarizing meeting notes", started: Date().addingTimeInterval(-840), running: true),
                 Task(id: "2", app: "Example App", appIdentifier: nil, account: "b", title: "Naming a project", started: Date(), running: true)]
        grants = ["h": Router.Grant(app: "Example App", identifier: "com.example.app", verified: true, accounts: ["a", "b", "c"])]
        let sample = UUID()
        approvals.addSample(Approvals.Request(id: sample, app: "Example App", identifier: "com.example.app", verified: true, code: "123456",
                                              allowed: ["a", "c"], engines: Set(library.catalog.entries.keys), tools: .workspace,
                                              folders: [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Example Project")]))
        signIn.showSample(SignInFlow.State(kind: .claude, text: "When Claude shows you a code, paste it here.", page: URL(string: "https://claude.com"), needsCode: true))
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
