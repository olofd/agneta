// Agneta's runtime: the engines, the router and what lasts (grants, task history, traces and engine homes),
// wired together. It records grants and every task's transitions itself, in the order they happened, cleans up
// after a crash, and removes what a task leaves behind when it leaves history. A host (the menu bar app, agnetad)
// opens it, says which accounts to serve, and observes its events: it never writes Agneta's records itself.
import Foundation

public actor AgnetaRuntime {
    public enum Event: Sendable {
        /// What the router reported, after the runtime recorded it.
        case router(Router.Event)
        /// Task history changed: read it again.
        case historyChanged
        /// A task's trace can't be written any more (the disk is full, the file went away).
        case traceProblem(task: String, reason: String)
    }

    public struct Configuration: Sendable {
        public var store: AgnetaStore
        public var engines: [any EngineAdapter]
        public var shellTool: URL
        /// Where each paired app's own workspace is made, if apps get one.
        public var appWorkspaces: URL?
        /// Loopback ports engines may reach besides the apps' tool servers (a local model).
        public var engineLoopbackPorts: [Int]
        public var concurrency: Router.Concurrency

        public init(store: AgnetaStore, engines: [any EngineAdapter], shellTool: URL, appWorkspaces: URL? = nil,
                    engineLoopbackPorts: [Int] = [], concurrency: Router.Concurrency = .init()) {
            self.store = store
            self.engines = engines
            self.shellTool = shellTool
            self.appWorkspaces = appWorkspaces
            self.engineLoopbackPorts = engineLoopbackPorts
            self.concurrency = concurrency
        }
    }

    public nonisolated let router: Router
    public nonisolated let supervisor: EngineSupervisor
    public nonisolated let traces: Traces
    public nonisolated let database: AgnetaDatabase
    /// What opening found after a crash: engines it stopped, and tasks it marked interrupted.
    public nonisolated let recovered: (engines: Int, tasks: Int)
    private let store: AgnetaStore
    private let log: OperationalLog?
    private var observer: @Sendable (Event) -> Void = { _ in }
    /// Running tasks, and how each last turn ended: with how the task ended, its outcome in history.
    private var running: [String: String?] = [:]
    /// Days of task history kept; 0 keeps none.
    public private(set) var historyDays: Int
    private var consumer: Task<Void, Never>?
    private var housekeeping: Task<Void, Never>?
    private let finish: @Sendable () -> Void

    /// Opens Agneta's data (throwing `StoreError` when it can't), stops engines and marks tasks a crash left behind,
    /// applies retention, and starts the router with the saved grants. `approve` decides pairing requests.
    public init(_ configuration: Configuration, log: OperationalLog? = nil, approve: @escaping Router.Approve) async throws {
        let store = configuration.store
        let database = try store.open()
        if let workspaces = configuration.appWorkspaces { try AgnetaStore.ownerOnly(workspaces) }
        // After a crash: stop engines the last run left behind (by recorded pid and start time, never by name),
        // and mark its unfinished tasks. Nothing is replayed.
        let recorded = Self.attempt(log, "read-engines") { try database.recordedEngines() } ?? []
        let stopped = await EngineReaper.reap(recorded)
        for engine in recorded { Self.attempt(log, "forget-engine") { try database.forgetEngine(pid: engine.pid) } }
        let interrupted = Self.attempt(log, "interrupt-tasks") { try database.interruptUnfinishedTasks() } ?? 0
        if stopped.count + interrupted > 0 { log?.log("recovered", ["engines": .int(Int64(stopped.count)), "tasks": .int(Int64(interrupted))]) }

        let traces = Traces(folder: store.tracesFolder)
        let supervisor = EngineSupervisor(.init(engines: configuration.engines, shellTool: configuration.shellTool, root: store.root,
                                                engineLoopbackPorts: configuration.engineLoopbackPorts, ledger: database, traces: traces))
        let router = Router(context: PolicyContext(userHome: FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [store.root],
                                                   appWorkspaces: configuration.appWorkspaces),
                            engines: supervisor, traces: traces, concurrency: configuration.concurrency,
                            commit: { hash, grant in try database.save(grant, tokenHash: hash) }, approve: approve)
        await router.restore(Self.attempt(log, "read-grants") { try database.grants() } ?? [:])
        // Events are recorded one at a time, in the order the router sent them.
        let (events, sink) = AsyncStream<Router.Event>.makeStream()
        await router.observe { sink.yield($0) }

        self.store = store
        self.log = log
        self.database = database
        self.traces = traces
        self.supervisor = supervisor
        self.router = router
        self.recovered = (stopped.count, interrupted)
        self.finish = { sink.finish() }
        historyDays = Self.attempt(log, "read-retention") { try database.setting("historyDays") }.flatMap { $0.flatMap { Int($0) } } ?? 30

        consumer = Task { [weak self] in
            for await event in events { await self?.record(event) }
        }
        traces.onProblem { [weak self] task, reason in
            log?.error("trace-write-failed", ["task": .string(task), "reason": .string(reason)])
            Task { await self?.emit(.traceProblem(task: task, reason: reason)) }
        }
        // Every engine Agneta runs, so an app set to one other than its account's gets it.
        for engine in configuration.engines { await router.register(engine: engine) }
        prune(olderThan: historyDays)
        await sweepEngineHomes()
        // Retention also runs daily while Agneta stays open.
        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(86_400))
                guard let self, !Task.isCancelled else { return }
                await self.trim()
            }
        }
    }

    /// Hears every event after it's recorded.
    public func observe(_ handler: @escaping @Sendable (Event) -> Void) { observer = handler }

    private func emit(_ event: Event) { observer(event) }

    // MARK: Accounts

    /// Adds or replaces an engine (Claude Code once its adapter is installed, OpenCode once downloaded).
    public func register(_ engine: any EngineAdapter) async {
        await supervisor.register(engine)
        await router.register(engine: engine)
    }

    /// Changes the engine an app's tasks on an account run on (nil: the account's own), and saves it.
    public func setEngine(grant: String, account: String, engine: String?) async throws {
        try await router.setEngine(grant: grant, account: account, engine: engine)
    }

    /// Serves an account: its engine and provider, how its tools run, and whether it's paused. Replaces what was there.
    public func serve(account id: String, label: String, setup: AccountSetup, runner: Router.ToolRunner, kind: String?, billing: String, paused: Bool) async {
        await supervisor.add(account: id, setup: setup)
        let engine = await supervisor.engine(for: id)
        await router.add(account: id, label: label, runner: runner, kind: kind, billing: billing, engine: engine)
        await router.setPaused(id, paused)
    }

    /// Stops serving an account: its tasks stop, its engines too, and their homes go.
    public func remove(account id: String) async {
        await router.remove(account: id)
        await supervisor.remove(account: id)
        EngineHomes.remove(account: id, root: store.root)
    }

    // MARK: Grants

    /// Removes an app's access: forgotten first, so it can't come back at the next launch, then cut off now.
    public func revoke(grant id: String) async throws {
        try database.deleteGrant(id: id)
        await router.revoke(grant: id)
    }

    // MARK: Tasks

    /// Stops a running task from Agneta's UI. History records it as stopped.
    public func stop(task id: String) async {
        await router.stop(id)
    }

    private func record(_ event: Router.Event) {
        var historyChanged = false
        switch event {
        case .sessionStarted(let info):
            running[info.id] = .some(nil)
            let record = TaskRecord(id: info.id, app: info.app, appIdentifier: info.appIdentifier, account: info.account, title: info.title, started: info.started)
            write("task-started") {
                try database.taskStarted(record)
                if info.resumed { try database.taskResumed(info.id) }
            }
            historyChanged = info.resumed // a resumed task leaves the history list while it runs
        case .turnStarted(let id):
            write("turn-started") { try database.turnStarted(task: id) }
        case .turnEnded(let id, let reason):
            if running[id] != nil { running[id] = reason }
            write("turn-ended") { try database.turnEnded(task: id, stopReason: reason) }
        case .usage(let id, let used, let cost):
            write("usage") { try database.usage(task: id, usedTokens: used, cost: cost) }
        case .sessionEnded(let id, let ending):
            let lastTurn = running.removeValue(forKey: id) ?? nil
            let outcome: TaskOutcome = switch ending {
            case .stopped: .stopped
            case .engineStopped: .failed
            case .closed: lastTurn == "error" ? .failed : .finished
            }
            write("task-ended") { try database.taskEnded(id, outcome: outcome) }
            if historyDays == 0 { prune(olderThan: 0) }
            historyChanged = true
        default:
            break
        }
        observer(.router(event))
        if historyChanged { observer(.historyChanged) }
    }

    /// Runs a write to Agneta's records; one that fails is logged, never silently dropped.
    private func write(_ name: String, _ work: () throws -> Void) {
        Self.attempt(log, name, work)
    }

    @discardableResult
    private static func attempt<T>(_ log: OperationalLog?, _ name: String, _ work: () throws -> T) -> T? {
        do { return try work() } catch {
            log?.error("store-write-failed", ["step": .string(name), "reason": .string("\(error)")])
            return nil
        }
    }

    // MARK: History and retention

    public func history() -> [TaskRecord] { Self.attempt(log, "read-history") { try database.history() } ?? [] }

    public func setHistoryDays(_ days: Int) {
        historyDays = days
        write("set-retention") { try database.set(String(days), for: "historyDays") }
        prune(olderThan: days)
        observer(.historyChanged)
    }

    public func clearHistory() {
        forget(tasks: Self.attempt(log, "clear-history") { try database.clearHistory() } ?? [])
        observer(.historyChanged)
    }

    /// Retention: history rows go with their traces and engine homes.
    private func prune(olderThan days: Int) {
        forget(tasks: Self.attempt(log, "prune-history") { try database.pruneHistory(olderThan: days) } ?? [])
    }

    /// A task leaves history: its engine home (its conversation) and its trace go too.
    private func forget(tasks: [String]) {
        guard !tasks.isEmpty else { return }
        EngineHomes.remove(tasks: tasks, traces: traces, root: store.root)
        traces.delete(tasks: tasks)
    }

    /// Engine homes nothing refers to any more (a crash, older builds), after the retention period.
    private func sweepEngineHomes() async {
        let keep = await supervisor.runningKeys
        EngineHomes.sweep(root: store.root, traces: traces, before: Date().addingTimeInterval(-Double(max(historyDays, 1)) * 86_400), keep: keep)
    }

    private func trim() async {
        prune(olderThan: historyDays)
        await sweepEngineHomes()
        observer(.historyChanged)
    }

    // MARK: Stopping

    /// Quitting: every engine stops, and history records the tasks that were running as stopped.
    public func stopAll() async {
        housekeeping?.cancel()
        for id in running.keys { write("task-stopped") { try database.taskEnded(id, outcome: .stopped) } }
        running = [:]
        await supervisor.stopAll()
    }

    /// Reset: no grant works, every task and engine stops, and the database closes. This runtime is done.
    public func shutdown() async {
        housekeeping?.cancel()
        await router.shutdown()
        await supervisor.stopAll()
        finish()
        await consumer?.value
        write("close") { try database.close() }
    }
}
