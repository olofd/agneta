// Turns: the queue that keeps every account and every app within its concurrency (one account's or app's turns never
// hold up another's), the watchdog that enforces a policy's limits and the app's spending limit while a turn runs,
// and what a turn's end reports.
import Foundation

extension Router {
    // MARK: Turn queue

    func hasRoom(for account: String) -> Bool {
        runningTurns.count < concurrency.global && runningTurns.values.count { $0.account == account } < concurrency.perAccount
    }

    /// Room for a turn of this app on this account: Agneta's, the account's, and the app's own "at once" (AppLimits).
    func hasRoom(for account: String, meter: String) -> Bool {
        hasRoom(for: account) && (limits(meter: meter).atOnce.map { running(meter: meter) < $0 } ?? true)
    }

    /// Whether the app's "at once" is full.
    func appFull(_ meter: String) -> Bool { limits(meter: meter).atOnce.map { running(meter: meter) >= $0 } ?? false }

    /// Whether the waiter at `index` is held by its own app: its "at once" is full. (An app's turns held by its limit
    /// go in order, and an earlier one held so is held for the same reason, so this is the whole rule; it's checked for
    /// every waiter on every admission, so it must stay this cheap.) One held so doesn't hold up other apps' turns on
    /// its account; one waiting for a full account doesn't hold up the app's turns elsewhere.
    func heldByApp(_ index: Int) -> Bool { appFull(waiting[index].meter) }

    /// Whether a turn wanting this room waits behind the waiter at `index`: one of its own app held by the app's limit,
    /// or one on its account that isn't.
    func waitsBehind(_ index: Int, account: String, meter: String) -> Bool {
        let held = heldByApp(index)
        return (waiting[index].meter == meter && held) || (waiting[index].account == account && !held)
    }

    /// What a turn waits for, from what holds it: its app's "at once", its account, or Agneta's room.
    func waitingFor(account: String, meter: String) -> String {
        if appFull(meter) { return "app" }
        if runningTurns.values.count(where: { $0.account == account }) >= concurrency.perAccount { return "account" }
        return runningTurns.count >= concurrency.global ? "agneta" : "account"
    }

    /// Takes a place in the room for a turn, noting what its task had cost so far.
    func start(_ id: String, account: String, meter: String) {
        runningTurns[id] = RunningTurn(account: account, meter: meter, counted: countsSpend(account),
                                       costAtStart: traces?.session(id)?.progress.taskCost ?? 0)
    }

    /// Waits for room to run a turn. Returns false if the wait was cancelled; throws when the queue is full, or the
    /// account was paused while the turn waited.
    func admit(_ id: String, account: String, meter: String) async throws -> Bool {
        // Waits only behind earlier turns that want the same room: on the same account (unless held by their own app's
        // limit), or of the same app held by its limit. One account's or one app's limits never hold up another's.
        if hasRoom(for: account, meter: meter) && !waiting.indices.contains(where: { waitsBehind($0, account: account, meter: meter) }) {
            start(id, account: account, meter: meter)
            return true
        }
        guard waiting.count < concurrency.queue else {
            throw RPCError(code: Self.queueFull, message: "Too many AI tasks are waiting; try again shortly")
        }
        let position = waiting.count + 1
        let reason = waitingFor(account: account, meter: meter)
        traces?.session(id)?.writer.record("lifecycle", ["event": "queued", "position": .int(Int64(position)),
                                                         "running": .int(Int64(runningTurns.count)), "waitingFor": .string(reason)])
        let peer = sessions[id].flatMap { apps[$0.app]?.peer }
        let started = ContinuousClock.now
        // Joins the queue before anything can suspend, so a turn finishing or a cancel arriving meanwhile
        // finds it (announcing first could lose the wakeup and stall the account's queue).
        let admission = await withCheckedContinuation { continuation in
            waiting.append(Waiter(session: id, account: account, meter: meter, resume: continuation))
            if let peer {
                Task { try? await peer.notify("agneta/queued", ["sessionId": .string(id), "position": .int(Int64(position)), "waitingFor": .string(reason)]) }
            }
        }
        let waited = ContinuousClock.now - started
        let event: JSONValue = switch admission { case .admitted: "dequeued"; case .cancelled: "queue-cancelled"; case .paused: "queue-paused" }
        traces?.session(id)?.writer.record("lifecycle", ["event": event,
                                                         "ms": .double(Double(waited.components.seconds) * 1000 + Double(waited.components.attoseconds) / 1e15)])
        if admission == .paused { throw pausedError(account) }
        return admission == .admitted
    }

    /// A turn ended: its usage joins its app's meter, and waiting turns may run.
    func finishTurn(_ id: String) {
        guard let turn = runningTurns.removeValue(forKey: id) else { return }
        meterTurn(id, turn)
        admitWaiting()
    }

    /// Lets waiting turns run, oldest first, wherever their account and app have room (after a turn ends, or the user
    /// raised an app's "at once").
    func admitWaiting() {
        var index = 0
        while index < waiting.count {
            let waiter = waiting[index]
            // Room for its account and its app; in order, so an app's turns held by its limit run oldest first.
            if hasRoom(for: waiter.account, meter: waiter.meter) {
                waiting.remove(at: index)
                start(waiter.session, account: waiter.account, meter: waiter.meter)
                waiter.resume.resume(returning: .admitted)
            } else {
                index += 1
            }
        }
    }

    /// Cancels a turn still waiting in the queue. Returns true if there was one.
    func cancelWaiting(_ id: String) -> Bool {
        guard let index = waiting.firstIndex(where: { $0.session == id }) else { return false }
        waiting.remove(at: index).resume.resume(returning: .cancelled)
        // Turns it held back may run now.
        admitWaiting()
        return true
    }

    static let queueFull: Int64 = -32012


    // MARK: Limits and usage

    /// A provider's limit ended the turn: say so in the trace, to the app (`agneta/rateLimited` and
    /// structured error data) and to Agneta's UI, with the reset time when the provider gave one.
    func rateLimited(_ id: String, account: String, limit: RateLimit, error: RPCError) async -> RPCError {
        let resets: JSONValue = limit.resetsAt.map { .string(TraceWriter.timestamp($0)) } ?? .null
        let details: JSONValue = ["account": .string(account), "message": .string(limit.message), "resetsAt": resets]
        traces?.session(id)?.writer.record("event", ["kind": "rate-limited", "account": .string(account), "message": .string(limit.message), "resetsAt": resets])
        if let session = sessions[id], let app = apps[session.app] {
            try? await app.peer.notify("agneta/rateLimited", details.setting("sessionId", to: .string(id)))
        }
        onEvent(.rateLimited(account: account, resetsAt: limit.resetsAt, message: limit.message))
        let data = (error.data?.objectValue != nil ? error.data! : [:]).setting("agneta", to: ["rateLimited": details])
        return RPCError(code: error.code, message: error.message, data: data)
    }

    /// Enforces the policy's limits on a running prompt, and the spending limit the user set for its app: checks twice
    /// a second and cancels the turn at the first limit passed, recording which. The policy's come first, so a turn
    /// past both reports its own. The app's spending limit, once reached, stops every turn of the app it counts.
    func watch(_ id: String, generation: UUID, limits: SessionPolicy.Limits) async {
        let started = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let session = sessions[id], session.generation == generation else { return }
            let elapsed = ContinuousClock.now - started
            let progress = traces?.session(id)?.progress ?? (turnModelCalls: 0, taskCost: 0)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let policy = limits.breached(seconds: seconds, modelCalls: progress.turnModelCalls, cost: progress.taskCost).map { LimitHit(limit: $0.limit, value: $0.value) }
            guard let hit = policy ?? appSpendHit(id) else { continue }
            sessions[id]?.limitHit = hit
            traces?.session(id)?.writer.record("lifecycle", ["event": "limit", "limit": .string(hit.limit), "value": hit.value, "setBy": .string(hit.setBy)])
            // Sent on its own: an engine that isn't reading can hold the write, and the grace runs regardless.
            let peer = session.lease.peer, engineSession = JSONValue.string(session.engineSession)
            Task { try? await peer.notify("session/cancel", ["sessionId": engineSession]) }
            // A limit is a hard limit: an engine that hasn't stopped within the grace (stuck in a tool, not reading,
            // or ignoring the cancel) gets its session ended, which stops a dedicated engine, and the prompt is
            // answered as stopped by the limit.
            try? await Task.sleep(for: concurrency.limitGrace)
            guard !Task.isCancelled, let still = sessions[id], still.generation == generation, still.limitHit != nil else { return }
            traces?.session(id)?.writer.record("lifecycle", ["event": "limit-enforced", "limit": .string(hit.limit)])
            enforcedLimits[id] = hit
            await Self.closeOnEngine(still)
            // The wait may have let the turn finish, or the session close and reopen under its id: nothing to end then.
            guard sessions[id]?.generation == generation else { return }
            if let app = apps[still.app] {
                let peer = app.peer
                Task { try? await peer.notify("agneta/sessionStopped", ["sessionId": .string(id), "stoppedBy": "limit"]) }
            }
            let call = inFlight[id]
            await end(id, .stopped)
            call?.cancel()
            return
        }
    }

    /// The turn's usage for the app (`agneta/usage`): from the engine's per-call ledger, with
    /// what the numbers mean. Unknown values stay null.
    func usage(_ turn: [String: JSONValue], account: String) -> JSONValue {
        let ledger = turn["ledger"]
        return [
            "modelCalls": turn["modelCalls"] ?? .null, "models": turn["models"] ?? .array([]),
            "inputTokens": ledger?["input"] ?? .null, "outputTokens": ledger?["output"] ?? .null,
            "cacheReadTokens": ledger?["cacheRead"] ?? .null, "cacheWriteTokens": ledger?["cacheWrite"] ?? .null,
            "cost": turn["cost"] ?? .null, "costKind": turn["costKind"] ?? .null,
            "billing": .string(accounts[account]?.billing ?? "unknown"), "account": .string(account),
            "taskCost": turn["taskCost"] ?? .null,
            "ms": turn["ms"] ?? .null, "msToFirstToken": turn["msToFirstToken"] ?? .null, "basis": turn["basis"] ?? "engine-ledger",
        ]
    }

    /// The turn's usage with, when the user set a spending limit for the app, where it stands after this turn.
    func usage(_ turn: [String: JSONValue], account: String, meter: String) -> JSONValue {
        let base = usage(turn, account: account)
        let calls = turn["modelCalls"]?.intValue ?? 0
        let cost: Double = switch turn["cost"] { case .double(let v)?: v; case .int(let v)?: Double(v); default: 0 }
        return appUsageReport(meter: meter, unpriced: countsSpend(account) && calls > 0 && cost == 0).map { base.setting("app", to: $0) } ?? base
    }
}
