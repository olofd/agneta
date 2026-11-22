// Regression tests for faults found by measuring: stray sign-in callbacks, Claude Code's usage reporting and Codex's
// modes. The stalled-engines test is in TimingTests.
import Foundation
import Testing

@testable import AgnetaKit

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite struct ClaudeCodeUsageTests {
    static func sdk(_ message: JSONValue) -> JSONValue { ["sessionId": "s", "message": message] }
    static func assistant(_ id: String, output: Int) -> JSONValue {
        sdk([
            "type": "assistant",
            "message": [
                "id": .string(id), "model": "claude-haiku-5-5",
                "usage": [
                    "input_tokens": 2, "output_tokens": .int(Int64(output)), "cache_read_input_tokens": 100,
                    "cache_creation_input_tokens": 10
                ]
            ]
        ])
    }
    static func result(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, cost: Double) -> JSONValue {
        sdk([
            "type": "result",
            "modelUsage": [
                "claude-haiku-5-5": [
                    "inputTokens": .int(Int64(input)), "outputTokens": .int(Int64(output)),
                    "cacheReadInputTokens": .int(Int64(cacheRead)), "cacheCreationInputTokens": .int(Int64(cacheWrite)),
                    "costUSD": .double(cost)
                ]
            ]
        ])
    }

    /// Measured on Haiku: per-message usage holds the stream's opening output count (40 recorded, 210 real).
    /// The turn's ledger comes from the result's running totals, each turn getting its own share, side calls included.
    @Test func turnLedgerUsesTheResultsTotals() async throws {
        let adapter = ClaudeCodeAdapter(
            executable: URL(filePath: "/x"), cli: InstalledCLI(path: URL(filePath: "/y"), version: nil, source: "path"))
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "agneta-cc-usage-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let traces = Traces(folder: folder)
        let session = traces.open(task: "t1", lease: "l", engineSession: "s")
        func feed(_ params: JSONValue) {
            if let row = adapter.modelCall(fromNotification: "_claude/sdkMessage", params: params) {
                session.ingest(modelCall: row)
            }
        }
        session.turnStarted(prompt: nil)
        feed(Self.assistant("m1", output: 6))
        feed(Self.result(input: 2, output: 6, cacheRead: 100, cacheWrite: 10, cost: 0.0002))
        let first = await session.turnEnded(stopReason: "end_turn", usage: nil)
        #expect(first["ledger"]?["output"]?.intValue == 6)

        session.turnStarted(prompt: nil)
        feed(Self.assistant("m2", output: 8))
        feed(Self.assistant("m2", output: 8)) // the same call again, for its next content block
        feed(Self.assistant("m3", output: 24))
        feed(Self.result(input: 1186, output: 230, cacheRead: 300, cacheWrite: 30, cost: 0.0014))
        let second = await session.turnEnded(stopReason: "end_turn", usage: nil)
        #expect(second["modelCalls"]?.intValue == 2)
        #expect(second["callLedger"]?["output"]?.intValue == 32)
        #expect(second["ledger"]?["output"]?.intValue == 224)
        #expect(second["ledger"]?["input"]?.intValue == 1184)
        #expect(second["ledger"]?["cacheRead"]?.intValue == 200)
        #expect(second["basis"]?.stringValue == "engine-turn-totals")
        guard case .double(let cost)? = second["cost"] else { Issue.record("no cost"); return }
        #expect(abs(cost - 0.0012) < 1e-9)

        // A resumed task's new engine process starts its totals over: all of it is the new turn's.
        session.turnStarted(prompt: nil)
        feed(Self.result(input: 5, output: 7, cacheRead: 50, cacheWrite: 0, cost: 0.0001))
        let third = await session.turnEnded(stopReason: "end_turn", usage: nil)
        #expect(third["ledger"]?["output"]?.intValue == 7)
        traces.close(task: "t1")
        let summary = TraceSummary(records: traces.records(task: "t1") ?? [])
        #expect(summary.output == 6 + 224 + 7)
    }
}

@Suite struct CodexModeTests {
    /// `agent` gives Codex's approval questions to its own model reviewer, not to Agneta.
    @Test func autoReviewIsRefused() {
        let codex = CodexAdapter(
            node: URL(filePath: "/n"), script: URL(filePath: "/s"),
            cli: InstalledCLI(path: URL(filePath: "/c"), version: nil, source: "path"))
        #expect(codex.permitsMode("read-only") && codex.permitsMode("workspace-write"))
        #expect(
            !codex.permitsMode("agent") && !codex.permitsMode("agent-full-access")
                && !codex.permitsMode("permission-profile:x"))
    }
}
