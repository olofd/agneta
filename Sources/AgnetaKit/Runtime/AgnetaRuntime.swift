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
        /// After asking shared engines to delete conversations of tasks gone from history: how many are still queued,
        /// and what went wrong, if anything (nil: nothing to tell the user). Queued ones are asked for again when their
        /// provider is served, after the next forgetting, and on `retryForgetting`; a problem with none queued is one
        /// asking again can't fix (the engine can't delete a session).
        case conversationsLeft(count: Int, problem: String?)
    }

    public struct Configuration: Sendable {
        public var store: AgnetaStore
        public var shellTool: URL
        /// Where each paired app's own workspace is made, if apps get one.
        public var appWorkspaces: URL?
        /// Loopback ports engines may reach besides the apps' tool servers (a local model).
        public var engineLoopbackPorts: [Int]
        public var concurrency: Router.Concurrency

        public init(store: AgnetaStore, shellTool: URL, appWorkspaces: URL? = nil,
                    engineLoopbackPorts: [Int] = [], concurrency: Router.Concurrency = .init()) {
            self.store = store
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
    /// Deleting the queued conversations (`pendingConversations`), one pass at a time; `deleteAgain` asks for another.
    private var deleting: Task<Void, Never>?
    private var deleteAgain = false

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
        // Developer access keeps out all of Agneta's data and every app's workspace and caches but the session's own,
        // wherever the data lives (an isolated instance's too, not only the default folders' names).
        let supervisor = EngineSupervisor(.init(shellTool: configuration.shellTool, root: store.root,
                                                engineLoopbackPorts: configuration.engineLoopbackPorts, ledger: database, traces: traces,
                                                agnetaRoots: [store.root] + (configuration.appWorkspaces.map { [$0] } ?? [])))
        let router = Router(context: PolicyContext(userHome: FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [store.root],
                                                   appWorkspaces: configuration.appWorkspaces),
                            engines: supervisor, traces: traces, concurrency: configuration.concurrency,
                            commit: { hash, grant, replacing in try database.save(grant, tokenHash: hash, replacing: replacing) }, approve: approve)
        // A grant whose limits can't be read isn't restored rather than left unlimited: its app pairs again. Said in the log.
        for id in Self.attempt(log, "read-limits") { try database.unreadableLimits() } ?? [] {
            log?.error("app-limits-unreadable", ["grant": .string(id)])
        }
        // Each app's usage goes on from where it was, for the limits the user set for it.
        Self.attempt(log, "prune-app-usage") { try database.pruneUsage(before: Date().addingTimeInterval(-Self.usageDays * 86_400)) }
        await router.restore(Self.attempt(log, "read-grants") { try database.grants() } ?? [:],
                             usage: Self.attempt(log, "read-app-usage") { try database.usage(since: Date().addingTimeInterval(-Self.usageDays * 86_400)) } ?? [:])
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

    /// The host's snapshot of its engines and each provider's default, whenever either changes (EngineCatalog).
    public func setCatalog(_ catalog: EngineCatalog) async { await router.setCatalog(catalog) }

    /// Changes which providers and engines an app may use, and the most its tasks may do, and saves it.
    public func setAccess(grant: String, accounts: [String], engines: EngineAllowance, sandbox: Sandbox) async throws {
        try await router.setAccess(grant: grant, accounts: accounts, engines: engines, sandbox: sandbox)
        // Removed meanwhile (Remove Access while the change was saved): its row must not come back on the next launch.
        if await !router.hasGrant(grant) { try database.deleteGrant(id: grant) }
    }

    /// Serves an account: its provider, how its tools run, and whether it's paused. Replaces what was there.
    public func serve(account id: String, label: String, provider: ProviderSetup, runner: Router.ToolRunner, kind: AccountKind, billing: String,
                      paused: Bool) async {
        await supervisor.add(account: id, provider: provider)
        await router.add(account: id, label: label, runner: runner, kind: kind, billing: billing)
        await router.setPaused(id, paused)
        // Its shared engines can delete what history left them to.
        if pendingConversations.contains(where: { $0.account == id }) { deletePendingConversations() }
    }

    /// An account's default model and effort for new sessions (Router+Settings). When they change, its shared engines
    /// are renewed (EngineSupervisor.renew): one already running could keep what an earlier session set.
    public func setDefaults(account id: String, model: String?, effort: String?) async {
        if await router.setDefaults(account: id, model: model, effort: effort) { await supervisor.renew(account: id) }
    }

    /// Stops serving an account: its tasks stop, its engines too, and their homes go.
    public func remove(account id: String) async {
        await router.remove(account: id)
        await supervisor.remove(account: id)
        EngineHomes.remove(account: id, root: store.root)
        // Its engines' state, conversations and all, went with its folder.
        let pending = pendingConversations
        if pending.contains(where: { $0.account == id }) {
            savePending(pending.filter { $0.account != id })
            observer(.conversationsLeft(count: pendingConversations.count, problem: nil))
        }
    }

    // MARK: Grants

    /// Sets the limits the user chose for an app (AppLimits), and saves them.
    public func setLimits(grant: String, limits: AppLimits) async throws {
        try await router.setLimits(grant: grant, limits: limits)
        if await !router.hasGrant(grant) { try database.deleteGrant(id: grant) }
    }

    /// An app's usage and where it stands against its limits, for Settings.
    public func appStatus(grant: String) async -> AppLimitStatus { await router.appStatus(grant: grant) }

    /// How long each app's usage by hour is kept: the longest limit period (a month) and some.
    static let usageDays = 35.0

    /// Removes an app's access: forgotten first, so it can't come back at the next launch, then cut off now.
    /// The token stops working now, whatever happens to the saved row; a row that couldn't be deleted throws, so the
    /// app can say so (it would work again at the next launch).
    public func revoke(grant id: String) async throws {
        await router.revoke(grant: id)
        try database.deleteGrant(id: id)
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
        case .appUsage(let grant, let hour, let usage):
            write("app-usage") { try database.addUsage(grant: grant, hour: hour, usage) }
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

    /// A task leaves history: its conversation and its trace go too. Its engine home and files go here; a shared
    /// engine is asked to delete it (Router+Forget), from what the trace said. That's queued in Agneta's records before
    /// the trace goes, so a conversation the engine doesn't delete now (it failed, isn't here, Agneta quit) is asked
    /// for again rather than left where nothing can find it.
    private func forget(tasks: [String]) {
        guard !tasks.isEmpty else { return }
        let shared = tasks.compactMap { traces.meta(task: $0).flatMap(Router.sharedConversation) }
        let queued = shared.isEmpty || savePending(Array(Set(pendingConversations + shared)))
        // Not queued (the database refused the write): those tasks' traces stay, the only record left of where their
        // conversations are.
        let gone = queued ? tasks : tasks.filter { traces.meta(task: $0).flatMap(Router.sharedConversation) == nil }
        // Codex keeps a conversation in its databases too, not only in the rollout file: Codex itself deletes it, while
        // the rollout is still there to find it by (the files go as before if it can't).
        let codexThreads: [(home: URL, session: String, files: [URL])] = gone.compactMap { task in
            guard let engine = traces.meta(task: task)?["engine"], engine["id"]?.stringValue == "codex",
                  let session = engine["session"]?.stringValue, let root = engine["stateRoot"]?.stringValue else { return nil }
            let files = EngineHomes.conversation(engine: engine, root: store.root)
            return files.isEmpty ? nil : (URL(filePath: root, directoryHint: .isDirectory), session, files)
        }
        EngineHomes.remove(tasks: gone, traces: traces, root: store.root, keepingConversationsOf: codexThreads.isEmpty ? [] : ["codex"])
        traces.delete(tasks: gone)
        if !codexThreads.isEmpty {
            _Concurrency.Task { [router, log] in
                let program = await router.codexProgram
                var failed = 0
                for thread in codexThreads {
                    var deleted = false
                    if let program { deleted = await CodexSignIn(cli: program, codexHome: thread.home).delete(session: thread.session) }
                    if !deleted {
                        failed += 1
                        for file in thread.files { try? FileManager.default.removeItem(at: file) }
                    }
                }
                log?.log("codex-threads-deleted", level: failed == 0 ? "info" : "error",
                         ["asked": .int(Int64(codexThreads.count)), "failed": .int(Int64(failed)), "program": .bool(program != nil)])
            }
        }
        if !queued {
            observer(.conversationsLeft(count: shared.count, problem: "Agneta couldn't record which conversations to delete"))
        } else if !shared.isEmpty {
            deletePendingConversations()
        }
    }

    // MARK: Conversations still to delete

    static let pendingKey = "pendingConversationDeletions"

    /// Conversations in shared engines still to delete, kept in Agneta's records until an engine deletes them.
    public var pendingConversations: [Router.SharedConversation] {
        guard let text = Self.attempt(log, "read-pending-deletions", { try database.setting(Self.pendingKey) }) ?? nil,
              let list = try? JSONDecoder().decode([Router.SharedConversation].self, from: Data(text.utf8)) else { return [] }
        return list
    }

    @discardableResult
    private func savePending(_ list: [Router.SharedConversation]) -> Bool {
        let text = list.isEmpty ? nil : (try? JSONEncoder().encode(list)).map { String(decoding: $0, as: UTF8.self) }
        return Self.attempt(log, "save-pending-deletions") { try database.set(text, for: Self.pendingKey) } != nil
    }

    /// Asks the shared engines again to delete what's queued (the user's Try Again).
    public func retryForgetting() { deletePendingConversations() }

    /// Waits for a pass under way (tests, and a host that wants to know the outcome).
    public func conversationsSettled() async {
        while let deleting { await deleting.value }
    }

    private func deletePendingConversations() {
        guard deleting == nil else {
            deleteAgain = true
            return
        }
        deleting = Task { [weak self] in await self?.deletePendingPasses() }
    }

    private func deletePendingPasses() async {
        repeat {
            deleteAgain = false
            let asked = pendingConversations
            guard !asked.isEmpty else { break }
            let outcome = await router.deleteConversations(asked)
            // Others may have been queued meanwhile: only what this pass finished leaves the queue.
            if !outcome.done.isEmpty { savePending(pendingConversations.filter { !outcome.done.contains($0) }) }
            log?.log("conversations-deleted", level: outcome.problems.isEmpty ? "info" : "error",
                     ["asked": .int(Int64(asked.count)), "deleted": .int(Int64(outcome.deleted)),
                      "problems": .array(outcome.problems.map(JSONValue.string))])
            observer(.conversationsLeft(count: pendingConversations.count,
                                        problem: outcome.problems.isEmpty ? nil : outcome.problems.joined(separator: "; ")))
        } while deleteAgain
        deleting = nil
    }

    /// Engine homes nothing refers to any more (after a crash), after the retention period.
    private func sweepEngineHomes() async {
        let keep = await supervisor.runningKeys
        EngineHomes.sweep(root: store.root, traces: traces, before: Date().addingTimeInterval(-Double(max(historyDays, 1)) * 86_400), keep: keep)
    }

    private func trim() async {
        prune(olderThan: historyDays)
        let usageCutoff = Date().addingTimeInterval(-Self.usageDays * 86_400)
        write("prune-app-usage") { try database.pruneUsage(before: usageCutoff) }
        await router.pruneUsage(before: usageCutoff)
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
