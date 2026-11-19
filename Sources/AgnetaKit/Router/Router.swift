// Routes ACP between app connections and engines. Agneta is agent-side to
// apps and client-side to engines: it answers initialize itself, checks the
// app's grant and the session policy, translates session/new for the engine,
// and maps session IDs both ways so apps never see engine IDs and can't
// reach another app's sessions. Apps call only the methods listed in
// `sessionMethods`: an engine's own methods (configuration, extensions, its
// session list) would bypass every check made when the session started.
import CryptoKit
import Foundation

public actor Router {
    /// What the user allowed an app (GrantScope): the providers (accounts) and the engines it may use, as two lists
    /// (Access), the most built-in tools, and the folders its sessions may name.
    public struct Grant: Sendable, Equatable {
        public var id: String
        public var app: String
        /// The verified signing identifier when pairing could read it.
        public var identifier: String?
        /// The verified signing team, checked again when the app reconnects.
        public var team: String?
        public var verified: Bool
        public var accounts: [String]
        public var created: Date
        /// The most built-in tools a session may use.
        public var tools: SessionPolicy.Tools
        /// Absolute folders a session's workspace and other folders must lie inside.
        public var folders: [String]
        /// Kept across launches ("Always Allow"), or only for the connection that paired ("Allow Once").
        public var remembered: Bool
        /// The engines the app's tasks may run on, on any of its providers that supports them.
        public var engines: EngineAllowance

        public init(id: String = UUID().uuidString, app: String, identifier: String? = nil, team: String? = nil, verified: Bool = false,
                    accounts: [String], engines: EngineAllowance = .all, created: Date = Date(), tools: SessionPolicy.Tools = .appOnly,
                    folders: [String] = [], remembered: Bool = true) {
            self.id = id
            self.app = app
            self.identifier = identifier
            self.team = team
            self.verified = verified
            self.accounts = accounts
            self.created = created
            self.tools = tools
            self.folders = folders
            self.remembered = remembered
            self.engines = engines
        }
    }

    /// What the UI shows about a session.
    public struct SessionInfo: Sendable, Equatable {
        public var id: String
        public var app: String
        /// The app's verified bundle identifier, for showing its real icon.
        public var appIdentifier: String?
        public var account: String
        public var title: String
        public var started: Date
        public var stopWarning: String?
        /// Resumed with `session/load` rather than started.
        public var resumed = false
    }

    /// How a session ended.
    public enum Ending: String, Sendable {
        /// The app closed it, or disconnected.
        case closed
        /// The user stopped it, or Agneta did (access removed, account signed out, Reset).
        case stopped
        /// Its engine exited on its own.
        case engineStopped = "engine-stopped"
    }

    public enum Event: Sendable {
        /// A new grant, saved by then when remembered; the token itself is never stored. `replaced` is the app's
        /// earlier grant when that one is gone (an unverified app paired again: its new grant starts afresh).
        case paired(tokenHash: String, grant: Grant, replaced: String?)
        /// A grant's providers or engines changed (Settings → Apps), already saved.
        case grantChanged(tokenHash: String, grant: Grant)
        case sessionStarted(SessionInfo)
        case turnStarted(String)
        case turnEnded(String, stopReason: String)
        case sessionEnded(String, Ending)
        case usage(String, used: Int?, cost: Double?)
        /// A provider's rate or plan limit stopped a turn on this account.
        case rateLimited(account: String, resetsAt: Date?, message: String)
        /// The engine says the account isn't signed in (or its sign-in expired).
        case needsSignIn(account: String)
        /// The plan's own usage, when the engine reports it (Codex): each limit's used percent, window and reset.
        case planUsage(account: String, limits: JSONValue)
        /// The app behind a pairing request still waiting for the user went away: stop asking.
        case pairingWithdrawn(UUID)
        /// A task asked for an engine that isn't here yet but can be downloaded (or failed to): the host downloads it.
        case engineWanted(String)
        /// What an engine offered on an account when a session opened (its config options: models, efforts), for
        /// Settings to list (Router+Settings).
        case settingsSeen(account: String, engine: String, options: JSONValue)
    }

    /// How an account's engine runs tools. Goose's own tools go through Agneta's broker;
    /// on the Claude Code route Claude Code runs its own, so Agneta gates each call.
    public enum ToolRunner: Sendable { case brokered, native }

    /// An app asking to pair, for the user to decide.
    public struct PairingRequest: Sendable {
        /// Names the request in `Event.pairingWithdrawn` when its app goes away first.
        public var id: UUID
        /// The name the app gave itself.
        public var app: String
        /// The connecting process's code identity, when it could be read.
        public var peer: PeerIdentity?
        /// When the app can't be verified: the six-digit code it has been sent (`agneta/pairingCode`), for the user to compare.
        public var code: String?
        /// The most built-in tools the app asks for.
        public var tools: SessionPolicy.Tools = .appOnly
        /// The folders of the user's the app asks to work in (its own workspace comes on top).
        public var folders: [URL] = []

        public init(id: UUID = UUID(), app: String, peer: PeerIdentity? = nil, code: String? = nil, tools: SessionPolicy.Tools = .appOnly, folders: [URL] = []) {
            self.id = id
            self.app = app
            self.peer = peer
            self.code = code
            self.tools = tools
            self.folders = folders
        }
    }

    /// The user's yes to a pairing request.
    public struct PairingAnswer: Sendable, Equatable {
        /// The providers the app may use.
        public var accounts: [String]
        /// The engines it may use on them.
        public var engines: EngineAllowance
        /// "Always Allow": kept across launches. Otherwise only this connection may use it.
        public var remember: Bool
        public init(accounts: [String], engines: EngineAllowance = .all, remember: Bool) {
            self.accounts = accounts
            self.engines = engines
            self.remember = remember
        }
    }

    /// Decides a pairing request: the user's answer, or nil for Don't Allow.
    public typealias Approve = @Sendable (PairingRequest) async -> PairingAnswer?
    /// Saves a remembered grant before its token is handed out: a token for a grant Agneta then forgets would
    /// work until the next launch and fail after it.
    /// Saves a grant under its token's hash, in one step removing the saved grant `replacing` names, if any.
    public typealias Commit = @Sendable (_ tokenHash: String, _ grant: Grant, _ replacing: String?) async throws -> Void

    struct App {
        var peer: RPCPeer
        var grant: Grant?
        /// Closes the connection itself, not only the peer: a closed peer on a live socket would leave
        /// the app connected.
        var close: @Sendable () -> Void = {}
    }

    struct Session {
        var app: UUID
        var account: String
        var lease: EngineLease
        var engineSession: String
        var policy: SessionPolicy
        /// The names of the app's own MCP servers: their tools are the app's to give, whatever the policy.
        var appServers: Set<String> = []
        /// The MCP server of each tool call in progress, by the engine's call id, from its updates: a permission
        /// request may name only the call.
        var toolServers: [String: String] = [:]
        /// The engine's id for the running turn, for steering.
        var activeRun: String?
        /// Live trace delivery, when the app asked for it.
        var forwarder: TraceForwarder?
        /// The policy limit that stopped the current turn, if one did.
        var limitHit: (limit: String, value: JSONValue)?
        /// New every time a session is registered. Work that waited (a load, a fork, a prompt) checks it before
        /// touching the session again: meanwhile the session may have ended, or been reopened under the same id.
        let generation = UUID()
    }

    var accounts: [String: (label: String, runner: ToolRunner, kind: AccountKind, billing: String)] = [:]
    /// Accounts whose engine said they need signing in again, until they're served again.
    var needsSignIn: Set<String> = []
    /// The engines this Agneta has and each provider's default (the host's snapshot).
    var catalog = EngineCatalog()
    /// Paused accounts start nothing new (see `setPaused`).
    var paused: Set<String> = []
    /// Each account's default model and effort, by config option category (Router+Settings).
    var settingDefaults: [String: [String: String]] = [:]
    /// Sessions each engine process deleted, by `process(_:)`: one it hands back as new is never used (Router+Forget).
    var deletedSessions: [String: Set<String>] = [:]
    var apps: [UUID: App] = [:]
    var tokens: [String: Grant] = [:] // token hash → grant
    var infos: [String: SessionInfo] = [:]
    var onEvent: @Sendable (Event) -> Void = { _ in }
    var sessions: [String: Session] = [:]
    var byEngine: [String: String] = [:] // "lease\u{0}engineSession" → Agneta session
    let engines: EngineSource
    let approve: Approve
    let context: PolicyContext
    let traces: Traces?

    /// How many turns may run at once. Further prompts wait in order.
    public struct Concurrency: Sendable {
        public var global: Int
        public var perAccount: Int
        public var queue: Int
        /// How long an engine has to stop a turn after a limit cancels it, before Agneta ends the session.
        public var limitGrace: Duration
        /// A connection without a grant is anything on this Mac: at most this many at once, each message at most
        /// `unpairedFrame` bytes, closed after `unpairedFor` (longer than the approval window waits).
        public var unpaired: Int
        public var unpairedFrame: Int
        public var unpairedFor: Duration
        public init(global: Int = 8, perAccount: Int = 3, queue: Int = 32, limitGrace: Duration = .seconds(10),
                    unpaired: Int = 16, unpairedFrame: Int = 256 << 10, unpairedFor: Duration = .seconds(600)) {
            self.unpaired = unpaired
            self.unpairedFrame = unpairedFrame
            self.unpairedFor = unpairedFor
            self.global = global
            self.perAccount = perAccount
            self.queue = queue
            self.limitGrace = limitGrace
        }
    }

    let concurrency: Concurrency
    var runningTurns: [String: String] = [:] // session → account
    /// Each running prompt's request to its engine, so a limit the engine ignores can abandon it.
    var inFlight: [String: Task<JSONValue, Error>] = [:]
    /// Limits Agneta enforced by ending the session, for the prompt they cut short to report.
    var enforcedLimits: [String: (limit: String, value: JSONValue)] = [:]
    struct Waiter {
        var session: String
        var account: String
        var resume: CheckedContinuation<Admission, Never>
    }
    /// How a turn's wait for room ended.
    enum Admission { case admitted, cancelled, paused }
    var waiting: [Waiter] = []
    var loading: Set<String> = []
    /// Sessions being opened, by lease: an engine may speak of a new session before its answer names it.
    var openingOn: [String: Int] = [:]
    /// What an engine said about a session not yet registered, by lease and engine session, delivered once it is.
    var early: [String: [(method: String, params: JSONValue?)]] = [:]
    /// Set by `shutdown()` (Reset): this router answers nothing more.
    var shutDown = false
    /// Pairing requests waiting for the user, by app connection.
    var pairing: [UUID: UUID] = [:]
    /// "Allow Once" grants' token hashes, by the connection that paired: they end with it.
    var onceTokens: [UUID: String] = [:]
    let commit: Commit?

    public init(context: PolicyContext, engines: EngineSource, traces: Traces? = nil, concurrency: Concurrency = .init(), commit: Commit? = nil,
                approve: @escaping Approve) {
        self.commit = commit
        self.context = context
        self.engines = engines
        self.traces = traces
        self.concurrency = concurrency
        self.approve = approve
    }

    /// Serves an account (again, after signing in or a change). Its tasks run on engines its kind supports.
    /// - Parameters:
    ///   - billing: `subscription` or `api-key`, so traces can say what a cost means.
    ///   - runner: `.native` when the account's provider runs its own tools whatever the engine (a Claude plan runs
    ///     Claude Code); engines that always do (Claude Code, Codex) are native on any account (`runner(account:engine:)`).
    public func add(account id: String, label: String, runner: ToolRunner = .brokered, kind: AccountKind, billing: String = "unknown") {
        accounts[id] = (label, runner, kind, billing)
        needsSignIn.remove(id)
        accessChanged()
    }

    /// The host's new snapshot of its engines and defaults. Apps hear `agneta/accessChanged` when what they may run
    /// changed (not for download progress, which `-32015` and `agneta/access` carry).
    public func setCatalog(_ catalog: EngineCatalog) {
        let changed = catalog.shape != self.catalog.shape
        self.catalog = catalog
        if changed { accessChanged() }
    }

    /// Whether a grant is for this app: the same verified signing identity (identifier and team), or, for an app Agneta
    /// can't verify, the same name. Pairing again replaces such an app's access instead of adding to it.
    public static func sameApp(_ grant: Grant, app: String, identifier: String?, team: String?, verified: Bool) -> Bool {
        guard grant.verified == verified else { return false }
        return verified ? grant.identifier == identifier && grant.team == team : grant.app == app
    }

    /// Whether any connection still holds this grant.
    public func hasGrant(_ id: String) -> Bool { tokens.values.contains { $0.id == id } }

    /// Changes which providers and engines an app may use, for every connection holding the grant, and saves it.
    /// Sessions that no longer fit (on a provider or engine taken away) stop; the app hears `agneta/accessChanged`.
    public func setAccess(grant id: String, accounts allowed: [String], engines: EngineAllowance) async throws {
        for (hash, grant) in tokens where grant.id == id {
            var changed = grant
            changed.accounts = allowed
            changed.engines = engines
            if changed.remembered, let commit { try await commit(hash, changed, nil) }
            // Access removed while the change was saved stays removed (AgnetaRuntime.setAccess deletes the saved row again).
            guard tokens[hash]?.id == id else { continue }
            tokens[hash] = changed
            onEvent(.grantChanged(tokenHash: hash, grant: changed))
            await apply(changed)
        }
    }

    /// A grant changed (Settings → Apps, or its app paired again): every connection holding it has it now, its
    /// sessions that no longer fit stop, and its apps hear what they may use.
    func apply(_ grant: Grant) async {
        for (appID, app) in apps where app.grant?.id == grant.id { apps[appID]?.grant = grant }
        for (session, entry) in sessions where apps[entry.app]?.grant?.id == grant.id
            && !Self.fits(account: entry.account, engine: entry.lease.engine.id, policy: entry.policy, grant: grant) {
            await stop(session)
        }
        accessChanged(grant: grant.id)
    }

    /// Whether a session on this account and engine, with this policy, is within what `grant` allows.
    static func fits(account: String, engine: String, policy: SessionPolicy, grant: Grant) -> Bool {
        grant.accounts.contains(account) && grant.engines.allows(engine) && GrantScope.check(policy, against: grant) == nil
    }

    /// What an app may use, as it sees it (AccessReport): each provider it may use, with the engines its tasks there
    /// may run on (default first), and each engine it may use that one of those providers can run, with its state.
    func access(_ grant: Grant) -> JSONValue {
        let providers: [AccessReport.Provider] = grant.accounts.compactMap { id in
            guard let account = accounts[id] else { return nil }
            let engines = Access.engines(for: account.kind, allowed: grant.engines, catalog: catalog)
            return AccessReport.Provider(id: id, label: account.label, kind: account.kind.rawValue, paused: paused.contains(id),
                                         needsSignIn: needsSignIn.contains(id), engines: engines, defaultEngine: engines.first)
        }
        let kinds = Set(grant.accounts.compactMap { accounts[$0]?.kind })
        let engines = catalog.entries.keys.filter { id in grant.engines.allows(id) && kinds.contains { ProviderEngines.supported(by: $0).contains(id) } }
            .sorted().map(catalog.report)
        return AccessReport(providers: providers, engines: engines, allowedEngines: grant.engines,
                            scope: .init(tools: grant.tools.rawValue, folders: grant.folders),
                            workspace: Self.workspace(of: grant, in: context)?.path(percentEncoded: false)).json
    }

    /// Tells connected apps (those holding `grant`, or every one) that what they may use changed, with what it is now.
    func accessChanged(grant only: String? = nil) {
        for app in apps.values {
            guard let grant = app.grant, only == nil || grant.id == only else { continue }
            let peer = app.peer, access = access(grant)
            Task { try? await peer.notify("agneta/accessChanged", ["access": access]) }
        }
    }

    /// The engine a task runs on, or why it can't: a new task's is the one it asks for or its provider's default, among
    /// what the grant allows (Access); a resumed or forked task's is the engine that saved it, which the grant must
    /// still allow. The engine must be ready: one still downloading is answered with how far along it is (`-32015`),
    /// and one that isn't here but can download starts downloading (`engineWanted`) and is answered the same way.
    func taskEngine(account id: String, requested: String?, resuming: Bool, grant: Grant) -> Result<any EngineAdapter, RPCError> {
        guard let account = accounts[id] else { return .failure(RPCError(code: RPCError.invalidParams, message: "This app isn't allowed to use that account")) }
        let engine: String
        if resuming {
            guard let saved = requested else { return .failure(RPCError(code: RPCError.invalidParams, message: "This session can't be resumed")) }
            guard grant.engines.allows(saved) else { return .failure(accessRefusal(.notAllowed(saved), account: id, grant: grant)) }
            engine = saved
        } else {
            switch Access.engine(for: account.kind, requested: requested, allowed: grant.engines, catalog: catalog) {
            case .success(let chosen): engine = chosen
            case .failure(let refusal): return .failure(accessRefusal(refusal, account: id, grant: grant))
            }
        }
        let name = catalog.entries[engine]?.name ?? engine
        switch catalog.entries[engine]?.state {
        case .ready?:
            if let adapter = catalog.adapter(engine) { return .success(adapter) }
        case .downloading(let received, let total)?:
            return .failure(Self.downloadingError(engine, name: name, received: received, total: total))
        case .downloadable?, .failed?:
            onEvent(.engineWanted(engine))
            return .failure(Self.downloadingError(engine, name: name, received: 0, total: nil))
        case .unavailable?, nil:
            break
        }
        return .failure(accessRefusal(.unavailable(engine), account: id, grant: grant))
    }

    static func downloadingError(_ engine: String, name: String, received: Int64, total: Int64?) -> RPCError {
        RPCError(code: engineDownloading, message: "Agneta is downloading what \(name) needs; try again shortly",
                 data: ["agneta": ["engineDownloading": ["engine": .string(engine), "received": .int(received), "total": total.map(JSONValue.int) ?? .null]]])
    }

    /// A refused engine, said plainly, with what the app may use on that provider now (`data.agneta.access`).
    func accessRefusal(_ refusal: Access.Refusal, account id: String, grant: Grant) -> RPCError {
        let label = accounts[id]?.label ?? "This account"
        func name(_ engine: String) -> String { catalog.entries[engine]?.name ?? engine }
        let message = switch refusal {
        case .unsupported(let engine): "\(label) can't run on \(name(engine))"
        case .notAllowed(let engine): "This app isn't allowed to use \(name(engine))"
        case .unavailable(let engine): {
            if case .unavailable(let reason)? = catalog.entries[engine]?.state { return "\(name(engine)) isn't available: \(reason)" }
            return "\(name(engine)) isn't on this Mac"
        }()
        case .noEngine: "\(label) has no engine this app may use on this Mac"
        }
        return RPCError(code: RPCError.invalidParams, message: message, data: ["agneta": ["access": access(grant)]])
    }

    static let engineDownloading: Int64 = -32015

    /// Whether a session's tools are run by the engine itself (Agneta gating each call from its permission requests) or
    /// brokered by Agneta: the account's provider may say (a Claude plan runs Claude Code), else the engine does.
    func runner(account: String, engine: (any EngineAdapter)?) -> ToolRunner {
        accounts[account]?.runner == .native || engine?.capabilities.runsOwnTools == true ? .native : .brokered
    }

    /// Pausing an account starts nothing more on it: no session opens (new, load or fork) and no turn begins,
    /// whether it's sent now or was waiting in the queue; both are refused with `-32013`. A turn already running
    /// finishes, and idle sessions stay open, to go on once the account is resumed.
    public func setPaused(_ account: String, _ isPaused: Bool) {
        guard isPaused else {
            paused.remove(account)
            accessChanged()
            return
        }
        paused.insert(account)
        for waiter in waiting where waiter.account == account { waiter.resume.resume(returning: .paused) }
        waiting.removeAll { $0.account == account }
        accessChanged()
    }

    static let accountPaused: Int64 = -32013
    public func remove(account id: String) async {
        accounts.removeValue(forKey: id)
        for (session, entry) in sessions where entry.account == id { await stop(session) }
        accessChanged()
    }

    public func observe(_ handler: @escaping @Sendable (Event) -> Void) { onEvent = handler }

    /// Grants from earlier launches, keyed by token hash.
    public func restore(_ grants: [String: Grant]) { tokens = grants }

    /// Removes an app's access: its token stops working, its live connections lose the grant at once
    /// (before anything can suspend), its sessions stop, and its connections close.
    public func revoke(grant id: String) async {
        tokens = tokens.filter { $0.value.id != id }
        let affected = apps.filter { $0.value.grant?.id == id }.map(\.key)
        for appID in affected { apps[appID]?.grant = nil }
        for appID in affected {
            for (session, entry) in sessions where entry.app == appID { await stop(session) }
            if let app = apps[appID] { await hangUp(app, reason: "access removed") }
        }
    }

    /// Ends everything for Reset: no grant works, every session stops, every app connection closes,
    /// and this router answers nothing more. Reset starts a new one.
    public func shutdown() async {
        shutDown = true
        tokens = [:]
        for appID in apps.keys { apps[appID]?.grant = nil }
        for id in Array(sessions.keys) { await stop(id) }
        for app in apps.values { await hangUp(app, reason: "Agneta was reset") }
    }

    /// Closes an app's peer and its connection; the connection's `serve` then cleans up.
    func hangUp(_ app: App, reason: String) async {
        await app.peer.close(reason)
        app.close()
    }

    /// Whether `id` is still the session registered as `generation`.
    func current(_ id: String, _ generation: UUID) -> Bool { sessions[id]?.generation == generation }

    /// Why a session planned under `grant` can't be registered now, or nil: checked after every wait, since meanwhile
    /// the app may have gone, the user removed its access, or a change of access (Settings, or pairing again) left the
    /// plan outside what the grant allows.
    func refusal(_ appID: UUID, _ grant: Grant, _ plan: Plan) -> RPCError? {
        guard !shutDown, let current = apps[appID]?.grant, current.id == grant.id else { return Self.appGone }
        guard Self.fits(account: plan.account, engine: plan.engine.id, policy: plan.policy, grant: current) else {
            return RPCError(code: RPCError.invalidParams, message: "This app's access changed while the task started",
                            data: ["agneta": ["accessChanged": true]])
        }
        return nil
    }

    /// Stops a session from Agneta's UI. The app sees the turn end as cancelled by the user.
    public func stop(_ id: String) async {
        guard let session = sessions[id] else { return }
        traces?.session(id)?.writer.record("lifecycle", ["event": "stop", "by": "user"])
        await Self.closeOnEngine(session)
        if let app = apps[session.app] {
            // Not waited for: an app that stopped reading mustn't hold up Stop.
            let peer = app.peer
            Task { try? await peer.notify("agneta/sessionStopped", ["sessionId": .string(id), "stoppedBy": "user"]) }
        }
        await end(id, .stopped)
    }

    /// Tells the engine a session is over: cancel its turn, then close it, within 5 s together. A stuck engine
    /// (one that stopped reading, so even a notification can't be written) can't hold up Stop, a disconnect,
    /// Remove Access or close; ending the session afterwards stops a dedicated engine regardless.
    static func closeOnEngine(_ session: Session) async {
        let peer = session.lease.peer, engineSession = JSONValue.string(session.engineSession)
        await bounded {
            try? await peer.notify("session/cancel", ["sessionId": engineSession])
            _ = try? await peer.request("session/close", ["sessionId": engineSession])
        }
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var sessionCount: Int { sessions.count }
}
