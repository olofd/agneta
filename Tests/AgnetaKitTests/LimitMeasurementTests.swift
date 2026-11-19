// Measurements behind the app limits' stated bounds (manual, opt-in):
//   AGNETA_MEASURE_LIMITS=1 swift test --filter LimitMeasurementTests
// Real Goose and OpenCode against the fake model, in a temporary home: how long after a model call ends Agneta knows
// its usage (the engine's ledger, read every 2 s while a turn runs), which bounds what a turn can spend past an app's
// spending limit before the watchdog sees it; and whether the ledger carries a cost (the fake model has no price, so
// neither does: real costs need an API key, and none is used here). Prints one line per measurement,
// and checks only what the design relies on. docs/ENGINES.md keeps the numbers.
import Foundation
import Testing

@testable import AgnetaKit

@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["AGNETA_MEASURE_LIMITS"] != nil && GooseHarness.available
            && BuiltTools.shellBuilt))
struct LimitMeasurementTests {
    /// Each turn makes two model calls with a tool between them that runs 4 s, and the second call takes 5 s (the fake
    /// model answers "slowly" to a tool result saying so). The first call's ledger row should reach the trace while the
    /// tool or the second call runs: its lag is its arrival after the tool started (right after the call ended), after
    /// the tool ended, and how long before the turn's end.
    @Test(arguments: AppScenarioTests.engines) func ledgerLagWhileATurnRuns(account: String) async throws {
        let stack = try await RouterIntegrationTests.Stack.start(port: UInt16(47425), modelPort: 47426)
        do {
            let client = AppClient(port: stack.port)
            try await client.pairAndInitialize("Measure")
            let session = try await client.newSession(
                cwd: try stack.workspace("Measure"), tools: "workspace", account: account, sandbox: "contained")
            var lags: [Double] = []
            var afterTool: [Double] = []
            var costs: [String] = []
            var beforeTurnEnd: [Double] = []
            var calls: [Int] = []
            for _ in 0..<5 {
                _ = try await client.prompt(session, #"CALL shell {"command": "sleep 4; echo slowly"}"#)
            }
            let records = try stack.traces.text(of: session).split(separator: "\n").map {
                try JSONCoding.decode(Data($0.utf8))
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for turn in 1...5 {
                let mine = records.filter { $0["turn"]?.intValue == Int64(turn) }
                guard let tool = mine.first(where: { $0["kind"]?.stringValue == "tool-call" }),
                    let started = tool["tStart"]?.stringValue.flatMap(formatter.date),
                    let call = mine.first(where: { $0["kind"]?.stringValue == "model-call" }),
                    let seen = call["t"]?.stringValue.flatMap(formatter.date)
                else { continue }
                lags.append(seen.timeIntervalSince(started))
                if let result = mine.first(where: { $0["kind"]?.stringValue == "tool-result" }),
                    let ended = result["tEnd"]?.stringValue.flatMap(formatter.date)
                {
                    afterTool.append(seen.timeIntervalSince(ended))
                }
                costs.append(call["cost"].map { "\($0)" } ?? "absent")
                calls.append(mine.filter { $0["kind"]?.stringValue == "model-call" }.count)
                if let end = mine.first(where: { $0["kind"]?.stringValue == "turn" })?["t"]?.stringValue.flatMap(
                    formatter.date)
                {
                    beforeTurnEnd.append(end.timeIntervalSince(seen))
                }
            }
            func list(_ values: [Double]) -> String { values.map { String(format: "%.2f", $0) }.joined(separator: " ") }
            print(
                "MEASURE \(account) ledger row seen after the call ended (s):", list(lags), "after its tool ended:",
                list(afterTool),
                "before the turn's end:", list(beforeTurnEnd),
                "model calls per turn:", calls.map(String.init).joined(separator: " "), "costs:",
                costs.joined(separator: " "))
            // Goose writes a call's row when the call ends; OpenCode when its step ends, after the tools it called ran.
            // Either way Agneta reads it within one poll (2 s) of the write.
            #expect(
                lags.count == 5 && zip(lags, afterTool).allSatisfy { min($0, max($1, 0)) < 2.5 }, "\(lags) \(afterTool)"
            )
            client.close()
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }

    /// The user's limits for an app hold on a real engine and runtime: a second turn waits for the app's "at once", and
    /// a new task past its limit is refused with -32016. (Spending needs a priced model, so an API key: not here.)
    @Test func limitsHoldOnARealEngine() async throws {
        let stack = try await RouterIntegrationTests.Stack.start(port: UInt16(47428), modelPort: 47429)
        do {
            let client = AppClient(port: stack.port)
            try await client.pairAndInitialize("Limited")
            let grant = try #require(await stack.runtime.router.tokens.values.first { $0.app == "Limited" }?.id)
            try await stack.runtime.setLimits(
                grant: grant, limits: AppLimits(atOnce: 1, newTasks: .init(max: 2, period: .hour)))
            let project = try stack.workspace("Limited")
            let one = try await client.newSession(cwd: project, tools: "workspace", sandbox: "contained")
            let two = try await client.newSession(cwd: project, tools: "workspace", sandbox: "contained")
            let started = ContinuousClock.now
            async let first = client.prompt(one, #"CALL shell {"command": "sleep 2; echo done"}"#)
            try await Task.sleep(for: .milliseconds(300))
            async let second = client.prompt(two, "hello")
            let results = try await [first, second]
            #expect(results.allSatisfy { $0["stopReason"]?.stringValue == "end_turn" })
            let queued = client.notifications("agneta/queued").first { $0["sessionId"]?.stringValue == two }
            print(
                "MEASURE at once on Goose: queued", queued.map { "\($0)" } ?? "none", "both done after",
                ContinuousClock.now - started)
            #expect(queued?["waitingFor"]?.stringValue == "app")
            do {
                _ = try await client.newSession(cwd: project, tools: "workspace", sandbox: "contained")
                Issue.record("a third new task started")
            } catch let error as RPCError {
                print("MEASURE new tasks on Goose:", error.code, error.message)
                #expect(error.code == -32016)
            }
            let status = await stack.runtime.appStatus(grant: grant)
            #expect(status.today.tasks == 2 && status.today.turns == 2)
            client.close()
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }
}
