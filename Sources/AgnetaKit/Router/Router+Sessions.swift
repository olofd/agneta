// Opening sessions: `session/new`, `session/load` and `agneta/fork` share one authorization step and one launch
// path, and differ only in what they ask of the engine. Also the checks a session's policy and tool servers pass,
// and the trace each opened session starts or continues.
import Foundation

extension Router {
    /// A session's policy held to its app's grant: one the app didn't send gets no more tools than granted;
    /// anything beyond the grant is refused, naming the field.
    static func fit(_ policy: SessionPolicy, sent: Bool, grant: Grant) -> Result<SessionPolicy, RPCError> {
        var policy = policy
        if !sent, policy.tools.rank > grant.tools.rank { policy.tools = grant.tools }
        if let refusal = GrantScope.check(policy, against: grant) { return .failure(refusal.rpcError) }
        return .success(policy)
    }

    /// The app's own workspace, made when it paired.
    static func workspace(of grant: Grant, in context: PolicyContext) -> URL? {
        // Its last component never resolved: a session may have replaced the folder with a link (OwnFolder).
        context.appWorkspaces.map { $0.realFileURL.appending(path: grant.id, directoryHint: .isDirectory) }
    }

    /// An app's tool servers must be Streamable HTTP on loopback: a stdio server would be a command the
    /// engine runs inside its sandbox, and a remote one a host the policy didn't allow.
    static func refuseServers(_ servers: [JSONValue]) -> RPCError? {
        for server in servers {
            let type = server["type"]?.stringValue ?? (server["command"] != nil ? "stdio" : "?")
            guard type == "http", let raw = server["url"]?.stringValue, let url = URL(string: raw),
                ["http", "https"].contains(url.scheme ?? ""),
                ["127.0.0.1", "localhost", "::1"].contains(url.host() ?? "")
            else {
                return RPCError(
                    code: RPCError.invalidParams, message: "Agneta takes only loopback HTTP tool servers",
                    data: [
                        "agneta": [
                            "unenforceable": ["mcpServers"],
                            "reason": .string("type \(type), url \(server["url"]?.stringValue ?? "none")")
                        ]
                    ])
            }
        }
        return nil
    }

    /// Loopback ports of the app's MCP servers, which the engine's sandbox must allow.
    static func loopbackPorts(_ servers: [JSONValue]) -> [Int] {
        servers.compactMap { server in
            guard let raw = server["url"]?.stringValue, let url = URL(string: raw),
                ["127.0.0.1", "localhost", "::1"].contains(url.host() ?? "")
            else { return nil }
            return url.port ?? (url.scheme == "https" ? 443 : 80)
        }
    }

    // MARK: Opening sessions
    //
    // `session/new`, `session/load` and `agneta/fork` differ only in what they ask of the engine. What a session may
    // do is decided once, in `authorize`, so no path checks less than another; then its engine starts (`launch`), it
    // becomes reachable (`register`), the engine sets it up (`prepare`), and Agneta's UI is told (`announce`).

    /// What an authorized session runs with.
    struct Plan {
        var account: String
        /// The engine the task runs on (Router.taskEngine).
        var engine: any EngineAdapter
        var policy: SessionPolicy
        var servers: [JSONValue]
        var instructions: String?
        /// What the task can really do (SandboxResolution.Outcome.effective), reported to the app.
        var sandbox: Sandbox = .contained
        /// The results it declared (agneta/result), and its route on Agneta's result server once given one.
        var results: ResultDeclaration?
        var resultRoute: ResultServer.Route?
        /// The MCP servers the engine gets: the app's, and Agneta's result server for a session that declared results.
        var engineServers: [JSONValue] { servers + (resultRoute.map { [$0.server] } ?? []) }
    }

    /// Every check a session passes before an engine starts: an account the app was granted, not paused; an engine
    /// the grant allows that the account's provider supports and that's here (`taskEngine`); a policy that parses and
    /// fits the grant, a contained one reaching only its app's own sockets and ports or sockets in its folders
    /// (ToolReach); tool servers Agneta can confine; and a cost limit only where the engine reports cost (on
    /// another it would silently never trip). `sent`: the policy came from the app (or the task
    /// it resumes), so it's held to the grant as it is; one Agneta supplies gets no more tools than granted.
    func authorize(
        app appID: UUID, grant: Grant, account: String?, engine requested: String? = nil, resuming: Bool = false,
        cwd: String?,
        policy value: JSONValue?, sent: Bool, appTools: JSONValue? = nil, results resultsValue: JSONValue? = nil,
        servers: [JSONValue], instructions: String?
    ) async -> Result<Plan, RPCError> {
        guard let account, grant.accounts.contains(account), accounts[account] != nil else {
            return .failure(
                RPCError(code: RPCError.invalidParams, message: "This app isn't allowed to use that account"))
        }
        if let refusal = pausedRefusal(account) { return .failure(refusal) }
        guard let cwd else { return .failure(RPCError(code: RPCError.invalidParams, message: "cwd is required")) }
        // The app's own workspace is Agneta's folder: whatever a session planted in its place is put right first.
        if let root = context.appWorkspaces, let workspace = Self.workspace(of: grant, in: context) {
            _ = try? OwnFolder.ensure(workspace, under: root)
        }
        var policy: SessionPolicy
        do { policy = try SessionPolicy.parse(value, cwd: cwd, context: context) } catch let rejection
            as PolicyRejection
        {
            return .failure(rejection.rpcError)
        } catch {
            return .failure(RPCError(code: RPCError.invalidParams, message: "Invalid policy"))
        }
        switch Self.fit(policy, sent: sent, grant: grant) {
        case .success(let fitted): policy = fitted
        case .failure(let refusal): return .failure(refusal)
        }
        do { policy.appTools = try AppToolsLoad.parse(appTools) } catch let rejection as PolicyRejection {
            return .failure(rejection.rpcError)
        } catch {
            return .failure(RPCError(code: RPCError.invalidParams, message: "Invalid \(AppToolsLoad.key)"))
        }
        let results: ResultDeclaration?
        do { results = try ResultDeclaration.parse(resultsValue) } catch { return .failure(error.rpcError) }
        if let refusal = Self.refuseServers(servers) { return .failure(refusal) }
        let engine: any EngineAdapter
        let wanted =
            policy.requestedSandbox.map { min($0, grant.ceiling) }
            ?? (policy.tools == .workspace ? grant.ceiling : .contained)
        switch taskEngine(account: account, requested: requested, resuming: resuming, grant: grant, sandbox: wanted) {
        case .success(let adapter): engine = adapter
        case .failure(let refusal): return .failure(refusal)
        }
        if let taken = servers.compactMap({ $0["name"]?.stringValue }).first(where: {
            engine.reservedToolServers.contains($0) || ResultServer.isReserved($0)
        }) {
            return .failure(
                RPCError(
                    code: RPCError.invalidParams,
                    message: "\(engine.displayName) uses the tool server name \(taken) for its own tools",
                    data: ["agneta": ["unenforceable": ["mcpServers"], "reason": .string("reserved name \(taken)")]]))
        }
        // The sandbox, decided in one place (SandboxResolution): the user's choice for the app (its grant's ceiling) is the most,
        // the app may ask for less, and the engine must be able to provide what's asked.
        guard let kind = accounts[account]?.kind else {
            return .failure(RPCError(code: RPCError.invalidParams, message: "Unknown account"))
        }
        let effective: Sandbox
        switch SandboxResolution.resolve(
            requested: policy.requestedSandbox, ceiling: grant.ceiling,
            levels: ProviderEngines.sandboxLevels(engine.id, for: kind), tools: policy.tools,
            provider: accounts[account]?.label ?? account, why: ProviderEngines.uncontainedReason(engine.id, for: kind))
        {
        case .success(let outcome):
            policy.sandbox = outcome.profile
            effective = outcome.effective
        case .failure(let refusal): return .failure(refusal.rpcError)
        }
        // A narrowing the engine can't honour on this account would leave it offering a tool the app left out.
        if let reason = engine.builtinsRefusal(policy, kind: kind) {
            return .failure(PolicyRejection(field: "builtins", reason: reason).rpcError)
        }
        if policy.limits.maxCostUSD != nil, !engine.capabilities.reportsCost {
            return .failure(
                PolicyRejection(
                    field: "limits",
                    reason: "\(engine.displayName) doesn't report cost, so maxCostUSD can't be enforced"
                ).rpcError)
        }
        // Developer access builds with the app's own caches, warm across its sessions and apart from the user's.
        if policy.sandbox == .developer {
            let root =
                context.appWorkspaces
                ?? FileManager.default.temporaryDirectory.appending(path: "agneta-apps", directoryHint: .isDirectory)
            policy.buildCaches = root.realFileURL.appending(
                path: ".build-caches/\(grant.id)", directoryHint: .isDirectory)
        }
        // A contained task's sockets and ports: within its folders, or the app's own (ToolReach). Last, since it waits:
        // the probes run off the router (one app's slow or silent servers never hold up another's), and nothing after
        // them reads the router's state. What a later step needs is checked again after its own waits (`refusal`).
        let unresolved = effective == .contained ? ToolReach.unresolved(policy, grant: grant) : []
        if unresolved.count > ToolReach.most {
            return .failure(
                PolicyRejection(
                    field: policy.toolPorts.count >= policy.toolSockets.count ? "toolPorts" : "toolSockets",
                    reason:
                        "a contained session may name at most \(ToolReach.most) sockets and ports beyond its folders, "
                        + "not \(unresolved.count)"
                ).rpcError)
        }
        if !unresolved.isEmpty {
            let app = reachingApp(appID, grant: grant)
            // One check per app at a time: an app opening many sessions at once can't flood the probes' threads.
            await beginReachCheck(grant.id)
            policy.servedByApp = await ToolReach.served(unresolved, by: app, lookup: reach)
            endReachCheck(grant.id)
            policy.reachCheck = ToolReach.Check(app: app, name: grant.app, endpoints: unresolved)
        }
        if let refusal = GrantScope.reach(policy, against: grant, sandbox: effective) {
            return .failure(refusal.rpcError)
        }
        return .success(
            Plan(
                account: account, engine: engine, policy: policy, servers: servers, instructions: instructions,
                sandbox: effective, results: results))
    }

    /// Waits until no other reach check of this grant's is running, then holds the turn.
    func beginReachCheck(_ grant: String) async {
        guard reachChecks[grant] != nil else {
            reachChecks[grant] = []
            return
        }
        await withCheckedContinuation { reachChecks[grant, default: []].append($0) }
    }

    /// Hands the turn to the grant's next waiting check, or frees it.
    func endReachCheck(_ grant: String) {
        guard var waiting = reachChecks[grant], !waiting.isEmpty else {
            reachChecks[grant] = nil
            return
        }
        let next = waiting.removeFirst()
        reachChecks[grant] = waiting
        next.resume()
    }

    /// Who counts as the app for what it serves: a verified grant's team, or the processes holding its connection now,
    /// as instances (a pid reused later is another process).
    func reachingApp(_ appID: UUID, grant: Grant) -> ToolReach.App {
        if grant.verified, let team = grant.team { return ToolReach.App(team: team, processes: []) }
        let pids = apps[appID]?.ports.map { reach.connection($0.client, $0.server) } ?? []
        return ToolReach.App(team: nil, processes: pids.compactMap(reach.instance))
    }

    /// The refusal for anything new on a paused account, or nil when it isn't paused.
    func pausedRefusal(_ account: String) -> RPCError? { paused.contains(account) ? pausedError(account) : nil }

    func pausedError(_ account: String) -> RPCError {
        RPCError(
            code: Self.accountPaused, message: "\(accounts[account]?.label ?? "This account") is paused in Agneta",
            data: ["agneta": ["paused": .string(account)]])
    }

    /// Why a saved task can't continue on its engine, or nil: a task resumes (or is forked) only in a state format
    /// the engine that saved it still reads.
    func savedStateRefusal(_ meta: JSONValue, engine: any EngineAdapter) -> RPCError? {
        let format = meta["engine"]?["stateFormat"]?.stringValue ?? "unknown"
        guard format != engine.stateFormat else { return nil }
        return RPCError(
            code: RPCError.invalidParams,
            message:
                "This task can't continue: \(engine.displayName) now stores sessions as \(engine.stateFormat), not \(format)",
            data: [
                "agneta": [
                    "stateChanged": [
                        "engine": .string(engine.id), "saved": .string(format), "current": .string(engine.stateFormat)
                    ]
                ]
            ])
    }

    /// Starts (or joins) the plan's engine and routes its messages. `key` returns to an earlier engine home.
    func launch(_ plan: Plan, key: String?) async -> Result<EngineLease, RPCError> {
        do {
            let lease = try await engines.open(
                account: plan.account, engine: plan.engine, policy: plan.policy,
                mcpPorts: Self.loopbackPorts(plan.engineServers), key: key,
                session: EngineSessionSpec(
                    policy: plan.policy, servers: plan.engineServers, instructions: plan.instructions))
            await wire(lease)
            return .success(lease)
        } catch let error as RPCError {
            return .failure(error)
        } catch {
            return .failure(RPCError(code: RPCError.internalError, message: "The engine didn't start"))
        }
    }

    /// Makes a session reachable, by Agneta's id and by the engine's. Returns its generation.
    func register(_ id: String, app: UUID, meter: String, plan: Plan, lease: EngineLease, engineSession: String) -> UUID
    {
        var session = Session(
            app: app, account: plan.account, lease: lease, engineSession: engineSession, policy: plan.policy,
            appServers: Set(plan.servers.compactMap { $0["name"]?.stringValue }))
        session.sandbox = plan.sandbox
        session.meter = meter
        session.results = plan.results
        sessions[id] = session
        byEngine[key(lease.key, engineSession)] = id
        return session.generation
    }

    /// The engine's setup of an opened session: the adapter's own requests, then the instructions, on engines that
    /// take them per session (those configured per process got them at launch). A session that would run without
    /// the instructions it was given doesn't open.
    func prepare(_ lease: EngineLease, _ engineSession: String, instructions: String?) async throws {
        for request in lease.engine.prepareSession(engineSession) {
            _ = try await lease.peer.request(request.method, request.params)
        }
        if let instructions,
            let request = lease.engine.setInstructions(engineSession, text: instructions, appendKey: nil)
        {
            _ = try await lease.peer.request(request.method, request.params)
        }
    }

    /// Takes back a session whose opening failed, unless it ended meanwhile: then `end()` already let it go.
    func abandon(_ id: String, generation: UUID) async {
        guard current(id, generation), let session = sessions.removeValue(forKey: id) else { return }
        byEngine.removeValue(forKey: key(session.lease.key, session.engineSession))
        traces?.session(id)?.writer.record("end", [:])
        traces?.close(task: id)
        await Self.closeOnEngine(session)
        await engines.release(session.lease)
    }

    /// Shows an opened session in Agneta's UI. Only announced sessions are announced as ended.
    func announce(
        _ id: String, grant: Grant, account: String, sandbox: Sandbox, title: String, stopWarning: String?,
        resumed: Bool = false
    ) {
        let info = SessionInfo(
            id: id, app: grant.app, appIdentifier: grant.verified ? grant.identifier : nil, account: account,
            title: title,
            started: Date(), stopWarning: stopWarning, resumed: resumed, sandbox: sandbox)
        infos[id] = info
        onEvent(.sessionStarted(info))
    }

    /// The engine's result as the app gets it: Agneta's session id, and what Agneta adds in `_meta.agneta`.
    func reply(
        _ result: JSONValue, id: String?, plan: Plan, lease: EngineLease, adding extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var agneta: [String: JSONValue] = [
            "account": .string(plan.account), "dedicatedEngine": .bool(lease.dedicated),
            "capabilities": Self.capabilities(lease.engine), "sandbox": .string(plan.sandbox.rawValue),
            "appTools": Self.appTools(plan.policy, engine: lease.engine, kind: accounts[plan.account]?.kind),
            "builtins": Self.builtins(
                plan.policy, engine: lease.engine, kind: accounts[plan.account]?.kind, dedicated: lease.dedicated)
        ]
        if let results = plan.results {
            // What the session can ask for, and how its results come back (docs/APP_PROTOCOL.md, Structured results).
            agneta["results"] = [
                "declared": .array(results.names.map(JSONValue.string)),
                "every": results.every.map(JSONValue.string) ?? .null, "mechanism": "tool"
            ]
        }
        agneta.merge(extra) { _, new in new }
        return (id.map { result.setting("sessionId", to: .string($0)) } ?? result).setting(
            "_meta", to: ["agneta": .object(agneta)])
    }

    /// An engine's failure as the app sees it: a sign-in the account needs is named.
    func engineFailure(_ error: any Error, account: String, otherwise message: String) -> RPCError {
        guard let error = error as? RPCError else { return RPCError(code: RPCError.internalError, message: message) }
        return Self.isAuthRequired(error) ? signInNeeded(error, account: account) : error
    }

    static let appGone = RPCError(code: RPCError.internalError, message: "The app disconnected or lost access")
    static let endedWhileOpening = RPCError(
        code: RPCError.internalError, message: "The session ended while it was opening")

    func newSession(_ appID: UUID, grant: Grant, params: JSONValue?) async -> Result<JSONValue, RPCError> {
        let meta = params?["_meta"]
        let requested = meta?["agneta"]?["account"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let instructions =
            meta?["agneta/instructions"]?["text"]?.stringValue
            ?? params?["systemPrompt"]?["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined(
                separator: "\n")
        var plan: Plan, lease: EngineLease
        // Without an account named: the first one the app may use that's here.
        switch await authorize(
            app: appID, grant: grant, account: requested ?? grant.accounts.first { accounts[$0] != nil },
            engine: params?["_meta"]?["agneta"]?["engine"]?.stringValue, cwd: params?["cwd"]?.stringValue,
            policy: meta?[SessionPolicy.key], sent: meta?[SessionPolicy.key] != nil, appTools: meta?[AppToolsLoad.key],
            results: meta?[ResultDeclaration.key],
            servers: params?["mcpServers"]?.arrayValue ?? [], instructions: instructions)
        {
        case .success(let authorized): plan = authorized
        case .failure(let refusal): return .failure(refusal)
        }
        // The app's limits, checked and the task counted before anything waits, so a burst can't all pass; a task
        // that doesn't start after all is taken off the count.
        if let refusal = appLimitRefusal(grant, account: plan.account, newTask: .beforeCounting) {
            return .failure(refusal)
        }
        let counted = reserveTask(meter: grant.meter)
        var opened = false
        // Its id now: a session that declares results needs its route before the engine starts.
        let id = "s_" + UUID().uuidString.lowercased()
        defer {
            if opened {
                taskCommitted(meter: grant.meter, at: counted)
            } else {
                refundTask(meter: grant.meter, at: counted)
                if plan.resultRoute != nil { dropResults(id) }
            }
        }
        if let failure = await routeResults(&plan, session: id) { return .failure(failure) }
        switch await launch(plan, key: nil) {
        case .success(let started): lease = started
        case .failure(let error): return .failure(error)
        }
        if let refusal = refusal(appID, grant, plan, counted: true) {
            await engines.release(lease)
            return .failure(refusal)
        }
        beginOpening(lease.key)
        defer { endOpening(lease.key) }
        let engineSession: String
        var result: JSONValue
        do {
            let engineParams = lease.engine.newSession(
                cwd: plan.policy.workspace, servers: plan.engineServers, policy: plan.policy,
                title: meta?["agneta/task"]?["title"], instructions: plan.instructions)
            (engineSession, result) = try await freshSession(lease, EngineRequest("session/new", engineParams)) {
                $0["sessionId"]?.stringValue
            }
        } catch {
            await engines.release(lease)
            return .failure(engineFailure(error, account: plan.account, otherwise: "The engine stopped"))
        }
        // What the engine offers, as it set it before any default: Settings names the engine's own choice.
        if let options = result["configOptions"] {
            onEvent(.settingsSeen(account: plan.account, engine: plan.engine.id, options: options))
        }
        // The provider's default model and effort, where the app hasn't chosen yet (Router+Settings).
        result = await withDefaults(result, account: plan.account, lease: lease, engineSession: engineSession)
        // The app may have gone or lost access while the engine started: nothing to hand the session to.
        if let refusal = refusal(appID, grant, plan, counted: true) {
            await Self.closeOnEngine(lease, session: engineSession)
            await engines.release(lease)
            return .failure(refusal)
        }
        let generation = register(
            id, app: appID, meter: grant.meter, plan: plan, lease: lease, engineSession: engineSession)
        await deliverEarly(lease, engineSession)
        do {
            try await prepare(lease, engineSession, instructions: plan.instructions)
        } catch {
            await abandon(id, generation: generation)
            return .failure(engineFailure(error, account: plan.account, otherwise: "The engine stopped"))
        }
        guard current(id, generation) else { return .failure(Self.endedWhileOpening) }
        if let refusal = refusal(appID, grant, plan, counted: true) {
            await abandon(id, generation: generation)
            return .failure(refusal)
        }
        if let traces {
            openTrace(
                traces, task: id, grant: grant, accountID: plan.account, lease: lease, engineSession: engineSession,
                policy: plan.policy, sandbox: plan.sandbox, request: params, result: result,
                instructions: plan.instructions)
        }
        announce(
            id, grant: grant, account: plan.account, sandbox: plan.sandbox,
            title: meta?["agneta/task"]?["title"]?.stringValue ?? "AI task",
            stopWarning: meta?["agneta/task"]?["stopWarning"]?.stringValue)
        opened = true
        return .success(reply(result, id: id, plan: plan, lease: lease))
    }

    /// `session/load`: resumes one of this app's earlier tasks after a close or a restart. The engine that saved it
    /// returns to the same engine home (where it keeps the conversation) and replays the history as
    /// `session/update`s; the task's trace continues, its cost included. The app passes its tool servers again,
    /// since their bearers are per session.
    func loadSession(_ appID: UUID, grant: Grant, params: JSONValue?) async -> Result<JSONValue, RPCError> {
        guard let id = params?["sessionId"]?.stringValue, !id.contains("/"), !id.contains(".."),
            let traces, let meta = traces.meta(task: id), meta["app"]?["grant"]?.stringValue == grant.id
        else {
            return .failure(RPCError(code: RPCError.invalidParams, message: "Unknown session"))
        }
        // Reserved for the whole load, so a second load of the same task can't start a second engine.
        guard sessions[id] == nil, !loading.contains(id) else {
            return .failure(RPCError(code: RPCError.invalidParams, message: "The session is already open"))
        }
        loading.insert(id)
        defer { loading.remove(id) }
        guard let engineSession = meta["engine"]?["session"]?.stringValue,
            let engineKey = meta["engine"]?["key"]?.stringValue
        else {
            return .failure(RPCError(code: RPCError.invalidParams, message: "This session can't be resumed"))
        }
        let original = meta["request"]
        let policyValue = params?["_meta"]?[SessionPolicy.key] ?? original?["_meta"]?[SessionPolicy.key]
        let appTools = params?["_meta"]?[AppToolsLoad.key] ?? original?["_meta"]?[AppToolsLoad.key]
        let declared = params?["_meta"]?[ResultDeclaration.key] ?? original?["_meta"]?[ResultDeclaration.key]
        var plan: Plan, lease: EngineLease
        switch await authorize(
            app: appID, grant: grant, account: meta["account"]?["id"]?.stringValue,
            engine: meta["engine"]?["id"]?.stringValue,
            resuming: true,
            cwd: params?["cwd"]?.stringValue ?? original?["cwd"]?.stringValue,
            policy: policyValue, sent: policyValue != nil, appTools: appTools, results: declared,
            servers: params?["mcpServers"]?.arrayValue ?? [],
            instructions: params?["_meta"]?["agneta/instructions"]?["text"]?.stringValue
                ?? meta["instructions"]?.stringValue)
        {
        case .success(let authorized): plan = authorized
        case .failure(let refusal): return .failure(refusal)
        }
        // A task that ran on the shared engine (no built-in tools) resumes there: built-ins would run unconfined
        // by the broker.
        // Resuming isn't a new task, but what it spends is the app's.
        if let refusal = appLimitRefusal(grant, account: plan.account, newTask: .none) { return .failure(refusal) }
        if EngineKeys.isShared(engineKey), plan.policy.tools != .appOnly {
            return .failure(
                PolicyRejection(field: "tools", reason: "this task ran without built-in tools; resume it the same way")
                    .rpcError)
        }
        if let refusal = savedStateRefusal(meta, engine: plan.engine) { return .failure(refusal) }
        var loaded = false
        defer { if !loaded, plan.resultRoute != nil { dropResults(id) } }
        if let failure = await routeResults(&plan, session: id) { return .failure(failure) }
        switch await launch(plan, key: engineKey) {
        case .success(let started): lease = started
        case .failure(let error): return .failure(error)
        }
        if let refusal = refusal(appID, grant, plan) {
            await engines.release(lease)
            return .failure(refusal)
        }
        // Registered before loading, so the replayed history reaches the app under Agneta's id.
        let generation = register(
            id, app: appID, meter: grant.meter, plan: plan, lease: lease, engineSession: engineSession)
        let trace = startTrace(
            traces, task: id, accountID: plan.account, lease: lease, engineSession: engineSession, request: params,
            resumed: true)
        trace.writer.record(
            "lifecycle", ["event": "resumed", "pid": .int(Int64(lease.pid)), "request": params ?? .null])
        do {
            let result = try await lease.peer.request(
                "session/load",
                lease.engine.loadSession(
                    engineSession, cwd: plan.policy.workspace,
                    servers: plan.engineServers, policy: plan.policy,
                    instructions: plan.instructions))
            try await prepare(lease, engineSession, instructions: plan.instructions)
            // Ended while the engine replayed it (the app went or lost access, or the user stopped it): end() has
            // already let it go, and nothing may announce it now.
            guard current(id, generation) else { return .failure(Self.endedWhileOpening) }
            if let refusal = refusal(appID, grant, plan) {
                await abandon(id, generation: generation)
                return .failure(refusal)
            }
            announce(
                id, grant: grant, account: plan.account, sandbox: plan.sandbox,
                title: original?["_meta"]?["agneta/task"]?["title"]?.stringValue ?? "AI task",
                stopWarning: original?["_meta"]?["agneta/task"]?["stopWarning"]?.stringValue, resumed: true)
            loaded = true
            return .success(reply(result, id: nil, plan: plan, lease: lease, adding: ["resumed": true]))
        } catch {
            if current(id, generation) {
                trace.writer.record("lifecycle", ["event": "resume-failed", "reason": .string("\(error)")])
            }
            await abandon(id, generation: generation)
            return .failure(
                engineFailure(error, account: plan.account, otherwise: "The engine couldn't resume the session"))
        }
    }

    /// `agneta/fork`: a new task that starts with a copy of an earlier one's conversation, for a review that mustn't
    /// change the original. The engine exports the source session (starting it in its old home if the task is
    /// closed) and imports it into a fresh engine under the fork's own policy: by default the original one with
    /// read-only tools.
    func forkSession(_ appID: UUID, grant: Grant, params: JSONValue?) async -> Result<JSONValue, RPCError> {
        guard let source = params?["sessionId"]?.stringValue, !source.contains("/"), !source.contains(".."),
            let traces, let meta = traces.meta(task: source), meta["app"]?["grant"]?.stringValue == grant.id,
            let sourceSession = meta["engine"]?["session"]?.stringValue,
            let sourceKey = meta["engine"]?["key"]?.stringValue
        else {
            return .failure(RPCError(code: RPCError.invalidParams, message: "Unknown session"))
        }
        let original = meta["request"]
        var policyValue = params?["_meta"]?[SessionPolicy.key] ?? (original?["_meta"]?[SessionPolicy.key] ?? [:])
        // By default a fork only reads (within what the app was granted).
        if params?["_meta"]?[SessionPolicy.key] == nil {
            policyValue = policyValue.setting(
                "tools", to: .string((grant.tools.rank < SessionPolicy.Tools.read.rank ? grant.tools : .read).rawValue))
        }
        let appTools = params?["_meta"]?[AppToolsLoad.key] ?? original?["_meta"]?[AppToolsLoad.key]
        let declared = params?["_meta"]?[ResultDeclaration.key] ?? original?["_meta"]?[ResultDeclaration.key]
        let cwd = params?["cwd"]?.stringValue ?? original?["cwd"]?.stringValue
        var plan: Plan, lease: EngineLease
        switch await authorize(
            app: appID, grant: grant, account: meta["account"]?["id"]?.stringValue,
            engine: meta["engine"]?["id"]?.stringValue,
            resuming: true, cwd: cwd,
            policy: policyValue, sent: true, appTools: appTools, results: declared,
            servers: params?["mcpServers"]?.arrayValue ?? [],
            instructions: params?["_meta"]?["agneta/instructions"]?["text"]?.stringValue
                ?? meta["instructions"]?.stringValue)
        {
        case .success(let authorized): plan = authorized
        case .failure(let refusal): return .failure(refusal)
        }
        // The copy is made, and imported, by the engine that saved the task.
        if let refusal = savedStateRefusal(meta, engine: plan.engine) { return .failure(refusal) }
        // A fork is a new task: counted as `session/new` is.
        if let refusal = appLimitRefusal(grant, account: plan.account, newTask: .beforeCounting) {
            return .failure(refusal)
        }
        let counted = reserveTask(meter: grant.meter)
        var opened = false
        // Its id now: a fork that declares results needs its route before its engine starts.
        let id = "s_" + UUID().uuidString.lowercased()
        defer {
            if opened {
                taskCommitted(meter: grant.meter, at: counted)
            } else {
                refundTask(meter: grant.meter, at: counted)
                if plan.resultRoute != nil { dropResults(id) }
            }
        }
        if let failure = await routeResults(&plan, session: id) { return .failure(failure) }

        // 1. The conversation, from the engine that holds it.
        let exported: JSONValue
        do {
            if let open = sessions[source] {
                guard let request = open.lease.engine.exportSession(open.engineSession) else {
                    return .failure(Self.unsupported(open.lease.engine, "fork a session"))
                }
                exported = try await open.lease.peer.request(request.method, request.params)
            } else {
                let holder = try await engines.open(
                    account: plan.account, engine: plan.engine, policy: plan.policy, mcpPorts: [], key: sourceKey,
                    session: nil)
                defer { Task { await self.engines.release(holder) } }
                guard let request = holder.engine.exportSession(sourceSession) else {
                    return .failure(Self.unsupported(holder.engine, "fork a session"))
                }
                exported = try await holder.peer.request(request.method, request.params)
            }
        } catch {
            return .failure(
                RPCError(code: RPCError.internalError, message: "The engine couldn't copy the conversation: \(error)"))
        }

        // 2. Into a fresh engine, as a session of its own.
        switch await launch(plan, key: nil) {
        case .success(let started): lease = started
        case .failure(let error): return .failure(error)
        }
        if let refusal = refusal(appID, grant, plan, counted: true) {
            await engines.release(lease)
            return .failure(refusal)
        }
        beginOpening(lease.key)
        defer { endOpening(lease.key) }
        let engineSession: String, imported: JSONValue
        do {
            guard let request = lease.engine.importSession(exported) else {
                throw Self.unsupported(lease.engine, "fork a session")
            }
            let engine = lease.engine
            (engineSession, imported) = try await freshSession(lease, request) { engine.importedSession($0) }
        } catch {
            await engines.release(lease)
            return .failure(
                engineFailure(error, account: plan.account, otherwise: "The engine couldn't fork the session"))
        }
        if let refusal = refusal(appID, grant, plan, counted: true) {
            await Self.closeOnEngine(lease, session: engineSession)
            await engines.release(lease)
            return .failure(refusal)
        }
        let generation = register(
            id, app: appID, meter: grant.meter, plan: plan, lease: lease, engineSession: engineSession)
        await deliverEarly(lease, engineSession)
        do {
            let result = try await lease.peer.request(
                "session/load",
                lease.engine.loadSession(
                    engineSession, cwd: plan.policy.workspace,
                    servers: plan.engineServers, policy: plan.policy,
                    instructions: plan.instructions))
            try await prepare(lease, engineSession, instructions: plan.instructions)
            // Ended while the engine loaded it: end() has let it go, and it gets no trace or announcement.
            guard current(id, generation) else { return .failure(Self.endedWhileOpening) }
            if let refusal = refusal(appID, grant, plan, counted: true) {
                await abandon(id, generation: generation)
                return .failure(refusal)
            }
            var request = (params ?? [:]).setting("cwd", to: cwd.map(JSONValue.string) ?? .null)
            // The trace keeps what the fork runs with, so loading it later gets the same.
            var recorded = (request["_meta"] ?? [:]).setting(SessionPolicy.key, to: policyValue)
            if let appTools { recorded = recorded.setting(AppToolsLoad.key, to: appTools) }
            if let declared { recorded = recorded.setting(ResultDeclaration.key, to: declared) }
            request = request.setting("_meta", to: recorded)
            openTrace(
                traces, task: id, grant: grant, accountID: plan.account, lease: lease, engineSession: engineSession,
                policy: plan.policy, sandbox: plan.sandbox, request: request, result: result,
                instructions: plan.instructions)
            traces.session(id)?.writer.record(
                "lifecycle", ["event": "forked", "from": .string(source), "messages": imported["messageCount"] ?? .null]
            )
            announce(
                id, grant: grant, account: plan.account, sandbox: plan.sandbox,
                title: params?["_meta"]?["agneta/task"]?["title"]?.stringValue
                    ?? "Review of " + (original?["_meta"]?["agneta/task"]?["title"]?.stringValue ?? "a task"),
                stopWarning: nil)
            opened = true
            return .success(reply(result, id: id, plan: plan, lease: lease, adding: ["forkOf": .string(source)]))
        } catch {
            await abandon(id, generation: generation)
            return .failure(
                engineFailure(error, account: plan.account, otherwise: "The engine couldn't fork the session"))
        }
    }

    /// Opens a task's trace, or continues a resumed one, and follows its engine: what its costs mean, how it names
    /// tools, the plan's usage, its usage ledger, and live delivery when the app asked for it.
    /// A new task's `meta` is its trace's first record, written before the engine's messages can reach the trace.
    func startTrace(
        _ traces: Traces, task: String, accountID: String, lease: EngineLease, engineSession: String,
        request: JSONValue?, resumed: Bool, meta: [String: JSONValue]? = nil
    ) -> TraceSession {
        for server in request?["mcpServers"]?.arrayValue ?? [] {
            for header in server["headers"]?.arrayValue ?? [] {
                if let value = header["value"]?.stringValue { traces.mask.register(value) }
            }
        }
        var forwarder: TraceForwarder?
        if let live = request?["_meta"]?["agneta/trace"], live["live"]?.boolValue == true,
            let peer = apps[sessions[task]?.app ?? UUID()]?.peer
        {
            let include =
                live["include"]?.arrayValue.map { Traces.defaultTypes.union($0.compactMap(\.stringValue)) }
                ?? Traces.defaultTypes
            forwarder = TraceForwarder(
                include: include,
                send: { records in
                    try? await peer.notify("agneta/trace", ["sessionId": .string(task), "records": .array(records)])
                },
                overflow: { after in
                    try? await peer.notify(
                        "agneta/trace", ["sessionId": .string(task), "records": [], "overflow": ["after": .int(after)]])
                })
            sessions[task]?.forwarder = forwarder
        }
        let trace = traces.open(task: task, lease: lease.key, engineSession: engineSession) { trace in
            if let forwarder { trace.writer.observe { forwarder.accept($0) } } // the live app gets `meta` too
            if let meta {
                trace.writer.record("meta", meta)
                // On disk before the reply: a load or fork right after it finds the task by this record
                // (Traces.meta reads the file), and a slow machine answered "Unknown session" to a fork sent at
                // once (CI, 2026-11-21). One write per opened task.
                trace.writer.flush()
            }
        }
        trace.set(billing: accounts[accountID]?.billing ?? "unknown")
        trace.identify(with: lease.engine)
        let report = onEvent
        trace.onPlanUsage { limits in report(.planUsage(account: accountID, limits: limits)) }
        if let root = lease.stateRoot {
            trace.follow(
                lease.engine.ledger(
                    stateRoot: root, engineSession: engineSession, workspace: sessions[task]?.policy.workspace),
                resumed: resumed)
        }
        return trace
    }

    /// Starts a new task's trace with everything that shapes the run (docs/DIAGNOSTICS.md, `meta`).
    func openTrace(
        _ traces: Traces, task: String, grant: Grant, accountID: String, lease: EngineLease, engineSession: String,
        policy: SessionPolicy, sandbox: Sandbox, request: JSONValue?, result: JSONValue, instructions: String?
    ) {
        let account = accounts[accountID]
        func paths(_ urls: [URL]) -> JSONValue { .array(urls.map { .string($0.path(percentEncoded: false)) }) }
        let meta: [String: JSONValue] = [
            "format": "agneta/trace",
            "agneta": ["version": .string(Self.version)],
            "app": [
                "name": .string(grant.app), "identifier": grant.identifier.map(JSONValue.string) ?? .null,
                "verified": .bool(grant.verified),
                "grant": .string(grant.id)
            ],
            "account": [
                "id": .string(accountID), "label": account.map { .string($0.label) } ?? .null,
                "kind": account.map { .string($0.kind.rawValue) } ?? .null,
                "billing": .string(account?.billing ?? "unknown"),
                "runner": runner(account: accountID, engine: lease.engine) == .native ? "native" : "brokered"
            ],
            "engine": [
                "id": .string(lease.engine.id), "stateFormat": .string(lease.engine.stateFormat),
                "info": lease.engineInfo ?? .null,
                "pid": .int(Int64(lease.pid)), "dedicated": .bool(lease.dedicated), "key": .string(lease.key),
                "startMs": lease.startMs.map(JSONValue.double) ?? .null, "session": .string(engineSession),
                "stateRoot": lease.stateRoot.map { .string($0.path(percentEncoded: false)) } ?? .null
            ],
            "policy": [
                "tools": .string("\(policy.tools)"), "network": .string("\(policy.network)"),
                "approval": .string("\(policy.approval)"),
                "workspace": .string(policy.workspace.path(percentEncoded: false)), "readable": paths(policy.readable),
                "writable": paths(policy.writable), "readOnly": paths(policy.readOnly), "denied": paths(policy.denied),
                // The mode the task ran in, and which variables the app set for its commands (names: values may hold paths of its own).
                "sandbox": .string(sandbox.rawValue),
                "toolEnvironment": .array(policy.toolEnvironment.keys.sorted().map(JSONValue.string)),
                // The groups the app kept (null: no narrowing), and those the engine offers (null: not known).
                "builtins": policy.builtins.map { .array($0.sorted().map { .string($0.rawValue) }) } ?? .null,
                "builtinsOffered": Self.builtins(
                    policy, engine: lease.engine, kind: account?.kind, dedicated: lease.dedicated)
            ],
            "request": request ?? .null,
            "engineResult": result,
            "instructions": instructions.map(JSONValue.string) ?? .null
        ]
        let trace = startTrace(
            traces, task: task, accountID: accountID, lease: lease, engineSession: engineSession, request: request,
            resumed: false, meta: meta)
        // Goose reports the model as a config option; other engines as `models`.
        let model =
            result["models"]?["currentModelId"]
            ?? result["configOptions"]?.arrayValue?.first { $0["id"]?.stringValue == "model" }?["currentValue"]
        trace.writer.record(
            "event",
            [
                "kind": "init", "model": model ?? .null,
                "configOptions": result["configOptions"] ?? .null, "mcpServers": request?["mcpServers"] ?? .null,
                "extensions": result["_meta"]?["extensionResults"] ?? .null, "engine": lease.engineInfo ?? .null
            ])
        if let startMs = lease.startMs {
            trace.writer.record(
                "lifecycle",
                [
                    "event": "engine-start", "pid": .int(Int64(lease.pid)),
                    "msToInitialize": .double((startMs * 10).rounded() / 10)
                ])
        }
    }
}
