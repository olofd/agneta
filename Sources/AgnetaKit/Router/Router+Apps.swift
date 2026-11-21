// The app side of the router: each app connection served until it closes, pairing and `initialize`, every request
// an app may make (sessions open in +Sessions, turns run in +Turns), and what a session's end leaves behind.
import CryptoKit
import Foundation

extension Router {

    /// Serves one app connection until it closes; its sessions are closed with it.
    public func serve(_ connection: WebSocketServer.Connection) async {
        let peer = RPCPeer { data in try await connection.send(data) }
        let id = connection.id
        let port = connection.remotePort
        let serverPort = connection.localPort
        guard !shutDown, apps.values.count(where: { $0.grant == nil }) < concurrency.unpaired else {
            connection.close(); return
        }
        apps[id] = App(
            peer: peer, grant: nil, ports: port.flatMap { client in serverPort.map { (client, $0) } },
            close: { connection.close() })
        let unpairedFor = concurrency.unpairedFor
        Task { [weak self] in
            try? await Task.sleep(for: unpairedFor)
            await self?.closeIfUnpaired(id)
        }
        if let traces { await peer.handle(tap: traces.appAttributor().frame) }
        await peer.handle(requests: { [weak self] method, params in
            guard let self else {
                return .failure(RPCError(code: RPCError.internalError, message: "Agneta is stopping"))
            }
            return await self.appRequest(id, port: port, serverPort: serverPort, method: method, params: params)
        })
        await peer.handle(notifications: { [weak self] method, params in
            await self?.appNotification(id, method: method, params: params)
        })
        // Until it has a grant, a connection's messages are small: a large one closes it.
        let (messages, input) = AsyncThrowingStream<Data, Error>.makeStream()
        let relay = Task { [weak self] in
            do {
                for try await message in connection.messages {
                    guard let self, await self.admits(id, size: message.count) else { connection.close(); break }
                    input.yield(message)
                }
                input.finish()
            } catch { input.finish(throwing: error) }
        }
        await peer.run(messages)
        relay.cancel()
        await disconnect(id)
        connection.close() // whatever ended it, the connection itself goes too
    }

    /// What of a pairing ask the grant doesn't give, each with why: a provider kind not connected or not ticked, an
    /// engine not allowed or not on this Mac, a mode the user lowered or an engine can't provide.
    func unmet(_ asked: GrantScope.Request, grant: Grant) -> [JSONValue] {
        var unmet: [JSONValue] = []
        let given = Set(grant.accounts.compactMap { accounts[$0]?.kind })
        for kind in asked.providers ?? [] where !given.contains(kind) {
            let connected = accounts.values.contains { $0.kind == kind }
            unmet.append([
                "provider": .string(kind.rawValue),
                "reason": .string(connected ? "the user didn't allow it" : "not connected in Agneta")
            ])
        }
        for engine in asked.engines ?? [] {
            if !grant.engines.allows(engine) {
                unmet.append(["engine": .string(engine), "reason": "the user didn't allow it"])
            } else if let reason = catalog.report(engine).reason {
                unmet.append(["engine": .string(engine), "reason": .string(reason)])
            }
        }
        if asked.sandbox == .developer, grant.ceiling == .contained {
            // Developer access is a terminal's commands: offered only with workspace tools.
            unmet.append([
                "sandbox": "developer",
                "reason": grant.tools == .workspace
                    ? "the user chose contained" : "developer access needs workspace tools"
            ])
        }
        if asked.sandbox == .contained {
            for kind in given {
                let engines = Access.engines(for: kind, allowed: grant.engines, catalog: catalog)
                if !engines.contains(where: { ProviderEngines.sandboxLevels($0, for: kind).contains(.contained) }) {
                    unmet.append([
                        "provider": .string(kind.rawValue), "sandbox": "contained",
                        "reason": .string("none of its allowed engines can keep its tasks contained")
                    ])
                }
            }
        }
        return unmet
    }

    func admits(_ app: UUID, size: Int) -> Bool { size <= concurrency.unpairedFrame || apps[app]?.grant != nil }

    func closeIfUnpaired(_ id: UUID) async {
        if let app = apps[id], app.grant == nil { await hangUp(app, reason: "didn't pair in time") }
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
        if session.results != nil { dropResults(id) }
        // Only a session whose start was announced has an end to announce (a load or fork cut short has none).
        let announced = infos.removeValue(forKey: id) != nil
        _ = cancelWaiting(id)
        let turn = runningTurns[id], trace = traces?.session(id)
        finishTurn(id)
        byEngine.removeValue(forKey: key(session.lease.key, session.engineSession))
        if let traces {
            traces.session(id)?.writer.record("end", [:])
            traces.close(task: id)
        }
        if announced { onEvent(.sessionEnded(id, ending)) }
        // What the engine recorded after the last read still counts: a turn cut off here, or rows that landed after an
        // idle session's last turn ended (a step OpenCode finished late). The engine's records, read once more. (Claude
        // Code's cost for a turn it never finished never arrives.)
        if turn.map({ $0.began && $0.counted }) ?? countsSpend(session.account), let trace {
            let before = trace.progress.taskCost
            await trace.pollLedger()
            addUsage(
                meter: turn?.meter ?? session.meter, AppMeter.Usage(cost: max(0, trace.progress.taskCost - before)))
        }
        // Its running prompt ends now, whatever the engine does: a shared engine stays up, and one stuck in a tool may
        // never answer it.
        if let call = inFlight.removeValue(forKey: id) {
            cutOff.insert(id)
            call.cancel()
        }
        // Live records still owed to the app go out, but an app that stopped reading can't hold up the engine's release.
        if let forwarder = session.forwarder { await Self.bounded(seconds: 2) { await forwarder.finish() } }
        await engines.release(session.lease)
    }

    /// The answer to a prompt whose limit Agneta enforced by ending the session: stopped by that limit, as when the
    /// engine stops in time, and marked so the app knows the session is gone.
    static func enforced(_ hit: LimitHit, session id: String) -> JSONValue {
        [
            "sessionId": .string(id), "stopReason": hit.limit == "maxTurns" ? "max_turn_requests" : "cancelled",
            "_meta": ["agneta/limit": hit.report.setting("sessionEnded", to: true)]
        ]
    }

    static let notPaired = RPCError(
        code: -32001, message: "Pair with Agneta first", data: ["agneta": ["needsPairing": true]])

    /// What an app may call on one of its sessions, besides pairing, `initialize`, `session/new`,
    /// `session/load`, `agneta/fork` and `agneta/trace/read`. Engine extras (steering, instructions)
    /// are reached through Agneta's own methods, which the engine's adapter maps.
    static let sessionMethods: Set<String> = [
        "session/prompt", "session/close", "session/set_mode", "session/set_config_option",
        "session/set_model", "agneta/steer", "agneta/instructions/set"
    ]
    /// The only notification an app may send on a session.
    static let sessionNotifications: Set<String> = ["session/cancel"]

    func appRequest(_ appID: UUID, port: Int?, serverPort: Int?, method: String, params: JSONValue?) async -> Result<
        JSONValue, RPCError
    > {
        guard !shutDown, var app = apps[appID] else { return .failure(Self.notPaired) }
        // What Agneta offers, and help for the user to connect a provider: before pairing too, so an app can find out
        // whether there's anything to ask for, and ask Agneta to set it up when there isn't.
        if method == "agneta/catalog" { return .success(catalogReport()) }
        if method == "agneta/setup" {
            var kind: AccountKind?
            if let raw = params?["kind"] {
                guard let name = raw.stringValue, let parsed = AccountKind(rawValue: name) else {
                    return .failure(
                        PolicyRejection(
                            field: "kind",
                            reason: "expected one of: \(AccountKind.allCases.map(\.rawValue).joined(separator: ", "))"
                        ).rpcError)
                }
                kind = parsed
            }
            onEvent(.setupRequested(app: params?["name"]?.stringValue ?? app.grant?.app ?? "An app", kind: kind))
            return .success(["shown": true])
        }
        if method == "agneta/pair" {
            let name = params?["name"]?.stringValue ?? "An app"
            // The scope is checked before the user sees anything: a folder Agneta would refuse is never offered.
            let scope: GrantScope.Request
            do {
                scope = try GrantScope.requested(params?["scope"], context: context, known: Set(catalog.entries.keys))
            } catch let rejection as PolicyRejection {
                return .failure(rejection.rpcError)
            } catch {
                return .failure(RPCError(code: RPCError.invalidParams, message: "Invalid scope"))
            }
            let peer = port.flatMap { client in
                serverPort.flatMap { PeerIdentity.forLoopbackPort(client, serverPort: $0) }
            }
            // Verified means a checkable signature: Apple-issued certificate and team, not just valid.
            let verified = peer?.trusted == true && peer?.identifier != nil
            // An app Agneta can't verify shows a code; the approval window shows the same one.
            var code: String?
            if !verified {
                // Uniform over all six-digit codes, from the system generator (cryptographic on Apple platforms).
                code = String(format: "%06ld", Int.random(in: 0..<1_000_000))
                try? await app.peer.notify("agneta/pairingCode", ["code": .string(code!), "name": .string(name)])
            }
            var request = PairingRequest(
                id: UUID(), app: name, peer: peer, code: code, tools: scope.tools, folders: scope.folders)
            request.sandbox = scope.sandbox ?? .default
            request.sandboxAsked = scope.sandbox
            request.providers = scope.providers
            request.engines = scope.engines
            pairing[appID] = request.id
            let decision = await approve(request)
            pairing[appID] = nil
            guard let answer = decision, !answer.accounts.isEmpty else {
                return .failure(RPCError(code: -32002, message: "\(name) wasn't allowed to use Agneta"))
            }
            // The app may have gone while the user decided (or Agneta reset): no grant nobody received.
            guard !shutDown, apps[appID] != nil else {
                return .failure(RPCError(code: RPCError.internalError, message: "The app disconnected"))
            }
            let token = Self.newToken(), hash = Self.hash(token)
            let identifier = verified ? peer?.identifier : nil, team = verified ? peer?.team : nil
            // "Always Allow" for an app that has it already replaces its access rather than adding to it, and its old
            // token stops working. A verified app keeps its grant (its workspace, and its tasks to resume) with what was
            // just allowed. An unverified app is only a name, which another program could give: its new grant starts
            // afresh, and the earlier one is removed. "Allow Once" leaves remembered access alone.
            let remembered = tokens.values.first {
                $0.remembered && Self.sameApp($0, app: name, identifier: identifier, team: team, verified: verified)
            }
            let earlier = answer.remember ? remembered : nil
            let renewed = earlier.flatMap { $0.verified ? $0 : nil }
            // The limits the user set for the app stay with it, whichever way it pairs again: a new grant isn't a fresh
            // budget. Allow Once counts against the remembered grant's usage.
            var grant = Grant(
                id: renewed?.id ?? UUID().uuidString, app: name, identifier: identifier, team: team, verified: verified,
                accounts: answer.accounts, engines: answer.engines, tools: scope.tools,
                folders: scope.folders.map { $0.path(percentEncoded: false) }, remembered: answer.remember,
                sandbox: answer.sandbox,
                limits: remembered?.limits ?? .none)
            if !answer.remember, let remembered { grant.countsAs = remembered.meter }
            // The app's own workspace, inside its grant whatever else it asked for.
            if let root = context.appWorkspaces {
                let workspace = root.appending(path: grant.id, directoryHint: .isDirectory)
                do {
                    try FileManager.default.createDirectory(
                        at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                } catch {
                    return .failure(
                        RPCError(code: RPCError.internalError, message: "Agneta couldn't create the app's workspace"))
                }
                grant.folders.append(workspace.realFileURL.path(percentEncoded: false))
            }
            if answer.remember, let commit {
                do { try await commit(hash, grant, earlier.flatMap { $0.id == grant.id ? nil : $0.id }) } catch {
                    return .failure(
                        RPCError(
                            code: RPCError.internalError,
                            message: "Agneta couldn't save \(name)'s access: \(error.localizedDescription)"))
                }
                guard !shutDown, apps[appID] != nil else {
                    return .failure(RPCError(code: RPCError.internalError, message: "The app disconnected"))
                }
            }
            // The earlier grant's tokens stop working (its saved row was replaced or removed with this one's saving), and
            // its usage goes on under the new one.
            if let earlier {
                tokens = tokens.filter { $0.value.id != earlier.id }
                if earlier.id != grant.id { recount(from: earlier.id, to: grant.id) }
            }
            tokens[hash] = grant
            if !answer.remember { onceTokens[appID] = hash }
            apps[appID]?.grant = grant // the live entry, not a copy from before the approval
            onEvent(
                .paired(tokenHash: hash, grant: grant, replaced: earlier.flatMap { $0.id == grant.id ? nil : $0.id }))
            // The app's other connections on the earlier grant: a renewed one's get what was just allowed (their
            // sessions outside it stop); a replaced one's are cut off like Remove Access.
            if let earlier {
                if earlier.id == grant.id { await apply(grant) } else { await revoke(grant: earlier.id) }
            }
            // `remembered`: keep the token (in the Keychain) to connect with next time; an Allow Once token ends with this
            // connection.
            return .success([
                "token": .string(token), "remembered": .bool(answer.remember), "access": access(grant),
                "unmet": .array(unmet(scope, grant: grant))
            ])
        }
        if method == "initialize" {
            guard let token = params?["_meta"]?["agneta"]?["token"]?.stringValue, let grant = tokens[Self.hash(token)]
            else {
                return .failure(Self.notPaired)
            }
            // "Allow Once" covers only the connection that paired.
            if !grant.remembered, onceTokens[appID] != Self.hash(token) { return .failure(Self.notPaired) }
            // A verified grant is still that app: the token alone, copied into another program, isn't enough.
            if grant.verified {
                let peer = port.flatMap { client in
                    serverPort.flatMap { PeerIdentity.forLoopbackPort(client, serverPort: $0) }
                }
                guard GrantScope.identityMatches(grant, peer) else {
                    return .failure(
                        RPCError(
                            code: -32001, message: "This connection isn't \(grant.app) as it was paired; pair again",
                            data: ["agneta": ["needsPairing": true]]))
                }
            }
            traces?.mask.register(token)
            app.grant = grant
            apps[appID] = app
            return .success(initializeResult(grant))
        }
        guard let grant = app.grant else { return .failure(Self.notPaired) }
        if method == "agneta/access" { return .success(access(grant)) }
        if method == "session/new" { return await newSession(appID, grant: grant, params: params) }
        if method == "agneta/trace/read" { return await readTrace(appID, grant: grant, params: params) }
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
            return .failure(
                RPCError(code: Self.turnBusy, message: "A turn is already running in this session; steer it or wait"))
        }
        // The result the prompt asks for (agneta/result), checked before it waits for room.
        var resultTurn: ResultTurn?
        if method == "session/prompt" {
            switch self.resultTurn(for: params, in: session) {
            case .success(let turn): resultTurn = turn
            case .failure(let refusal): return .failure(refusal)
            }
        }
        if method == "session/prompt" {
            if let refusal = pausedRefusal(session.account) { return .failure(refusal) }
            // Over its cost limit already (a resumed task, or one the last turn took past it): nothing more is spent.
            if let max = session.policy.limits.maxCostUSD, let cost = traces?.session(id)?.progress.taskCost, cost > max
            {
                return .success([
                    "sessionId": .string(id), "stopReason": "cancelled",
                    "_meta": ["agneta/limit": LimitHit(limit: "maxCostUSD", value: .double(max)).report]
                ])
            }
            // Over a limit the user set for the app: refused, as the user's choice (-32016). And on an engine a spending
            // limit set since the session opened can't count (Codex on an API key; `apply` stops those sessions too).
            if let refusal = uncountedRefusal(session.lease.engine.id, account: session.account, grant: grant)
                ?? appLimitRefusal(grant, account: session.account, newTask: .none)
            {
                return .failure(refusal)
            }
            do {
                guard try await admit(id, account: session.account, meter: session.meter) else {
                    return .success(["stopReason": "cancelled"])
                }
            } catch let error as RPCError {
                return .failure(error)
            } catch {
                return .failure(RPCError(code: RPCError.internalError, message: "\(error)"))
            }
            // It may have waited while the app spent its budget, or the user lowered it.
            if current(id, generation), let now = apps[appID]?.grant,
                let refusal = uncountedRefusal(session.lease.engine.id, account: session.account, grant: now)
                    ?? appLimitRefusal(now, account: session.account, newTask: .none)
            {
                runningTurns[id] = nil
                sessions[id]?.limitHit = nil
                admitWaiting()
                return .failure(refusal)
            }
            runningTurns[id]?.began = true
            sessions[id]?.limitHit = nil // a turn begins with no limit reached
            onEvent(.turnStarted(id))
            trace?.turnStarted(prompt: params?["prompt"])
            if let resultTurn { openResult(id, resultTurn, generation: generation) }
        }
        // A session that ended meanwhile already let its turn go; one reopened under this id has a turn of its own.
        defer { if method == "session/prompt", current(id, generation) { finishTurn(id) } }
        // A result the turn didn't report (it failed) is forgotten with it.
        defer { if method == "session/prompt" { discardResult(id, generation: generation) } }
        // Agneta's own methods, so apps never need an engine's names.
        var engineMethod = method
        var engineParams = params?.setting("sessionId", to: .string(session.engineSession))
        if method == "session/prompt", let resultTurn { engineParams = Self.asking(engineParams, for: resultTurn) }
        let engine = session.lease.engine
        // A mode the engine's adapter doesn't allow would leave the session outside what Agneta set up: on engines
        // that run their own tools, one that stops asking skips Agneta's permission checks; on OpenCode, another agent
        // drops Agneta's, with the session's instructions.
        if let mode = method == "session/set_mode"
            ? params?["modeId"]?.stringValue
            : (method == "session/set_config_option" && params?["configId"]?.stringValue == "mode"
                ? params?["value"]?.stringValue : nil),
            !engine.permitsMode(mode)
        {
            return .failure(
                RPCError(
                    code: RPCError.invalidParams,
                    message: "\(engine.displayName)'s \(mode) mode would leave what Agneta set up for this session",
                    data: ["agneta": ["unenforceable": ["mode"]]]))
        }
        switch method {
        case "agneta/instructions/set":
            guard let text = params?["text"]?.stringValue else {
                return .failure(RPCError(code: RPCError.invalidParams, message: "text is required"))
            }
            // "replace" sets the whole instructions; "append" adds a named part, which a later append with the same key replaces.
            let appendKey = params?["mode"]?.stringValue == "append" ? (params?["key"]?.stringValue ?? "app") : nil
            guard let request = engine.setInstructions(session.engineSession, text: text, appendKey: appendKey) else {
                return .failure(Self.unsupported(engine, "change instructions during a session"))
            }
            (engineMethod, engineParams) = (request.method, request.params)
        case "agneta/steer":
            guard engine.capabilities.steer else { return .failure(Self.unsupported(engine, "steer a running turn")) }
            guard runningTurns[id] != nil,
                let request = engine.steer(
                    session.engineSession, run: session.activeRun, prompt: params?["prompt"] ?? .array([]))
            else {
                let error = RPCError(code: Self.noTurnRunning, message: "No turn is running to steer")
                record(method, params: params, result: .failure(error), in: trace)
                return .failure(error)
            }
            (engineMethod, engineParams) = (request.method, request.params)
        default:
            break
        }
        let watchdog =
            method == "session/prompt"
            ? Task { [weak self] in await self?.watch(id, generation: generation, limits: session.policy.limits) } : nil
        defer { watchdog?.cancel() }
        let call = Task { try await session.lease.peer.request(engineMethod, engineParams) }
        if method == "session/prompt" { inFlight[id] = call }
        defer { if method == "session/prompt", inFlight[id] == call { inFlight[id] = nil } }
        do {
            var result = try await withTaskCancellationHandler {
                try await call.value
            } onCancel: {
                call.cancel()
            }
            if method == "session/prompt" {
                watchdog?.cancel()
                let wasCutOff = cutOff.remove(id) != nil
                if let hit = enforcedLimits.removeValue(forKey: id) {
                    let report = closeResult(id, generation: generation, stopReason: "cancelled", stopped: true)
                    return .success(Self.withResult(Self.enforced(hit, session: id), report))
                }
                if wasCutOff {
                    let report = closeResult(id, generation: generation, stopReason: "cancelled", stopped: true)
                    return .success(Self.withResult(["sessionId": .string(id), "stopReason": "cancelled"], report))
                }
                // The session may have ended (or been reopened) while the engine worked: the result goes back, but
                // the router's state and the record of turns belong to the session as it is now.
                guard current(id, generation) else {
                    let report = closeResult(
                        id, generation: generation, stopReason: result["stopReason"]?.stringValue ?? "end_turn",
                        stopped: true)
                    return .success(Self.withResult(result.setting("sessionId", to: .string(id)), report))
                }
                let limited = sessions[id]?.limitHit != nil
                if let hit = sessions[id]?.limitHit {
                    // ACP has a stop reason for too many model turns; time and cost stop as cancelled, with the reason beside it.
                    if hit.limit == "maxTurns" { result = result.setting("stopReason", to: "max_turn_requests") }
                    result = result.setting(
                        "_meta", to: (result["_meta"] ?? [:]).setting("agneta/limit", to: hit.report))
                    sessions[id]?.limitHit = nil
                }
                let reason = result["stopReason"]?.stringValue ?? "end_turn"
                result = Self.withResult(
                    result, closeResult(id, generation: generation, stopReason: reason, stopped: limited))
                sessions[id]?.activeRun = nil
                if let summary = await trace?.turnEnded(stopReason: reason, usage: result["usage"], cutOff: limited) {
                    noteTokens(id, summary)
                    result = result.setting(
                        "_meta",
                        to: (result["_meta"] ?? [:]).setting(
                            "agneta/usage", to: usage(summary, account: session.account, meter: session.meter)))
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
                result = [
                    "delivery": "accepted", "runId": (delivered.run ?? session.activeRun).map(JSONValue.string) ?? .null
                ]
            }
            record(method, params: params, result: .success(result), in: trace)
            return .success(result["sessionId"] == nil ? result : result.setting("sessionId", to: .string(id)))
        } catch let error as RPCError {
            var error = error
            let wasCutOff = method == "session/prompt" && cutOff.remove(id) != nil
            if method == "session/prompt", let hit = enforcedLimits.removeValue(forKey: id) {
                let report = closeResult(id, generation: generation, stopReason: "cancelled", stopped: true)
                return .success(Self.withResult(Self.enforced(hit, session: id), report))
            }
            if wasCutOff {
                let report = closeResult(id, generation: generation, stopReason: "cancelled", stopped: true)
                return .success(Self.withResult(["sessionId": .string(id), "stopReason": "cancelled"], report))
            }
            if method == "session/prompt", current(id, generation) {
                sessions[id]?.activeRun = nil
                sessions[id]?.limitHit = nil // a stale flag would mislabel the next turn
                if let limit = RateLimit.detect(error.message) {
                    error = await rateLimited(id, account: session.account, limit: limit, error: error)
                } else if Self.isAuthRequired(error) {
                    error = signInNeeded(error, account: session.account)
                }
                if let summary = await trace?.turnEnded(stopReason: "error", usage: nil, error: error.message) {
                    noteTokens(id, summary)
                }
                if current(id, generation) { onEvent(.turnEnded(id, stopReason: "error")) }
            }
            record(method, params: params, result: .failure(error), in: trace)
            return .failure(error)
        } catch {
            let wasCutOff = method == "session/prompt" && cutOff.remove(id) != nil
            if method == "session/prompt", let hit = enforcedLimits.removeValue(forKey: id) {
                let report = closeResult(id, generation: generation, stopReason: "cancelled", stopped: true)
                return .success(Self.withResult(Self.enforced(hit, session: id), report))
            }
            // Stopped by the user (or its account removed, or access narrowed): cancelled, as the protocol says.
            if wasCutOff {
                let report = closeResult(id, generation: generation, stopReason: "cancelled", stopped: true)
                return .success(Self.withResult(["sessionId": .string(id), "stopReason": "cancelled"], report))
            }
            if method == "session/prompt", current(id, generation) {
                sessions[id]?.activeRun = nil
                sessions[id]?.limitHit = nil
                if let summary = await trace?.turnEnded(stopReason: "error", usage: nil, error: "The engine stopped") {
                    noteTokens(id, summary)
                }
                if current(id, generation) { onEvent(.turnEnded(id, stopReason: "error")) }
            }
            return .failure(RPCError(code: RPCError.internalError, message: "The engine stopped"))
        }
    }

    /// The turn's tokens, from its summary, for its app's meter when the turn leaves the room.
    func noteTokens(_ id: String, _ summary: [String: JSONValue]) {
        let ledger = summary["ledger"]
        runningTurns[id]?.tokens = (Int(ledger?["input"]?.intValue ?? 0), Int(ledger?["output"]?.intValue ?? 0))
        runningTurns[id]?.modelCalls = Int(summary["modelCalls"]?.intValue ?? 0)
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
        } else if method.hasPrefix("session/set_") || method.contains("system-prompt")
            || method.hasPrefix("agneta/instructions")
        {
            var fields: [String: JSONValue] = ["method": .string(method), "request": .object(request), "by": "app"]
            if case .failure(let error) = result { fields["error"] = .string(error.message) }
            trace.writer.record("config", fields)
        }
    }

    /// An engine's "sign in first" (ACP's auth_required, -32000, or its words): the user must act in Agneta.
    static func isAuthRequired(_ error: RPCError) -> Bool {
        error.code == -32000
            || error.message.range(
                of: "auth(entication)? required|not (signed|logged) in|please (log|sign) in",
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Says so to Agneta's UI and puts it in the app's error data, so the app can ask the user to open Agneta.
    func signInNeeded(_ error: RPCError, account: String) -> RPCError {
        onEvent(.needsSignIn(account: account))
        if needsSignIn.insert(account).inserted { accessChanged() }
        let data = (error.data?.objectValue != nil ? error.data! : [:]).setting(
            "agneta", to: ["needsSignIn": .string(account)])
        return RPCError(
            code: error.code,
            message: "\(accounts[account]?.label ?? "This account") needs you to sign in again in Agneta", data: data)
    }

    /// Runs `work` for at most `seconds`: a stuck engine mustn't hold up Stop, a disconnect or Remove Access
    ///. Ending the session afterwards releases (and stops) a dedicated engine regardless.
    /// Returns at the deadline whatever `work` is doing. Not a task group: a group waits for every child before
    /// it returns, and a request to an engine that never answers ignores cancellation, so the bound never ended.
    /// Unfinished work goes on in the background until the engine answers or its connection closes.
    static func bounded(seconds: Double = 5, _ work: @escaping @Sendable () async -> Void) async {
        let once = OnceFlag()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await work(); if once.take() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds)); if once.take() { continuation.resume() }
            }
        }
    }

    static let noTurnRunning: Int64 = -32010
    static let turnBusy: Int64 = -32011
    static let engineCantDoThat: Int64 = -32014

    /// A feature this session's engine doesn't have: said plainly, never a silent no-op.
    static func unsupported(_ engine: any EngineAdapter, _ what: String) -> RPCError {
        RPCError(
            code: engineCantDoThat, message: "\(engine.displayName) can't \(what)",
            data: ["agneta": ["engine": .string(engine.id)]])
    }

    /// What a session can do beyond plain ACP, so the app can offer it (SessionCapabilities).
    static func capabilities(_ engine: any EngineAdapter) -> JSONValue {
        (try? JSONCoding.decode(JSONCoding.encode(SessionCapabilities(engine)))) ?? [:]
    }

    /// `_meta.agneta.appTools` in a session's reply: the `load` it runs with, and whether the app's tools are in the
    /// model's first request on this engine (`upfront`, null when not known).
    static func appTools(_ policy: SessionPolicy, engine: any EngineAdapter, kind: AccountKind?) -> JSONValue {
        [
            "load": .string(policy.appTools.rawValue),
            "upfront": engine.appToolsUpfront(policy, kind: kind).map(JSONValue.bool) ?? .null
        ]
    }

    /// `_meta.agneta.builtins` in a session's reply: the groups of the engine's own tools the session has, as its engine
    /// is configured (null when Agneta doesn't know: Goose on a Claude plan).
    /// A shared engine (`dedicated` false) has no broker, so no shell: it's reported as the same policy without
    /// `execute`, which also drops `read` where an engine reads only through its shell (Goose, Codex).
    static func builtins(_ policy: SessionPolicy, engine: any EngineAdapter, kind: AccountKind?, dedicated: Bool)
        -> JSONValue
    {
        var policy = policy
        if !dedicated { policy.builtins = (policy.builtins ?? Set(BuiltinGroup.allCases)).subtracting([.execute]) }
        guard let groups = engine.builtinGroups(policy, kind: kind) else { return .null }
        return .array(groups.sorted().map { .string($0.rawValue) })
    }

    /// `agneta/trace/read`: a page of one of this app's own tasks, running or finished.
    func readTrace(_ appID: UUID, grant: Grant, params: JSONValue?) async -> Result<JSONValue, RPCError> {
        guard let traces else { return .failure(RPCError(code: RPCError.methodNotFound, message: "Traces are off")) }
        guard let task = params?["sessionId"]?.stringValue, !task.contains("/"), !task.contains("..")
        else {
            return .failure(RPCError(code: RPCError.invalidParams, message: "Unknown session"))
        }
        let types = params?["types"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) } ?? Traces.defaultTypes
        let limit = min(max(Int(params?["limit"]?.intValue ?? 500), 1), 5_000)
        // Read off the router: a page is file work, and the router serves every app.
        let after = params?["after"]?.intValue ?? 0
        guard
            let page = await Task.detached(
                priority: .utility,
                operation: { () -> (records: [JSONValue], next: Int64?, complete: Bool)? in
                    guard traces.meta(task: task)?["app"]?["grant"]?.stringValue == grant.id else { return nil }
                    return traces.read(task: task, after: after, types: types, limit: limit)
                }
            ).value, apps[appID]?.grant?.id == grant.id
        else {
            return .failure(RPCError(code: RPCError.invalidParams, message: "Unknown session"))
        }
        return .success([
            "records": .array(page.records), "next": page.next.map(JSONValue.int) ?? .null,
            "complete": .bool(page.complete)
        ])
    }

    func appNotification(_ appID: UUID, method: String, params: JSONValue?) async {
        guard Self.sessionNotifications.contains(method), let id = params?["sessionId"]?.stringValue,
            let session = sessions[id], session.app == appID
        else { return }
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
                "sessionCapabilities": ["close": [:]]
            ],
            "authMethods": [],
            "agentInfo": ["name": "agneta", "title": "Agneta", "version": .string(Router.version)],
            "_meta": [
                "agneta": [
                    "extensions": .array(Self.extensions.map(JSONValue.string)),
                    "access": access(grant)
                ]
            ]
        ]
    }

    /// Agneta's version, in `initialize` and every trace's `meta`: the app's, or "dev" outside one.
    public static let version =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    /// Agneta's additions to ACP, listed in `initialize` (docs/APP_PROTOCOL.md).
    static let extensions = [
        SessionPolicy.key, "agneta/access", "agneta/catalog", "agneta/setup", "agneta/task", "agneta/instructions",
        "agneta/steer", "agneta/usage",
        "agneta/trace", "agneta/limit", "agneta/queue", "agneta/rateLimited", "agneta/fork", "agneta/appLimits",
        AppToolsLoad.key
    ]

    static func newToken() -> String { SecureRandom.token() }
}
