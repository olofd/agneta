// Structured results in the router (docs/APP_PROTOCOL.md, Structured results): a session that declares results gets a
// route on Agneta's result server before its engine starts; a prompt that asks for one opens a ResultTurn, notes on
// the prompt which tool to call, and answers the app with the outcome. Every decision is ResultTurn's; this file only
// feeds it events and carries its answers. A session that declares nothing never reaches any of it.
import Foundation

extension Router: ResultSessions {
    /// Agneta's result server, made on first use (it starts listening only when a session registers).
    func results() -> ResultServer {
        if let resultServer { return resultServer }
        let server = ResultServer(sessions: self)
        resultServer = server
        return server
    }

    /// Gives a plan that declares results its route, under the id the session will have. Before the engine starts:
    /// engines take their MCP servers at launch or with `session/new`.
    func routeResults(_ plan: inout Plan, session id: String) async -> RPCError? {
        guard let declaration = plan.results else { return nil }
        do {
            let route = try await results().register(session: id)
            plan.resultRoute = route
            // Engines list a server's tools while the session is still opening, before it's registered: its tools are
            // answerable from now on.
            resultRoutes[id] = (route.id, declaration)
            // The bearer reaches the engine in the session's ACP frames: never in a trace.
            traces?.mask.register(route.bearer)
            traces?.mask.register("Bearer " + route.bearer)
            return nil
        } catch {
            return RPCError(
                code: RPCError.internalError, message: "Agneta couldn't start its result server: \(error)")
        }
    }

    /// Ends a session's route (it closed, or never opened).
    func dropResults(_ id: String) {
        resultRoutes[id] = nil
        guard let resultServer else { return }
        Task { await resultServer.unregister(session: id) }
    }

    // MARK: A turn

    /// The result a prompt asks for, or nil; refused (`-32602`) when the ask doesn't fit the session's declaration.
    func resultTurn(for params: JSONValue?, in session: Session) -> Result<ResultTurn?, RPCError> {
        do {
            guard
                let request = try ResultRequest.parse(
                    params?["_meta"]?[ResultDeclaration.key], declaration: session.results)
            else { return .success(nil) }
            return .success(session.results?.turn(for: request))
        } catch {
            return .failure(error.rpcError)
        }
    }

    /// The turn begins: its result is open for submissions.
    func openResult(_ id: String, _ turn: ResultTurn, generation: UUID) {
        resultTurns[id] = (generation, turn)
        traces?.session(id)?.writer.record(
            "result",
            [
                "event": "asked", "name": .string(turn.request.name), "tool": .string(turn.tool),
                "attempts": .int(Int64(turn.request.attempts))
            ])
    }

    /// The prompt as the engine gets it: the note saying which tool to call added, and Agneta's own field taken out.
    static func asking(_ params: JSONValue?, for turn: ResultTurn) -> JSONValue? {
        guard var fields = params?.objectValue else { return params }
        var prompt = fields["prompt"]?.arrayValue ?? []
        prompt.append(["type": "text", "text": .string(ResultWording.note(tool: turn.tool))])
        fields["prompt"] = .array(prompt)
        if var meta = fields["_meta"]?.objectValue {
            meta[ResultDeclaration.key] = nil
            fields["_meta"] = meta.isEmpty ? nil : .object(meta)
        }
        return .object(fields)
    }

    /// The turn ended: its outcome, taken out of the router (a late call finds nothing open), as the reply's
    /// `_meta["agneta/result"]`. Nil when the turn asked for no result.
    func closeResult(_ id: String, generation: UUID, stopReason: String, stopped: Bool) -> JSONValue? {
        guard var open = resultTurns[id], open.generation == generation else { return nil }
        resultTurns[id] = nil
        let outcome = open.turn.end(stopReason: stopReason, stopped: stopped)
        let report = Self.report(outcome, turn: open.turn)
        traces?.session(id)?.writer.record(
            "result", ["event": "final", "name": .string(open.turn.request.name), "report": Self.traced(report)])
        return report
    }

    /// Forgets a turn's result without an outcome (the prompt failed with an error).
    func discardResult(_ id: String, generation: UUID) {
        if resultTurns[id]?.generation == generation { resultTurns[id] = nil }
    }

    /// The reply with the result in its `_meta`.
    static func withResult(_ reply: JSONValue, _ report: JSONValue?) -> JSONValue {
        guard let report else { return reply }
        return reply.setting("_meta", to: (reply["_meta"] ?? [:]).setting(ResultDeclaration.key, to: report))
    }

    /// `_meta["agneta/result"]` on a prompt's reply.
    static func report(_ outcome: ResultOutcome, turn: ResultTurn) -> JSONValue {
        var fields: [String: JSONValue] = [
            "status": .string(outcome.status), "name": .string(turn.request.name), "mechanism": "tool",
            "attempts": .int(Int64(turn.submissions))
        ]
        switch outcome {
        case .valid(let value): fields["value"] = value
        case .invalid(let value, let issues):
            fields["value"] = value
            fields["issues"] = .array(issues.map(Self.issue))
        case .missing(let reason, let last):
            fields["reason"] = .string(reason.rawValue)
            // The last value refused before the turn ended, as detail: what the model got wrong before it was cut off.
            if let last {
                fields["value"] = last.value
                fields["issues"] = .array(last.issues.map(Self.issue))
            }
        }
        return .object(fields)
    }

    /// An issue for the app, its texts cut to a bound (a value's own keys are in its path).
    static func issue(_ issue: ResultIssue) -> JSONValue {
        [
            "path": .string(ResultWording.cut(issue.path, to: 1_000)), "keyword": .string(issue.keyword),
            "message": .string(ResultWording.cut(issue.message, to: 1_000)),
            "schemaPath": .string(ResultWording.cut(issue.schemaPath, to: 1_000))
        ]
    }

    /// A value in the trace, unless it's large: then only its size.
    static func traced(_ value: JSONValue) -> JSONValue {
        let size = (try? JSONCoding.encode(value).count) ?? 0
        return size <= 16_384 ? value : ["omitted": true, "bytes": .int(Int64(size))]
    }

    // MARK: ResultSessions (the result server's calls)

    public func resultTools(session id: String, route: String) async -> [JSONValue]? {
        guard let routed = resultRoutes[id], routed.route == route else { return nil }
        return ResultServer.tools(routed.declaration)
    }

    public func submitResult(session id: String, route: String, tool: String, arguments: JSONValue) async -> (
        text: String, isError: Bool
    ) {
        // The session as it is now, through the route it has now: a call from before a reload is too late.
        guard let session = sessions[id], let declaration = session.results, resultRoutes[id]?.route == route else {
            return ("This task has ended or was reopened; nothing can be submitted here.", true)
        }
        let trace = traces?.session(id)
        guard declaration.name(forTool: tool) != nil else {
            return ("There's no tool \(tool) here.", true)
        }
        guard var open = resultTurns[id], open.generation == session.generation else {
            trace?.writer.record("result", ["event": "not-asked", "tool": .string(tool)])
            return (ResultWording.notAsked, true)
        }
        // Counted on the actor, checked off it (on a large stack, without holding up the router), recorded on it
        // again, against the same turn: one that ended meanwhile is told so.
        let answer: ResultTurn.Answer
        switch open.turn.reserve(tool: tool) {
        case .answered(let early):
            answer = early
            resultTurns[id] = open
        case .check(let ticket):
            resultTurns[id] = open
            let issues = await open.turn.schema.checked(arguments)
            guard var now = resultTurns[id], now.generation == open.generation, now.turn.id == open.turn.id else {
                trace?.writer.record("result", ["event": "too-late", "tool": .string(tool)])
                return ResultWording.answer(.notAsked, tool: open.turn.tool, schema: open.turn.schema)
            }
            answer = now.turn.complete(ticket, value: arguments, issues: issues)
            resultTurns[id] = now
            open = now
        }
        var fields: [String: JSONValue] = [
            "event": "submitted", "tool": .string(tool), "attempt": .int(Int64(open.turn.submissions)),
            "value": Self.traced(arguments)
        ]
        switch answer {
        case .accepted: fields["answer"] = "accepted"
        case .refused(let issues, _), .exhausted(let issues):
            fields["answer"] = "refused"
            fields["issues"] = .array(issues.map(Self.issue))
        case .alreadyReceived: fields["answer"] = "already-received"
        case .wrongTool: fields["answer"] = "wrong-tool"
        case .noAttemptsLeft: fields["answer"] = "no-attempts-left"
        case .notAsked: fields["answer"] = "not-asked"
        }
        trace?.writer.record("result", fields)
        return ResultWording.answer(answer, tool: open.turn.tool, schema: open.turn.schema)
    }

    // MARK: Permissions and updates

    /// Whether a permission request is for Agneta's own result tool: it runs nothing, so Agneta allows it itself.
    static func isResultTool(_ params: JSONValue?, in session: Session) -> Bool {
        session.results != nil
            && session.lease.engine.permissionServer(params, calls: session.toolServers) == ResultServer.name
    }

    /// A result tool's call, tagged for the app (`_meta.agneta.result`) so it can tell it from the model's work: every
    /// update of the call, its last one included. `session` is the session as it was before this update.
    func tagResultCall(_ id: String, _ params: JSONValue?, session: Session) -> JSONValue? {
        guard session.results != nil, let update = params?["update"], let call = update["toolCallId"]?.stringValue
        else { return params }
        let identity = session.lease.engine.toolIdentity(in: update)
        let known = session.resultCalls[call]
        guard known != nil || (identity.server ?? session.toolServers[call]) == ResultServer.name else { return params }
        let name = known ?? identity.tool.flatMap { session.results?.name(forTool: $0) }
        if ["completed", "failed"].contains(update["status"]?.stringValue ?? "") {
            sessions[id]?.resultCalls[call] = nil
        } else if let name {
            sessions[id]?.resultCalls[call] = name
        }
        let meta = (update["_meta"] ?? [:]).setting(
            "agneta",
            to: (update["_meta"]?["agneta"] ?? [:]).setting("result", to: ["name": name.map(JSONValue.string) ?? .null])
        )
        return params?.setting("update", to: update.setting("_meta", to: meta))
    }
}
