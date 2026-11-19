// The engine side of the router: wiring each engine's connection once, routing its notifications and requests
// back to the session's app, and deciding permission requests from the session's policy.
import Foundation

extension Router {
    func key(_ lease: String, _ engineSession: String) -> String { lease + "\u{0}" + engineSession }

    /// Routes an engine's notifications and requests back to the owning app. The engine's connection
    /// takes the handlers once, in one step: a restarted engine is a new connection, and no second caller
    /// can find it half wired.
    func wire(_ lease: EngineLease) async {
        let leaseKey = lease.key, peer = lease.peer
        await peer.route(
            tap: traces?.engineAttributor(lease: leaseKey).frame,
            requests: { [weak self] method, params in
                guard let self else {
                    return .failure(RPCError(code: RPCError.internalError, message: "Agneta is stopping"))
                }
                return await self.engineRequest(lease: leaseKey, method: method, params: params)
            },
            notifications: { [weak self] method, params in
                await self?.fromEngine(lease: leaseKey, method: method, params: params)
            },
            closed: { [weak self] reason in
                Task { await self?.engineGone(peer, reason: reason) }
            })
    }

    /// An engine's connection closed. When Agneta closed it (the session ended, Agneta is stopping) its sessions
    /// are already gone; otherwise the engine died, and its sessions end now rather than failing every prompt.
    func engineGone(_ peer: RPCPeer, reason: String) async {
        for (id, session) in sessions where session.lease.peer === peer {
            traces?.session(id)?.writer.record(
                "lifecycle", ["event": "stop", "by": "engine", "reason": .string(reason)])
            if let app = apps[session.app] {
                let appPeer = app.peer
                Task {
                    try? await appPeer.notify(
                        "agneta/sessionStopped", ["sessionId": .string(id), "stoppedBy": "engine"])
                }
            }
            await end(id, .engineStopped)
        }
    }

    func fromEngine(lease: String, method: String, params: JSONValue?) async {
        if let engineSession = params?["sessionId"]?.stringValue, byEngine[key(lease, engineSession)] == nil,
            openingOn[lease] != nil
        {
            // About a session this lease is still opening: held until it's registered (a few at most).
            if early[key(lease, engineSession), default: []].count < 256 {
                early[key(lease, engineSession), default: []].append((method, params))
            }
            return
        }
        guard let engineSession = params?["sessionId"]?.stringValue, let id = byEngine[key(lease, engineSession)],
            let session = sessions[id], let app = apps[session.app]
        else { return }
        if let update = params?["update"], update["sessionUpdate"]?.stringValue == "usage_update" {
            let cost: Double? =
                switch update["cost"]?["amount"] {
                case .double(let v)?: v;
                case .int(let v)?: Double(v);
                default: nil
                }
            onEvent(.usage(id, used: update["used"]?.intValue.map(Int.init), cost: cost))
        }
        if let call = session.lease.engine.modelCall(fromNotification: method, params: params) {
            traces?.session(id)?.ingest(modelCall: call)
        }
        if method == "session/update", let update = params?["update"] {
            traces?.session(id)?.update(update)
            if let run = session.lease.engine.activeRun(in: update) { sessions[id]?.activeRun = run }
            if let call = update["toolCallId"]?.stringValue {
                if ["completed", "failed"].contains(update["status"]?.stringValue ?? "") {
                    sessions[id]?.toolServers[call] = nil
                    sessions[id]?.toolNames[call] = nil
                } else {
                    let identity = session.lease.engine.toolIdentity(in: update)
                    if let server = identity.server {
                        sessions[id]?.toolServers[call] = server
                    }
                    // A built-in's permission request carries only its title and kind: its name comes from here.
                    else if let tool = identity.tool {
                        sessions[id]?.toolNames[call] = tool
                    }
                }
            }
        }
        try? await app.peer.notify(method, params?.setting("sessionId", to: .string(id)))
    }

    func engineRequest(lease: String, method: String, params: JSONValue?) async -> Result<JSONValue, RPCError> {
        let started = ContinuousClock.now
        let (result, decision) = await decide(lease: lease, method: method, params: params)
        if method == "session/request_permission", let engineSession = params?["sessionId"]?.stringValue,
            let id = byEngine[key(lease, engineSession)], let trace = traces?.session(id)
        {
            let elapsed = ContinuousClock.now - started
            var fields: [String: JSONValue] = [
                "engineCall": params?["toolCall"]?["toolCallId"] ?? .null,
                "toolKind": params?["toolCall"]?["kind"] ?? .null,
                "title": params?["toolCall"]?["title"] ?? .null, "decision": .string(decision),
                "ms": .double(
                    ((Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15) * 10)
                        .rounded() / 10)
            ]
            switch result {
            case .success(let answer): fields["answer"] = answer["outcome"] ?? .null
            case .failure(let error): fields["error"] = .string(error.message)
            }
            trace.writer.record("permission", fields)
        }
        return result
    }

    /// The answer to an engine's request, and for permission requests who decided it.
    func decide(lease: String, method: String, params: JSONValue?) async -> (Result<JSONValue, RPCError>, String) {
        guard let engineSession = params?["sessionId"]?.stringValue, let id = byEngine[key(lease, engineSession)],
            let session = sessions[id], let app = apps[session.app]
        else {
            return (.failure(RPCError(code: RPCError.invalidParams, message: "Unknown session")), "unknown-session")
        }
        if method == "session/request_permission",
            runner(account: session.account, engine: session.lease.engine) == .native,
            !Self.isAppTool(params, in: session), !Self.isAgnetaShell(params, in: session),
            !BuiltinTools.nativeRunnerMayUse(
                kind: params?["toolCall"]?["kind"]?.stringValue,
                tool: params?["toolCall"]?["toolCallId"]?.stringValue.flatMap { session.toolNames[$0] },
                policy: session.policy, brokered: session.lease.engine.brokersShell(session.policy))
        {
            // Claude Code and Codex run their own tools inside the engine sandbox, which allows port 443:
            // refuse what the policy forbids before it runs.
            let options = params?["options"]?.arrayValue ?? []
            if let reject = options.first(where: { $0["kind"]?.stringValue == "reject_once" }) {
                return (
                    .success(["outcome": ["outcome": "selected", "optionId": reject["optionId"] ?? .null]]),
                    "refused-by-policy"
                )
            }
            return (.success(["outcome": ["outcome": "cancelled"]]), "refused-by-policy")
        }
        if method == "session/request_permission", session.policy.approval == .neverAsk {
            // The policy is the permission: tools are already limited by extension and sandbox.
            let options = params?["options"]?.arrayValue ?? []
            guard let allow = options.first(where: { $0["kind"]?.stringValue == "allow_once" }) else {
                return (.success(["outcome": ["outcome": "cancelled"]]), "cancelled")
            }
            return (
                .success(["outcome": ["outcome": "selected", "optionId": allow["optionId"] ?? .null]]),
                "allowed-by-policy"
            )
        }
        do {
            var answer = try await app.peer.request(method, params?.setting("sessionId", to: .string(id)))
            if method == "session/request_permission" {
                answer = Self.onlyOnce(answer, options: params?["options"]?.arrayValue ?? [])
            }
            return (.success(answer), "asked-app")
        } catch let error as RPCError {
            return (.failure(error), "asked-app")
        } catch {
            return (.failure(RPCError(code: RPCError.internalError, message: "The app didn't answer")), "asked-app")
        }
    }

    /// A permission covers this one call: an app's "always" answer becomes "once" (and "reject always"
    /// becomes "reject once"), since an engine may keep "always" beyond the session (OpenCode keeps it
    /// for the whole project).
    static func onlyOnce(_ answer: JSONValue, options: [JSONValue]) -> JSONValue {
        guard let chosen = answer["outcome"]?["optionId"]?.stringValue,
            let kind = options.first(where: { $0["optionId"]?.stringValue == chosen })?["kind"]?.stringValue,
            kind == "allow_always" || kind == "reject_always"
        else { return answer }
        let replacement = kind == "allow_always" ? "allow_once" : "reject_once"
        // With no once-option, "always" can't be narrowed: the call is declined rather than allowed for good.
        guard let once = options.first(where: { $0["kind"]?.stringValue == replacement })?["optionId"] else {
            if let reject = options.first(where: { $0["kind"]?.stringValue == "reject_once" })?["optionId"] {
                return answer.setting("outcome", to: ["outcome": "selected", "optionId": reject])
            }
            return answer.setting("outcome", to: ["outcome": "cancelled"])
        }
        return answer.setting("outcome", to: ["outcome": "selected", "optionId": once])
    }

    /// A session is being opened on this lease: what the engine says about sessions it doesn't know yet is held.
    func beginOpening(_ lease: String) { openingOn[lease, default: 0] += 1 }

    /// The opening ended, registered or not: what's held for a session that never got registered is dropped.
    func endOpening(_ lease: String) {
        openingOn[lease, default: 1] -= 1
        guard openingOn[lease, default: 0] <= 0 else { return }
        openingOn[lease] = nil
        early = early.filter { !$0.key.hasPrefix(lease + "\u{0}") }
    }

    /// Delivers what the engine said about a session before it was registered, now that it is, in order.
    func deliverEarly(_ lease: EngineLease, _ engineSession: String) async {
        for (method, params) in early.removeValue(forKey: key(lease.key, engineSession)) ?? [] {
            await fromEngine(lease: lease.key, method: method, params: params)
        }
    }

    /// Whether a permission request is for one of the app's own MCP tools (Codex asks for those as `execute`).
    /// Only the servers the app named count: an engine's own MCP servers (claude-agent-acp's `mcp__acp__bash`)
    /// are built-ins.
    /// A call to Agneta's own shell server (Codex's commands on the contained path), which runs each command through
    /// the broker under the session's tool profile: the policy, not the engine's sandbox, confines it.
    static func isAgnetaShell(_ params: JSONValue?, in session: Session) -> Bool {
        guard session.lease.engine.brokersShell(session.policy),
            let server = session.lease.engine.permissionServer(params, calls: session.toolServers)
        else { return false }
        return server == CodexAdapter.shellServer && !session.appServers.contains(server)
    }

    static func isAppTool(_ params: JSONValue?, in session: Session) -> Bool {
        guard let server = session.lease.engine.permissionServer(params, calls: session.toolServers) else {
            return false
        }
        return session.appServers.contains(server) && !session.lease.engine.reservedToolServers.contains(server)
    }
}
