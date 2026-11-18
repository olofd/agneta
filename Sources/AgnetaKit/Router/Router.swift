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
    /// What the user allowed an app (GrantScope): accounts, the most built-in tools, and the folders its sessions
    /// may name.
    public struct Grant: Sendable, Equatable, Codable {
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
        /// The engine this app's tasks run on, per account, where the user chose one for this app; any other account
        /// runs on its own engine.
        public var engines: [String: String]

        public init(id: String = UUID().uuidString, app: String, identifier: String? = nil, team: String? = nil, verified: Bool = false,
                    accounts: [String], created: Date = Date(), tools: SessionPolicy.Tools = .appOnly, folders: [String] = [], remembered: Bool = true,
                    engines: [String: String] = [:]) {
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

        /// Grants saved before scopes existed read as app-only with no folders: the app pairs again to ask for more.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(id: try c.decode(String.self, forKey: .id), app: try c.decode(String.self, forKey: .app),
                      identifier: try c.decodeIfPresent(String.self, forKey: .identifier), team: try c.decodeIfPresent(String.self, forKey: .team),
                      verified: try c.decode(Bool.self, forKey: .verified), accounts: try c.decode([String].self, forKey: .accounts),
                      created: try c.decode(Date.self, forKey: .created), tools: try c.decodeIfPresent(SessionPolicy.Tools.self, forKey: .tools) ?? .appOnly,
                      folders: try c.decodeIfPresent([String].self, forKey: .folders) ?? [], remembered: try c.decodeIfPresent(Bool.self, forKey: .remembered) ?? true,
                      engines: try c.decodeIfPresent([String: String].self, forKey: .engines) ?? [:])
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
        /// A new grant; persist `tokenHash` → grant. The token itself is never stored.
        case paired(tokenHash: String, grant: Grant)
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
    }

    /// The user's yes to a pairing request.
    public struct PairingAnswer: Sendable, Equatable {
        public var accounts: [String]
        /// "Always Allow": kept across launches. Otherwise only this connection may use it.
        public var remember: Bool
        /// The engine the user chose for this app, per account, where it isn't the account's own.
        public var engines: [String: String]
        public init(accounts: [String], remember: Bool, engines: [String: String] = [:]) {
            self.accounts = accounts
            self.remember = remember
            self.engines = engines
        }
    }

    /// Decides a pairing request: the user's answer, or nil for Don't Allow.
    public typealias Approve = @Sendable (PairingRequest) async -> PairingAnswer?
    /// Saves a remembered grant before its token is handed out: a token for a grant Agneta then forgets would
    /// work until the next launch and fail after it.
    public typealias Commit = @Sendable (_ tokenHash: String, _ grant: Grant) async throws -> Void

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

    var accounts: [String: (label: String, runner: ToolRunner, kind: String?, billing: String, engine: (any EngineAdapter)?)] = [:]
    /// Paused accounts start nothing new (see `setPaused`).
    var paused: Set<String> = []
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
        public init(global: Int = 8, perAccount: Int = 3, queue: Int = 32) {
            self.global = global
            self.perAccount = perAccount
            self.queue = queue
        }
    }

    let concurrency: Concurrency
    var runningTurns: [String: String] = [:] // session → account
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

    /// - Parameters:
    ///   - kind: the account kind for traces, e.g. `chatgpt`.
    ///   - billing: `subscription` or `api-key`, so traces can say what a cost means.
    ///   - engine: the engine serving the account, so apps can see what its sessions can do.
    ///   - runner: `.native` when the account's provider runs its own tools whatever the engine (a Claude plan runs
    ///     Claude Code); engines that always do (Claude Code, Codex) are native on any account (`runner(account:engine:)`).
    public func add(account id: String, label: String, runner: ToolRunner = .brokered, kind: String? = nil, billing: String = "unknown",
                    engine: (any EngineAdapter)? = nil) {
        accounts[id] = (label, runner, kind, billing, engine)
        if let engine { adapters[engine.id] = engine }
    }

    /// Makes an engine available for apps that are set to it, beyond the accounts' own engines.
    public func register(engine: any EngineAdapter) { adapters[engine.id] = engine }

    /// The engines Agneta can run, by id: any an app may be set to.
    var adapters: [String: any EngineAdapter] = [:]

    /// The engine an app's tasks on an account run on: the one chosen for the app, else the account's own.
    func engine(for account: String, in grant: Grant) -> (any EngineAdapter)? {
        if let chosen = grant.engines[account] { return adapters[chosen] }
        return accounts[account]?.engine
    }

    /// Engines that run their own tools; Agneta answers their permission requests from the policy.
    static let nativeEngines: Set<String> = ["claude-code", "codex"]

    /// Whether a session's tools are run by the engine itself (Agneta gating each call) or brokered by Agneta.
    func runner(account: String, engine: (any EngineAdapter)?) -> ToolRunner {
        accounts[account]?.runner == .native || engine.map { Self.nativeEngines.contains($0.id) } == true ? .native : .brokered
    }

    /// Sets the engine an app's tasks on `account` run on (nil: the account's own), for every connection holding
    /// the grant, and saves it. Sessions already open keep their engine.
    public func setEngine(grant id: String, account: String, engine: String?) async throws {
        for (hash, grant) in tokens where grant.id == id {
            var changed = grant
            changed.engines[account] = engine
            if changed.remembered, let commit { try await commit(hash, changed) }
            tokens[hash] = changed
            for (appID, app) in apps where app.grant?.id == id { apps[appID]?.grant = changed }
            onEvent(.paired(tokenHash: hash, grant: changed))
        }
    }

    /// Pausing an account starts nothing more on it: no session opens (new, load or fork) and no turn begins,
    /// whether it's sent now or was waiting in the queue; both are refused with `-32013`. A turn already running
    /// finishes, and idle sessions stay open, to go on once the account is resumed.
    public func setPaused(_ account: String, _ isPaused: Bool) {
        guard isPaused else {
            paused.remove(account)
            return
        }
        paused.insert(account)
        for waiter in waiting where waiter.account == account { waiter.resume.resume(returning: .paused) }
        waiting.removeAll { $0.account == account }
    }

    static let accountPaused: Int64 = -32013
    public func remove(account id: String) async {
        accounts.removeValue(forKey: id)
        for (session, entry) in sessions where entry.account == id { await stop(session) }
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

    /// Whether an app's connection still holds this grant: checked after every wait, since the user may
    /// have removed access, or the app gone, meanwhile.
    func holds(_ appID: UUID, _ grant: Grant) -> Bool {
        !shutDown && apps[appID]?.grant?.id == grant.id
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

    // MARK: Apps

    /// Serves one app connection until it closes; its sessions are closed with it.
    public func serve(_ connection: WebSocketServer.Connection) async {
        let peer = RPCPeer { data in try await connection.send(data) }
        let id = connection.id
        let port = connection.remotePort
        let serverPort = connection.localPort
        guard !shutDown else { connection.close(); return }
        apps[id] = App(peer: peer, grant: nil, close: { connection.close() })
        if let traces { await peer.handle(tap: traces.appAttributor().frame) }
        await peer.handle(requests: { [weak self] method, params in
            guard let self else { return .failure(RPCError(code: RPCError.internalError, message: "Agneta is stopping")) }
            return await self.appRequest(id, port: port, serverPort: serverPort, method: method, params: params)
        })
        await peer.handle(notifications: { [weak self] method, params in
            await self?.appNotification(id, method: method, params: params)
        })
        await peer.run(connection.messages)
        await disconnect(id)
    }

    func disconnect(_ app: UUID) async {
        apps.removeValue(forKey: app)
        if let request = pairing.removeValue(forKey: app) { onEvent(.pairingWithdrawn(request)) }
        if let hash = onceTokens.removeValue(forKey: app) { tokens.removeValue(forKey: hash) }
        for (id, session) in sessions where session.app == app {
            traces?.session(id)?.writer.record("lifecycle", ["event": "stop", "by": "app", "reason": "disconnected"])
            await Self.closeOnEngine(session)
            await end(id, .closed)
        }
    }

    /// Everything that changes the router's state happens before the first wait, so a load or new session
    /// arriving meanwhile can't have its routing removed by this one.
    func end(_ id: String, _ ending: Ending) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        // Only a session whose start was announced has an end to announce (a load or fork cut short has none).
        let announced = infos.removeValue(forKey: id) != nil
        _ = cancelWaiting(id)
        finishTurn(id)
        byEngine.removeValue(forKey: key(session.lease.key, session.engineSession))
        if let traces {
            traces.session(id)?.writer.record("end", [:])
            traces.close(task: id)
        }
        if announced { onEvent(.sessionEnded(id, ending)) }
        // Live records still owed to the app go out, but an app that stopped reading can't hold up the engine's release.
        if let forwarder = session.forwarder { await Self.bounded(seconds: 2) { await forwarder.finish() } }
        await engines.release(session.lease)
    }

    static let notPaired = RPCError(code: -32001, message: "Pair with Agneta first", data: ["agneta": ["needsPairing": true]])

    /// What an app may call on one of its sessions, besides pairing, `initialize`, `session/new`,
    /// `session/load`, `agneta/fork` and `agneta/trace/read`. Engine extras (steering, instructions)
    /// are reached through Agneta's own methods, which the engine's adapter maps.
    static let sessionMethods: Set<String> = ["session/prompt", "session/close", "session/set_mode", "session/set_config_option",
                                              "session/set_model", "agneta/steer", "agneta/instructions/set"]
    /// The only notification an app may send on a session.
    static let sessionNotifications: Set<String> = ["session/cancel"]

    func appRequest(_ appID: UUID, port: Int?, serverPort: Int?, method: String, params: JSONValue?) async -> Result<JSONValue, RPCError> {
        guard !shutDown, var app = apps[appID] else { return .failure(Self.notPaired) }
        if method == "agneta/pair" {
            let name = params?["name"]?.stringValue ?? "An app"
            // The scope is checked before the user sees anything: a folder Agneta would refuse is never offered.
            let scope: (tools: SessionPolicy.Tools, folders: [URL])
            do { scope = try GrantScope.requested(params?["scope"], context: context) } catch let rejection as PolicyRejection {
                return .failure(rejection.rpcError)
            } catch {
                return .failure(RPCError(code: RPCError.invalidParams, message: "Invalid scope"))
            }
            let peer = port.flatMap { client in serverPort.flatMap { PeerIdentity.forLoopbackPort(client, serverPort: $0) } }
            // Verified means a checkable signature: Apple-issued certificate and team, not just valid.
            let verified = peer?.trusted == true && peer?.identifier != nil
            // An app Agneta can't verify shows a code; the approval window shows the same one.
            var code: String?
            if !verified {
                var number: UInt32 = 0
                _ = withUnsafeMutableBytes(of: &number) { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
                code = String(format: "%06d", number % 1_000_000)
                try? await app.peer.notify("agneta/pairingCode", ["code": .string(code!), "name": .string(name)])
            }
            let request = PairingRequest(id: UUID(), app: name, peer: peer, code: code, tools: scope.tools, folders: scope.folders)
            pairing[appID] = request.id
            let decision = await approve(request)
            pairing[appID] = nil
            guard let answer = decision, !answer.accounts.isEmpty else {
                return .failure(RPCError(code: -32002, message: "\(name) wasn't allowed to use Agneta"))
            }
            // The app may have gone while the user decided (or Agneta reset): no grant nobody received.
            guard !shutDown, apps[appID] != nil else { return .failure(RPCError(code: RPCError.internalError, message: "The app disconnected")) }
            let token = Self.newToken(), hash = Self.hash(token)
            var grant = Grant(app: name, identifier: verified ? peer?.identifier : nil, team: verified ? peer?.team : nil, verified: verified,
                              accounts: answer.accounts, tools: scope.tools, folders: scope.folders.map { $0.path(percentEncoded: false) },
                              remembered: answer.remember, engines: answer.engines.filter { answer.accounts.contains($0.key) })
            // The app's own workspace, inside its grant whatever else it asked for.
            if let root = context.appWorkspaces {
                let workspace = root.appending(path: grant.id, directoryHint: .isDirectory)
                do {
                    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                } catch {
                    return .failure(RPCError(code: RPCError.internalError, message: "Agneta couldn't create the app's workspace"))
                }
                grant.folders.append(workspace.realFileURL.path(percentEncoded: false))
            }
            if answer.remember, let commit {
                do { try await commit(hash, grant) } catch {
                    return .failure(RPCError(code: RPCError.internalError, message: "Agneta couldn't save \(name)'s access: \(error.localizedDescription)"))
                }
                guard !shutDown, apps[appID] != nil else { return .failure(RPCError(code: RPCError.internalError, message: "The app disconnected")) }
            }
            tokens[hash] = grant
            if !answer.remember { onceTokens[appID] = hash }
            onEvent(.paired(tokenHash: hash, grant: grant))
            apps[appID]?.grant = grant // the live entry, not a copy from before the approval
            return .success(["token": .string(token), "accounts": .array(answer.accounts.map { .string($0) }),
                             "workspace": Self.workspace(of: grant, in: context).map { .string($0.path(percentEncoded: false)) } ?? .null])
        }
        if method == "initialize" {
            guard let token = params?["_meta"]?["agneta"]?["token"]?.stringValue, let grant = tokens[Self.hash(token)] else {
                return .failure(Self.notPaired)
            }
            // "Allow Once" covers only the connection that paired.
            if !grant.remembered, onceTokens[appID] != Self.hash(token) { return .failure(Self.notPaired) }
            // A verified grant is still that app: the token alone, copied into another program, isn't enough.
            if grant.verified {
                let peer = port.flatMap { client in serverPort.flatMap { PeerIdentity.forLoopbackPort(client, serverPort: $0) } }
                guard GrantScope.identityMatches(grant, peer) else {
                    return .failure(RPCError(code: -32001, message: "This connection isn't \(grant.app) as it was paired; pair again",
                                             data: ["agneta": ["needsPairing": true]]))
                }
            }
            traces?.mask.register(token)
            app.grant = grant
            apps[appID] = app
            return .success(initializeResult(grant))
        }
        guard let grant = app.grant else { return .failure(Self.notPaired) }
        if method == "session/new" { return await newSession(appID, grant: grant, params: params) }
        if method == "agneta/trace/read" { return await readTrace(grant: grant, params: params) }
        if method == "session/load" { return await loadSession(appID, grant: grant, params: params) }
        if method == "agneta/fork" { return await forkSession(appID, grant: grant, params: params) }
        guard Self.sessionMethods.contains(method) else {
            return .failure(RPCError(code: RPCError.methodNotFound, message: "Agneta doesn't offer \(method)"))
        }
        guard let id = params?["sessionId"]?.stringValue, let session = sessions[id], session.app == appID else {
            return .failure(RPCError(code: RPCError.invalidParams, message: "Unknown session"))
        }
        let generation = session.generation
        let trace = traces?.session(id)
        if method == "session/close" {
            // The session ends whatever the engine answers, and if it doesn't answer at all.
            trace?.writer.record("lifecycle", ["event": "stop", "by": "app", "reason": "closed"])
            await Self.closeOnEngine(session)
            await end(id, .closed)
            return .success([:])
        }
        if method == "session/prompt", runningTurns[id] != nil || waiting.contains(where: { $0.session == id }) {
            // One turn at a time per session; add to a running turn with agneta/steer.
            return .failure(RPCError(code: Self.turnBusy, message: "A turn is already running in this session; steer it or wait"))
        }
        if method == "session/prompt" {
            if let refusal = pausedRefusal(session.account) { return .failure(refusal) }
            do {
                guard try await admit(id, account: session.account) else { return .success(["stopReason": "cancelled"]) }
            } catch let error as RPCError {
                return .failure(error)
            } catch {
                return .failure(RPCError(code: RPCError.internalError, message: "\(error)"))
            }
            onEvent(.turnStarted(id))
            trace?.turnStarted(prompt: params?["prompt"])
        }
        // A session that ended meanwhile already let its turn go; one reopened under this id has a turn of its own.
        defer { if method == "session/prompt", current(id, generation) { finishTurn(id) } }
        // Agneta's own methods, so apps never need an engine's names.
        var engineMethod = method
        var engineParams = params?.setting("sessionId", to: .string(session.engineSession))
        let engine = session.lease.engine
        // A mode the engine's adapter doesn't allow would leave the session outside what Agneta set up: on engines
        // that run their own tools, one that stops asking skips Agneta's permission checks; on OpenCode, another agent
        // drops Agneta's, with the session's instructions.
        if let mode = method == "session/set_mode" ? params?["modeId"]?.stringValue
                : (method == "session/set_config_option" && params?["configId"]?.stringValue == "mode" ? params?["value"]?.stringValue : nil),
           !engine.permitsMode(mode) {
            return .failure(RPCError(code: RPCError.invalidParams, message: "\(engine.displayName)'s \(mode) mode would leave what Agneta set up for this session",
                                     data: ["agneta": ["unenforceable": ["mode"]]]))
        }
        switch method {
        case "agneta/instructions/set":
            guard let text = params?["text"]?.stringValue else { return .failure(RPCError(code: RPCError.invalidParams, message: "text is required")) }
            // "replace" sets the whole instructions; "append" adds a named part, which a later append with the same key replaces.
            let appendKey = params?["mode"]?.stringValue == "append" ? (params?["key"]?.stringValue ?? "app") : nil
            guard let request = engine.setInstructions(session.engineSession, text: text, appendKey: appendKey) else {
                return .failure(Self.unsupported(engine, "change instructions during a session"))
            }
            (engineMethod, engineParams) = (request.method, request.params)
        case "agneta/steer":
            guard engine.capabilities.steer else { return .failure(Self.unsupported(engine, "steer a running turn")) }
            guard runningTurns[id] != nil, let request = engine.steer(session.engineSession, run: session.activeRun, prompt: params?["prompt"] ?? .array([])) else {
                let error = RPCError(code: Self.noTurnRunning, message: "No turn is running to steer")
                record(method, params: params, result: .failure(error), in: trace)
                return .failure(error)
            }
            (engineMethod, engineParams) = (request.method, request.params)
        default:
            break
        }
        let watchdog = method == "session/prompt" ? Task { [weak self] in await self?.watch(id, generation: generation, limits: session.policy.limits) } : nil
        defer { watchdog?.cancel() }
        do {
            var result = try await session.lease.peer.request(engineMethod, engineParams)
            if method == "session/prompt" {
                watchdog?.cancel()
                // The session may have ended (or been reopened) while the engine worked: the result goes back, but
                // the router's state and the record of turns belong to the session as it is now.
                guard current(id, generation) else { return .success(result.setting("sessionId", to: .string(id))) }
                if let hit = sessions[id]?.limitHit {
                    // ACP has a stop reason for too many model turns; time and cost stop as cancelled, with the reason beside it.
                    if hit.limit == "maxTurns" { result = result.setting("stopReason", to: "max_turn_requests") }
                    result = result.setting("_meta", to: (result["_meta"] ?? [:]).setting("agneta/limit@1", to: ["limit": .string(hit.limit), "value": hit.value]))
                    sessions[id]?.limitHit = nil
                }
                let reason = result["stopReason"]?.stringValue ?? "end_turn"
                sessions[id]?.activeRun = nil
                if let summary = await trace?.turnEnded(stopReason: reason, usage: result["usage"]) {
                    result = result.setting("_meta", to: (result["_meta"] ?? [:]).setting("agneta/usage@1", to: usage(summary, account: session.account)))
                }
                if current(id, generation) { onEvent(.turnEnded(id, stopReason: reason)) }
            }
            if method == "agneta/steer" {
                let delivered = engine.steerResult(result)
                guard delivered.accepted else {
                    let error = RPCError(code: Self.noTurnRunning, message: "The turn ended before the input arrived")
                    record(method, params: params, result: .failure(error), in: trace)
                    return .failure(error)
                }
                result = ["delivery": "accepted", "runId": (delivered.run ?? session.activeRun).map(JSONValue.string) ?? .null]
            }
            record(method, params: params, result: .success(result), in: trace)
            return .success(result["sessionId"] == nil ? result : result.setting("sessionId", to: .string(id)))
        } catch let error as RPCError {
            var error = error
            if method == "session/prompt", current(id, generation) {
                sessions[id]?.activeRun = nil
                sessions[id]?.limitHit = nil // a stale flag would mislabel the next turn
                if let limit = RateLimit.detect(error.message) {
                    error = await rateLimited(id, account: session.account, limit: limit, error: error)
                } else if Self.isAuthRequired(error) {
                    error = signInNeeded(error, account: session.account)
                }
                await trace?.turnEnded(stopReason: "error", usage: nil, error: error.message)
                if current(id, generation) { onEvent(.turnEnded(id, stopReason: "error")) }
            }
            record(method, params: params, result: .failure(error), in: trace)
            return .failure(error)
        } catch {
            if method == "session/prompt", current(id, generation) {
                sessions[id]?.activeRun = nil
                sessions[id]?.limitHit = nil
                await trace?.turnEnded(stopReason: "error", usage: nil, error: "The engine stopped")
                if current(id, generation) { onEvent(.turnEnded(id, stopReason: "error")) }
            }
            return .failure(RPCError(code: RPCError.internalError, message: "The engine stopped"))
        }
    }

    /// Settings and steering from the app, in the trace.
    func record(_ method: String, params: JSONValue?, result: Result<JSONValue, RPCError>, in trace: TraceSession?) {
        guard let trace else { return }
        var request = params?.objectValue ?? [:]
        request["sessionId"] = nil
        if method.contains("steer") {
            var fields: [String: JSONValue] = ["event": "steer", "request": .object(request)]
            switch result {
            case .success: fields["delivery"] = "accepted"
            case .failure(let error): fields["delivery"] = "rejected"; fields["error"] = .string(error.message)
            }
            trace.writer.record("lifecycle", fields)
        } else if method.hasPrefix("session/set_") || method.contains("system-prompt") || method.hasPrefix("agneta/instructions") {
            var fields: [String: JSONValue] = ["method": .string(method), "request": .object(request), "by": "app"]
            if case .failure(let error) = result { fields["error"] = .string(error.message) }
            trace.writer.record("config", fields)
        }
    }

    /// An engine's "sign in first" (ACP's auth_required, -32000, or its words): the user must act in Agneta.
    static func isAuthRequired(_ error: RPCError) -> Bool {
        error.code == -32000 || error.message.range(of: "auth(entication)? required|not (signed|logged) in|please (log|sign) in", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Says so to Agneta's UI and puts it in the app's error data, so the app can ask the user to open Agneta.
    func signInNeeded(_ error: RPCError, account: String) -> RPCError {
        onEvent(.needsSignIn(account: account))
        let data = (error.data?.objectValue != nil ? error.data! : [:]).setting("agneta", to: ["needsSignIn": .string(account)])
        return RPCError(code: error.code, message: "\(accounts[account]?.label ?? "This account") needs you to sign in again in Agneta", data: data)
    }

    /// Runs `work` for at most `seconds`: a stuck engine mustn't hold up Stop, a disconnect or Remove Access
    ///. Ending the session afterwards releases (and stops) a dedicated engine regardless.
    /// Returns at the deadline whatever `work` is doing. Not a task group: a group waits for every child before
    /// it returns, and a request to an engine that never answers ignores cancellation, so the bound never ended.
    /// Unfinished work goes on in the background until the engine answers or its connection closes.
    static func bounded(seconds: Double = 5, _ work: @escaping @Sendable () async -> Void) async {
        let once = OnceFlag()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { await work(); if once.take() { continuation.resume() } }
            Task { try? await Task.sleep(for: .seconds(seconds)); if once.take() { continuation.resume() } }
        }
    }

    static let noTurnRunning: Int64 = -32010
    static let turnBusy: Int64 = -32011
    static let engineCantDoThat: Int64 = -32014

    /// A feature this session's engine doesn't have: said plainly, never a silent no-op.
    static func unsupported(_ engine: any EngineAdapter, _ what: String) -> RPCError {
        RPCError(code: engineCantDoThat, message: "\(engine.displayName) can't \(what)", data: ["agneta": ["engine": .string(engine.id)]])
    }

    /// What a session can do beyond plain ACP, so the app can offer it.
    static func capabilities(_ engine: any EngineAdapter) -> JSONValue {
        let c = engine.capabilities
        return ["engine": .string(engine.id), "steer": .bool(c.steer), "fork": .bool(c.fork),
                "instructionsBetweenTurns": .bool(c.instructionsBetweenTurns), "reportsCost": .bool(c.reportsCost)]
    }

    /// `agneta/trace/read`: a page of one of this app's own tasks, running or finished.
    func readTrace(grant: Grant, params: JSONValue?) async -> Result<JSONValue, RPCError> {
        guard let traces else { return .failure(RPCError(code: RPCError.methodNotFound, message: "Traces are off")) }
        guard let task = params?["sessionId"]?.stringValue, !task.contains("/"), !task.contains(".."),
              traces.meta(task: task)?["app"]?["grant"]?.stringValue == grant.id else {
            return .failure(RPCError(code: RPCError.invalidParams, message: "Unknown session"))
        }
        let types = params?["types"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) } ?? Traces.defaultTypes
        let limit = min(max(Int(params?["limit"]?.intValue ?? 500), 1), 5_000)
        // Read off the router: a page is file work, and the router serves every app.
        let after = params?["after"]?.intValue ?? 0
        guard let page = await Task.detached(priority: .utility, operation: { traces.read(task: task, after: after, types: types, limit: limit) }).value else {
            return .failure(RPCError(code: RPCError.invalidParams, message: "Unknown session"))
        }
        return .success(["records": .array(page.records), "next": page.next.map(JSONValue.int) ?? .null, "complete": .bool(page.complete)])
    }

    func appNotification(_ appID: UUID, method: String, params: JSONValue?) async {
        guard Self.sessionNotifications.contains(method), let id = params?["sessionId"]?.stringValue,
              let session = sessions[id], session.app == appID else { return }
        // Cancel bypasses the queue: a waiting turn is simply taken out.
        if method == "session/cancel", cancelWaiting(id) { return }
        try? await session.lease.peer.notify(method, params?.setting("sessionId", to: .string(session.engineSession)))
    }

    func initializeResult(_ grant: Grant) -> JSONValue {
        [
            "protocolVersion": 1,
            "agentCapabilities": [
                "loadSession": true,
                "promptCapabilities": ["image": true, "audio": false, "embeddedContext": true],
                "mcpCapabilities": ["http": true, "sse": false],
                "sessionCapabilities": ["close": [:]],
            ],
            "authMethods": [],
            "agentInfo": ["name": "agneta", "title": "Agneta", "version": .string(Router.version)],
            "_meta": ["agneta": [
                "extensions": [.string(SessionPolicy.key), "agneta/task@1", "agneta/instructions", "agneta/instructions@1",
                               "agneta/steer@1", "agneta/usage@1", "agneta/trace@1", "agneta/limit@1", "agneta/queue@1", "agneta/rateLimited@1", "agneta/fork@1"],
                "accounts": .array(grant.accounts.compactMap { id in
                    accounts[id].map { account in
                        ["id": .string(id), "label": .string(account.label), "paused": .bool(paused.contains(id)),
                         "capabilities": engine(for: id, in: grant).map(Self.capabilities) ?? .null]
                    }
                }),
                // What the user allowed, and the app's own workspace (within it).
                "scope": ["tools": .string(grant.tools.rawValue), "folders": .array(grant.folders.map(JSONValue.string))],
                "workspace": Self.workspace(of: grant, in: context).map { .string($0.path(percentEncoded: false)) } ?? .null,
            ]],
        ]
    }

    /// Agneta's version, in `initialize` and every trace's `meta`.
    public static let version = "0.1.0"

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }

    public var sessionCount: Int { sessions.count }
}
