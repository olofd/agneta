// Codex's per-call usage and plan limits from its session file (shapes measured on Codex 0.167.0).
import Foundation
import Testing

@testable import AgnetaKit

@Suite struct CodexLedgerTests {
    @Test func readsCallsModelsAndPlanIncrementally() throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "agneta-codex-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appending(path: "sessions/2026/11/17", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "rollout-2026-11-17T17-56-07-thread-1.jsonl")
        func line(_ value: JSONValue) -> String { var t = ""; TraceJSON.encode(value, into: &t); return t + "\n" }
        let limits: JSONValue = [
            "primary": ["used_percent": 57.0, "window_minutes": 10080, "resets_at": 1795282848],
            "secondary": ["used_percent": 12.0, "window_minutes": 300]
        ]
        try
            (line(["type": "turn_context", "payload": ["turn_id": "t1", "model": "gpt-6-luna"]])
            + line([
                "type": "token_usage_record", "timestamp": "2026-11-17T16:56:10Z",
                "payload": [
                    "turn_id": "t1", "response_id": "resp_1",
                    "usage": [
                        "input_tokens": 14685, "cached_input_tokens": 11520, "cache_write_input_tokens": 0,
                        "output_tokens": 7
                    ]
                ]
            ])
            + line(["type": "event_msg", "payload": ["type": "token_count", "rate_limits": limits]])
            + "{\"type\":\"token_usage").write(to: file, atomically: true, encoding: .utf8) // a line still being written
        let ledger = CodexRolloutLedger(codexHome: home, session: "thread-1")
        let first = ledger.read().usage
        #expect(first.count == 1)
        #expect(first[0]["model"]?.stringValue == "gpt-6-luna" && first[0]["id"]?.stringValue == "resp_1")
        #expect(first[0]["input_tokens"]?.intValue == 3165 && first[0]["cache_read_tokens"]?.intValue == 11520) // uncached input
        #expect(first[0]["plan"]?["primary"]?["used_percent"] != nil)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(
            contentsOf: Data(
                (#"_record","payload":{"turn_id":"t1","response_id":"resp_2","usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":5}}}"#
                    + "\n").utf8))
        try handle.close()
        let second = ledger.read().usage
        #expect(second.map { $0["id"]?.stringValue } == ["resp_2"]) // only the new call, the half line completed
        #expect(ledger.read().usage.isEmpty)

        #expect(PlanUsage.describe(limits) == "57% of this week's limit used")
        #expect(
            PlanUsage.describe(["primary": ["used_percent": 80, "window_minutes": 300]])
                == "80% of the 5-hour limit used")
        #expect(PlanUsage.describe(.null) == nil)
    }
}
