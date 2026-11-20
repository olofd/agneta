// The limits the user sets for an app, held by the router (Router+AppLimits), against the in-memory fake engine and
// an injected clock: at once, spending (live, across the app's turns, never a plan's), engines it can't count, new
// tasks under a burst, limits that travel with the app, and which limit a turn reports when two are passed at once.
import Foundation
import Testing

@testable import AgnetaKit

/// A clock the test moves.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

@Suite(.serialized) struct AppLimitsContractTests {
    typealias Stack = RouterContractTests.Stack

    static func grant(_ stack: Stack, _ app: String) async throws -> String {
        try #require(await stack.router.tokens.values.first { $0.app == app && $0.remembered }?.id)
    }

    static func until(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)")
    }

    static func running(_ stack: Stack, _ session: String) async throws {
        try await until("\(session) to run") { await stack.router.runningTurns[session]?.began == true }
    }

    /// A JSON number, whole numbers included (they come back from the wire as integers).
    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let v)?: v
        case .int(let v)?: Double(v)
        default: nil
        }
    }

    static func refusal(_ work: () async throws -> JSONValue) async -> RPCError? {
        do {
            _ = try await work()
            return nil
        } catch let error as RPCError {
            return error
        } catch {
            return nil
        }
    }

    @Test func atOnceHoldsAnAppsTurnsAndNoOneElses() async throws {
        let stack = try await Stack.start(port: 47660)
        defer { stack.stop() }
        let capped = AppClient(port: stack.port), other = AppClient(port: stack.port)
        defer { capped.close(); other.close() }
        try await capped.pairAndInitialize("Capped")
        try await other.pairAndInitialize("Other")
        let grant = try await Self.grant(stack, "Capped")
        try await stack.router.setLimits(grant: grant, limits: AppLimits(atOnce: 1))
        let first = try await stack.session(capped, account: "brokered"),
            second = try await stack.session(capped, account: "brokered")
        let elsewhere = try await stack.session(other, account: "brokered")

        let running = Task { try await capped.prompt(first, "slow") }
        try await Self.running(stack, first)
        let waiting = Task { try await capped.prompt(second, "hello") }
        try await Self.until("the turn to queue") {
            capped.notifications("agneta/queued").contains { $0["sessionId"]?.stringValue == second }
        }
        #expect(capped.notifications("agneta/queued").last?["waitingFor"]?.stringValue == "app")
        let access = try AccessReport(json: try await capped.request("agneta/access", [:]))
        #expect(access.limits?.atOnce == .init(max: 1, running: 1) && access.limits?.spend == nil)
        // Another app's turn on the same account isn't held up by this app's limit.
        #expect(try await other.prompt(elsewhere, "hello")["stopReason"]?.stringValue == "end_turn")
        // Raising the limit lets the waiting turn run.
        try await stack.router.setLimits(grant: grant, limits: AppLimits(atOnce: 2))
        #expect(try await waiting.value["stopReason"]?.stringValue == "end_turn")
        capped.notify("session/cancel", ["sessionId": .string(first)])
        _ = try await running.value
        #expect(capped.notifications("agneta/accessChanged").last?["access"]?["limits"]?["atOnce"]?["max"] == .int(2))
    }

    @Test func spendingStopsTheAppsTurnsOnItsKeysAndNothingElse() async throws {
        let clock = TestClock(AppLimitsTests.date("2026-11-19T12:00:00Z"))
        // The fake engine stops one slow turn per cancel; the other is ended at the limit's grace.
        let stack = try await Stack.start(
            port: 47661, concurrency: .init(limitGrace: .milliseconds(300)), clock: clock,
            calendar: AppLimitsTests.calendar("Europe/Stockholm"))
        defer { stack.stop() }
        let app = AppClient(port: stack.port), other = AppClient(port: stack.port)
        defer { app.close(); other.close() }
        try await app.pairAndInitialize("Spender")
        try await other.pairAndInitialize("Other")
        try await stack.router.setLimits(
            grant: try await Self.grant(stack, "Spender"), limits: AppLimits(spend: .init(max: 1, period: .day)))
        let one = try await stack.session(app, account: "brokered"),
            two = try await stack.session(app, account: "brokered")
        let idle = try await stack.session(app, account: "brokered"),
            onPlan = try await stack.session(app, account: "native")
        let elsewhere = try await stack.session(other, account: "brokered")

        let first = Task { try await app.prompt(one, "slow") }, second = Task { try await app.prompt(two, "slow") }
        try await Self.running(stack, one)
        try await Self.running(stack, two)
        // The engine's records say the first turn spent $1.50: both of the app's turns stop.
        stack.traces.session(one)?.ingest(modelCall: [
            "id": "call-1", "cost": .double(1.5), "input_tokens": 100, "output_tokens": 10
        ])
        for result in [try await first.value, try await second.value] {
            let limit = result["_meta"]?["agneta/limit"]
            #expect(
                limit?["limit"] == "appSpend" && limit?["setBy"] == "user" && Self.number(limit?["value"]) == 1
                    && limit?["period"] == "day", "\(result)")
            #expect(result["stopReason"] == "cancelled")
        }
        #expect(try stack.records(one).contains { $0["event"]?.stringValue == "app-limit" })

        // More is refused, as the user's choice, with when it resets: midnight in Stockholm.
        let refused = await Self.refusal { try await app.prompt(idle, "hello") }
        #expect(
            refused?.code == -32016 && refused?.message.contains("$1 a day") == true, "\(String(describing: refused))")
        let detail = refused?.data?["agneta"]?["appLimit"]
        #expect(
            detail?["limit"] == "spend" && Self.number(detail?["used"]) == 1.5
                && detail?["resetsAt"]?.stringValue?.hasPrefix("2026-11-19T23:00:00") == true)
        #expect(
            await Self.refusal {
                _ = try await stack.session(app, account: "brokered"); return [:]
            }?.code == -32016)
        let access = try AccessReport(json: try await app.request("agneta/access", [:]))
        #expect(
            access.limits?.spend?.used == 1.5 && access.limits?.spend?.billing == "api-key"
                && access.limits?.spend?.counted["goose"] == "live")

        // A plan isn't charged per call: the limit doesn't count or stop it. Nor another app's turns.
        #expect(try await app.prompt(onPlan, "hello")["stopReason"]?.stringValue == "end_turn")
        #expect(try await other.prompt(elsewhere, "hello")["stopReason"]?.stringValue == "end_turn")

        // After midnight the app may spend again, and each turn says where it stands.
        clock.advance(12 * 3600)
        let next = try await app.prompt(idle, "hello")
        #expect(
            next["stopReason"] == "end_turn" && Self.number(next["_meta"]?["agneta/usage"]?["app"]?["spent"]) == 0,
            "\(next)")
        let status = await stack.router.appStatus(grant: try await Self.grant(stack, "Spender"))
        #expect(status.spent == 0 && status.today.turns == 1)
    }

    @Test func anEngineThatReportsNoCostCantRunUnderASpendingLimit() async throws {
        let stack = try await Stack.start(port: 47662)
        defer { stack.stop() }
        await stack.router.setCatalog(
            EngineCatalog([
                .init(ready: RouterContractTests.goose),
                .init(id: "codex", name: "Codex", state: .downloadable(size: nil))
            ]))
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Spender")
        let grant = try await Self.grant(stack, "Spender")
        let onCodex: [String: JSONValue] = ["agneta": ["account": "brokered", "engine": "codex"]]
        // Without a limit Codex runs (here it downloads first).
        #expect(
            await Self.refusal {
                _ = try await stack.session(app, account: "brokered", meta: onCodex); return [:]
            }?.code == -32015)

        try await stack.router.setLimits(grant: grant, limits: AppLimits(spend: .init(max: 5, period: .week)))
        let refused = await Self.refusal {
            _ = try await stack.session(app, account: "brokered", meta: onCodex); return [:]
        }
        #expect(
            refused?.code == RPCError.invalidParams
                && refused?.message
                    == "Codex reports no cost, so it can't run under the spending limit you set for this app in Agneta"
        )
        let access = try AccessReport(json: try await app.request("agneta/access", [:]))
        let key = try #require(access.providers.first { $0.id == "brokered" })
        #expect(key.engines == ["goose"] && key.uncounted == ["codex"])
        #expect(access.providers.first { $0.id == "native" }?.uncounted == nil)
        #expect(access.limits?.spend?.uncounted == ["codex"])
        // A task that names no engine runs on one the limit can count.
        _ = try await stack.session(app, account: "brokered")
        #expect(await stack.engines.askedEngines.last == "goose")
    }

    @Test func newTasksAreCountedBeforeTheyStart() async throws {
        let clock = TestClock(AppLimitsTests.date("2026-11-19T12:00:00Z"))
        let stack = try await Stack.start(port: 47663, clock: clock)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Starter")
        try await stack.router.setLimits(
            grant: try await Self.grant(stack, "Starter"), limits: AppLimits(newTasks: .init(max: 3, period: .hour)))
        let first = try await stack.session(app, account: "brokered")
        _ = try await stack.session(app, account: "brokered")
        // A fork that fails (this engine can't export) isn't counted.
        await stack.engines.exporting(false)
        #expect(
            await Self.refusal { try await app.request("agneta/fork", ["sessionId": .string(first), "mcpServers": []]) }
                != nil)
        _ = try await stack.session(app, account: "brokered")
        let refused = await Self.refusal {
            _ = try await stack.session(app, account: "brokered"); return [:]
        }
        #expect(refused?.code == -32016 && refused?.data?["agneta"]?["appLimit"]?["limit"] == "newTasks")
        #expect(
            refused?.data?["agneta"]?["appLimit"]?["resetsAt"]?.stringValue?.hasPrefix("2026-11-19T13:00:00") == true)
        // Resuming a task isn't a new one.
        _ = try await stack.meta(first)
        _ = try await app.request("session/close", ["sessionId": .string(first)])
        let loaded = try await app.request(
            "session/load",
            [
                "sessionId": .string(first),
                "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": []
            ])
        #expect(loaded["_meta"]?["agneta"]?["resumed"] == true)

        // An hour later: ten at once, slow to start, and exactly three get through.
        clock.advance(3601)
        await stack.engines.starting(takes: .milliseconds(200))
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 { group.addTask { (try? await stack.session(app, account: "brokered")) != nil } }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(outcomes.count(where: { $0 }) == 3)
    }

    @Test func limitsTravelWithTheApp() async throws {
        let answers = RememberAnswers([true, false])
        let stack = try await Stack.start(
            port: 47664, approve: { _ in Router.PairingAnswer(accounts: ["brokered"], remember: await answers.next()) })
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Example")
        let grant = try await Self.grant(stack, "Example")
        let limits = AppLimits(spend: .init(max: 2, period: .month), newTasks: .init(max: 10, period: .day))
        try await stack.router.setLimits(grant: grant, limits: limits)
        try await Self.until("accessChanged") {
            Self.number(app.notifications("agneta/accessChanged").last?["access"]?["limits"]?["spend"]?["max"]) == 2
        }
        #expect(
            await Self.refusal {
                try await stack.router.setLimits(grant: grant, limits: AppLimits(atOnce: 9)); return [:]
            }?.code == RPCError.invalidParams)

        // Allowed once more, it has the same limits and counts against the same usage: no fresh budget.
        let again = AppClient(port: stack.port)
        defer { again.close() }
        try await again.pairAndInitialize("Example")
        let access = try AccessReport(json: try await again.request("agneta/access", [:]))
        #expect(access.limits?.spend?.max == 2 && access.limits?.newTasks?.max == 10)
        let once = try #require(await stack.router.tokens.values.first { !$0.remembered })
        #expect(once.meter == grant && once.limits == limits)
        _ = try await stack.session(again, account: "brokered")
        #expect(await stack.router.appStatus(grant: grant).started == 1)
    }

    @Test func aTurnPastItsPolicyAndTheAppsLimitReportsItsPolicy() async throws {
        let stack = try await Stack.start(port: 47665)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Both")
        try await stack.router.setLimits(
            grant: try await Self.grant(stack, "Both"), limits: AppLimits(spend: .init(max: 1, period: .day)))
        let session = try await stack.session(
            app, account: "brokered",
            meta: [
                SessionPolicy.key: [
                    "tools": "app-only", "network": "none", "approval": "never-ask",
                    "limits": ["maxTurns": 1]
                ]
            ])
        let turn = Task { try await app.prompt(session, "slow") }
        try await Self.running(stack, session)
        let trace = try #require(stack.traces.session(session))
        trace.ingest(modelCall: ["id": "a", "cost": .double(1)])
        trace.ingest(modelCall: ["id": "b", "cost": .double(1)])
        let limit = try await turn.value["_meta"]?["agneta/limit"]
        #expect(limit?["limit"] == "maxTurns" && limit?["setBy"] == "app", "\(String(describing: limit))")
    }
}

/// The engine's records for a session, as a test hands them out: slow to read while `slow`, and a row once armed.
final class TestLedger: UsageLedger, @unchecked Sendable {
    private let lock = NSLock()
    private var isSlow = false
    private var rows: [[String: JSONValue]] = []
    var slow: Bool {
        get { lock.withLock { isSlow } }
        set { lock.withLock { isSlow = newValue } }
    }
    func add(_ row: [String: JSONValue]) { lock.withLock { rows.append(row) } }
    func read() -> (messages: [[String: JSONValue]], usage: [[String: JSONValue]], problem: String?) {
        if slow { Thread.sleep(forTimeInterval: 1.5) }
        return lock.withLock { () -> ([[String: JSONValue]], [[String: JSONValue]], String?) in
            defer { rows = [] }
            return ([], rows, nil)
        }
    }
}

/// Found in review: each a probe first, kept as a regression test.
@Suite(.serialized) struct AppLimitsReviewTests {
    typealias Stack = RouterContractTests.Stack

    /// The spending limit is reached while another of the app's turns is finishing (in its last read of the engine's
    /// records). Once the user raises the limit, that session's next turn runs: nothing stale stops it.
    @Test func aTurnFinishingAtTheLimitLeavesNothingForTheNext() async throws {
        let stack = try await Stack.start(port: 47666, concurrency: .init(limitGrace: .milliseconds(300)))
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Spender")
        let grant = try await AppLimitsContractTests.grant(stack, "Spender")
        try await stack.router.setLimits(grant: grant, limits: AppLimits(spend: .init(max: 1, period: .day)))
        let one = try await stack.session(app, account: "brokered"),
            two = try await stack.session(app, account: "brokered")
        let ledger = TestLedger()
        stack.traces.session(two)?.follow(ledger)
        let first = Task { try await app.prompt(one, "slow") }
        try await AppLimitsContractTests.running(stack, one)
        ledger.slow = true
        let second = Task { try await app.prompt(two, "hello") }
        try await Task.sleep(for: .milliseconds(200))
        stack.traces.session(one)?.ingest(modelCall: ["id": "c1", "cost": .double(1.5)])
        _ = try await second.value
        _ = try await first.value
        ledger.slow = false
        #expect(await stack.router.sessions[two]?.limitHit == nil)
        try await stack.router.setLimits(grant: grant, limits: AppLimits(spend: .init(max: 100, period: .day)))
        let next = try await app.prompt(two, "slow")
        #expect(next["stopReason"] == "end_turn" && next["_meta"]?["agneta/limit"] == nil, "\(next)")
    }

    /// A task on Codex with an API key, open before the user set a spending limit, stops when the limit is set: the
    /// limit can't count it.
    @Test func codexOpenBeforeASpendingLimitStopsWhenItsSet() async throws {
        let stack = try await Stack.start(port: 47667)
        defer { stack.stop() }
        let codex = CodexAdapter(
            node: URL(filePath: "/usr/bin/false"), script: URL(filePath: "/x/index.js"), cli: EngineContractTests.cli)
        await stack.router.setCatalog(EngineCatalog(ready: [RouterContractTests.goose, codex]))
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Spender")
        let grant = try await AppLimitsContractTests.grant(stack, "Spender")
        let session = try await stack.session(
            app, account: "brokered", meta: ["agneta": ["account": "brokered", "engine": "codex"]])
        #expect(try await app.prompt(session, "hello")["stopReason"] == "end_turn")
        try await stack.router.setLimits(grant: grant, limits: AppLimits(spend: .init(max: 1, period: .day)))
        #expect(await stack.router.sessions[session] == nil)
        try await AppLimitsContractTests.until("sessionStopped") {
            app.notifications("agneta/sessionStopped").contains { $0["sessionId"]?.stringValue == session }
        }
        // Stopped by the limit the user set, and the app is told why.
        let stopped = app.notifications("agneta/sessionStopped").first { $0["sessionId"]?.stringValue == session }
        #expect(
            stopped?["stoppedBy"] == "limit" && stopped?["limit"]?["limit"] == "appSpend"
                && stopped?["limit"]?["setBy"] == "user")
        #expect(
            stopped?["limit"]?["reason"]?.stringValue?.hasPrefix("Codex reports no cost") == true,
            "\(String(describing: stopped))")
        #expect(await AppLimitsContractTests.refusal { try await app.prompt(session, "hello") } != nil)
    }

    /// With "at once" set and not reached, the app's turn on a free account doesn't wait behind its own turn waiting for
    /// a full account, and that one waits for its account, as it says.
    @Test func anAppsTurnWaitingForItsAccountHoldsUpNoneOfItsOthers() async throws {
        let stack = try await Stack.start(port: 47668, concurrency: .init(perAccount: 1))
        defer { stack.stop() }
        let capped = AppClient(port: stack.port), other = AppClient(port: stack.port)
        defer { capped.close(); other.close() }
        try await capped.pairAndInitialize("Capped")
        try await other.pairAndInitialize("Other")
        try await stack.router.setLimits(
            grant: try await AppLimitsContractTests.grant(stack, "Capped"), limits: AppLimits(atOnce: 2))
        let busy = try await stack.session(other, account: "brokered")
        let onKey = try await stack.session(capped, account: "brokered"),
            onPlan = try await stack.session(capped, account: "native")
        let holding = Task { try await other.prompt(busy, "slow") }
        try await AppLimitsContractTests.running(stack, busy)
        let queued = Task { try await capped.prompt(onKey, "hello") }
        try await AppLimitsContractTests.until("the key turn to queue") {
            capped.notifications("agneta/queued").contains { $0["sessionId"]?.stringValue == onKey }
        }
        #expect(
            capped.notifications("agneta/queued").first { $0["sessionId"]?.stringValue == onKey }?["waitingFor"]
                == "account")
        // The turn on the plan runs at once.
        #expect(try await capped.prompt(onPlan, "hello")["stopReason"] == "end_turn")
        #expect(!capped.notifications("agneta/queued").contains { $0["sessionId"]?.stringValue == onPlan })
        // The fake's slow turn ends by itself after 3 s, and the waiting one runs.
        _ = try await holding.value
        #expect(try await queued.value["stopReason"] == "end_turn")
    }

    /// Many turns of an app with "at once" set (not reached) waiting for a full account: each joins the queue at once.
    /// (Checking whether a waiting turn was held by its app once recursed over the app's earlier waiters: 20 took a
    /// second, 24 took 20, with the router blocked for every app.)
    @Test func queueingManyTurnsOfACappedApp() async throws {
        let stack = try await Stack.start(port: 47680, concurrency: .init(perAccount: 1, limitGrace: .seconds(60)))
        defer { stack.stop() }
        let capped = AppClient(port: stack.port), other = AppClient(port: stack.port)
        defer { capped.close(); other.close() }
        try await capped.pairAndInitialize("Capped")
        try await other.pairAndInitialize("Other")
        try await stack.router.setLimits(
            grant: try await AppLimitsContractTests.grant(stack, "Capped"), limits: AppLimits(atOnce: 8))
        let busy = try await stack.session(other, account: "brokered")
        let holding = Task { try await other.prompt(busy, "deaf") }
        defer { holding.cancel() }
        try await AppLimitsContractTests.running(stack, busy)
        var turns: [Task<JSONValue, Error>] = []
        defer { turns.forEach { $0.cancel() } }
        var slowest = Duration.zero
        for _ in 1...30 {
            let session = try await stack.session(capped, account: "brokered")
            let started = ContinuousClock.now
            turns.append(Task { try await capped.prompt(session, "hello") })
            while await !stack.router.waiting.contains(where: { $0.session == session }),
                ContinuousClock.now - started < .seconds(5)
            {
                try await Task.sleep(for: .milliseconds(2))
            }
            slowest = max(slowest, ContinuousClock.now - started)
        }
        #expect(await stack.router.waiting.count == 30)
        #expect(slowest < .milliseconds(100), "the slowest took \(slowest)")
    }

    /// Each of the app's turns stopped by its spending limit says so, however their watchdogs' checks fall: here the
    /// second turn's checks come 300 ms after the first's, so the first is cancelled well before the second is found
    /// over the limit. (A cancel for one session once ended every slow turn of the fake engine, so the second answered
    /// as plainly cancelled, the limit unsaid, on runners fast enough to beat its own watchdog.)
    @Test func eachTurnStoppedByTheSpendingLimitSaysSo() async throws {
        let stack = try await Stack.start(port: 47681, concurrency: .init(limitGrace: .milliseconds(300)))
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Spender")
        try await stack.router.setLimits(
            grant: try await AppLimitsContractTests.grant(stack, "Spender"),
            limits: AppLimits(spend: .init(max: 1, period: .day)))
        let one = try await stack.session(app, account: "brokered"),
            two = try await stack.session(app, account: "brokered")
        let first = Task { try await app.prompt(one, "slow") }
        try await AppLimitsContractTests.running(stack, one)
        try await Task.sleep(for: .milliseconds(300))
        let second = Task { try await app.prompt(two, "slow") }
        try await AppLimitsContractTests.running(stack, two)
        stack.traces.session(one)?.ingest(modelCall: ["id": "call-1", "cost": .double(1.5)])
        for result in [try await first.value, try await second.value] {
            #expect(
                result["stopReason"] == "cancelled" && result["_meta"]?["agneta/limit"]?["limit"] == "appSpend",
                "\(result)")
        }
    }

    /// A turn that called a model its engine gave no price for is marked, not silently counted as free.
    @Test func aTurnWithNoPriceIsMarked() async throws {
        let stack = try await Stack.start(port: 47669)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Spender")
        let grant = try await AppLimitsContractTests.grant(stack, "Spender")
        try await stack.router.setLimits(grant: grant, limits: AppLimits(spend: .init(max: 1, period: .day)))
        let session = try await stack.session(app, account: "brokered")
        let turn = Task { try await app.prompt(session, "slow") }
        try await AppLimitsContractTests.running(stack, session)
        stack.traces.session(session)?.ingest(modelCall: ["id": "free", "cost": .int(0), "input_tokens": 5])
        app.notify("session/cancel", ["sessionId": .string(session)])
        let result = try await turn.value
        #expect(result["_meta"]?["agneta/usage"]?["app"]?["unpriced"] == true, "\(result)")
        #expect(await stack.router.appStatus(grant: grant).today.unpriced == 1)
        #expect(try stack.records(session).contains { $0["event"]?.stringValue == "unpriced" })
    }

    /// What the engine records after a session's last turn ended still counts when the session closes.
    @Test func costRecordedAfterTheLastTurnCountsAtClose() async throws {
        let stack = try await Stack.start(port: 47670)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Spender")
        let grant = try await AppLimitsContractTests.grant(stack, "Spender")
        let session = try await stack.session(app, account: "brokered")
        let ledger = TestLedger()
        stack.traces.session(session)?.follow(ledger)
        _ = try await app.prompt(session, "hello")
        ledger.add(["id": "late", "cost": .double(0.4)])
        _ = try await app.request("session/close", ["sessionId": .string(session)])
        #expect(await stack.router.appStatus(grant: grant).today.cost == 0.4)
    }
}

/// Always Allow or Allow Once, in order, for approvals.
actor RememberAnswers {
    private var answers: [Bool]
    init(_ answers: [Bool]) { self.answers = answers }
    func next() -> Bool { answers.isEmpty ? true : answers.removeFirst() }
}
