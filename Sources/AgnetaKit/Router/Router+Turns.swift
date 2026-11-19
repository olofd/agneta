// Turns: the queue that keeps every account within its concurrency (one account's turns never hold up
// another's), the watchdog that enforces a policy's limits while a turn runs, and what a turn's end reports.
import Foundation

extension Router {
    // MARK: Turn queue

    func hasRoom(for account: String) -> Bool {
        runningTurns.count < concurrency.global && runningTurns.values.filter { $0 == account }.count < concurrency.perAccount
    }

    /// Waits for room to run a turn. Returns false if the wait was cancelled; throws when the queue is full, or the
    /// account was paused while the turn waited.
    func admit(_ id: String, account: String) async throws -> Bool {
        // Waits only behind earlier turns on the same account: one account's limits never hold up another's.
        if hasRoom(for: account) && !waiting.contains(where: { $0.account == account }) {
            runningTurns[id] = account
            return true
        }
        guard waiting.count < concurrency.queue else {
            throw RPCError(code: Self.queueFull, message: "Too many AI tasks are waiting; try again shortly")
        }
        let position = waiting.count + 1
        traces?.session(id)?.writer.record("lifecycle", ["event": "queued", "position": .int(Int64(position)),
                                                         "running": .int(Int64(runningTurns.count))])
        let peer = sessions[id].flatMap { apps[$0.app]?.peer }
        let started = ContinuousClock.now
        // Joins the queue before anything can suspend, so a turn finishing or a cancel arriving meanwhile
        // finds it (announcing first could lose the wakeup and stall the account's queue).
        let admission = await withCheckedContinuation { continuation in
            waiting.append(Waiter(session: id, account: account, resume: continuation))
            if let peer { Task { try? await peer.notify("agneta/queued", ["sessionId": .string(id), "position": .int(Int64(position))]) } }
        }
        let waited = ContinuousClock.now - started
        let event: JSONValue = switch admission { case .admitted: "dequeued"; case .cancelled: "queue-cancelled"; case .paused: "queue-paused" }
        traces?.session(id)?.writer.record("lifecycle", ["event": event,
                                                         "ms": .double(Double(waited.components.seconds) * 1000 + Double(waited.components.attoseconds) / 1e15)])
        if admission == .paused { throw pausedError(account) }
        return admission == .admitted
    }

    /// A turn ended: let waiting turns run, oldest first, as long as their account has room.
    func finishTurn(_ id: String) {
        guard runningTurns.removeValue(forKey: id) != nil else { return }
        var index = 0
        while index < waiting.count {
            let waiter = waiting[index]
            if hasRoom(for: waiter.account) {
                waiting.remove(at: index)
                runningTurns[waiter.session] = waiter.account
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

    /// Enforces the policy's limits on a running prompt: checks twice a second and cancels the
    /// turn at the first limit passed, recording which.
    func watch(_ id: String, generation: UUID, limits: SessionPolicy.Limits) async {
        let started = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let session = sessions[id], session.generation == generation else { return }
            let elapsed = ContinuousClock.now - started
            let progress = traces?.session(id)?.progress ?? (turnModelCalls: 0, taskCost: 0)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            guard let hit = limits.breached(seconds: seconds, modelCalls: progress.turnModelCalls, cost: progress.taskCost) else { continue }
            sessions[id]?.limitHit = hit
            traces?.session(id)?.writer.record("lifecycle", ["event": "limit", "limit": .string(hit.limit), "value": hit.value])
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
}
