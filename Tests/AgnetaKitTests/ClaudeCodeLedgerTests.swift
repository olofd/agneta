// Claude Code's per-call usage from its session transcript, and how the trace completes the stream's partial rows
// with it. The lines follow the shape measured on Claude Code 2.1.326 through claude-agent-acp 0.107.2 (against a
// fake Messages API: no account), abridged to the keys that matter; the values are made up.
import Foundation
import Testing

@testable import AgnetaKit

@Suite struct ClaudeCodeLedgerTests {
    /// One transcript line for one content block of an assistant message, as Claude Code writes it.
    static func line(
        _ id: String, block: String = "text", output: Int, stop: String? = "tool_use", model: String = "claude-haiku-5-5"
    ) -> String {
        let stopValue = stop.map { "\"\($0)\"" } ?? "null"
        return
            #"{"parentUuid":"u0","isSidechain":false,"message":{"id":"\#(id)","type":"message","role":"assistant","model":"\#(model)","content":[{"type":"\#(block)","text":"…"}],"stop_reason":\#(stopValue),"stop_sequence":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":40,"cache_read_input_tokens":900,"output_tokens":\#(output),"output_tokens_details":{"thinking_tokens":0},"service_tier":"standard"}},"apiBlockIndex":0,"type":"assistant","uuid":"u1","timestamp":"2026-11-20T11:25:58.157Z","entrypoint":"sdk-ts","sessionId":"s","version":"2.1.326"}"#
            + "\n"
    }

    /// A tool result that quotes an assistant line: a user line, never a call.
    static let quotingUser =
        #"{"parentUuid":"u1","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"{\"type\":\"assistant\",\"message\":{\"id\":\"msg_q\",\"usage\":{\"output_tokens\":9},\"stop_reason\":\"end_turn\"}}"}]},"uuid":"u2","timestamp":"2026-11-20T11:25:59.000Z"}"#
        + "\n"

    struct Account {
        let config: URL
        let project: URL
        init() throws {
            config = FileManager.default.temporaryDirectory.appending(
                path: "agneta-cc-ledger-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            project = config.appending(path: "projects/-private-tmp-work", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }
        var transcript: URL { project.appending(path: "s.jsonl") }
        var subagent: URL { project.appending(path: "s/subagents/agent-a1.jsonl") }
        func append(_ text: String, to file: URL) throws {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                try Data().write(to: file)
            }
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }
        func remove() { try? FileManager.default.removeItem(at: config) }
    }

    @Test func readsEachFinalCallOnceIncrementally() throws {
        let account = try Account()
        defer { account.remove() }
        let ledger = ClaudeCodeTranscriptLedger(config: account.config, session: "s")
        #expect(ledger.read().usage.isEmpty) // no transcript yet
        try account.append(
            #"{"type":"queue-operation","operation":"enqueue"}"# + "\n" + Self.line("msg_a", output: 321)
                + Self.line("msg_a", block: "tool_use", output: 321) + Self.quotingUser
                + Self.line("msg_cut", output: 4, stop: nil) // cut off: the opening count, not final
                + Self.line("msg_err", output: 0, stop: "stop_sequence", model: "<synthetic>")
                + String(Self.line("msg_b", output: 123, stop: "end_turn").prefix(60)), // still being written
            to: account.transcript)
        let first = ledger.read().usage
        #expect(first.map { $0["id"]?.stringValue } == ["msg_a"])
        #expect(first[0]["output_tokens"]?.intValue == 321 && first[0]["input_tokens"]?.intValue == 3)
        #expect(first[0]["cache_read_tokens"]?.intValue == 900 && first[0]["cache_write_tokens"]?.intValue == 40)
        #expect(first[0]["output_partial"] == .bool(false) && first[0]["basis"]?.stringValue == "engine-transcript")
        #expect(first[0]["model"]?.stringValue == "claude-haiku-5-5")

        try account.append(
            String(Self.line("msg_b", output: 123, stop: "end_turn").dropFirst(60)), to: account.transcript)
        try account.append(Self.line("msg_sub", output: 77), to: account.subagent) // a subagent's call
        let second = ledger.read().usage
        #expect(second.map { $0["id"]?.stringValue } == ["msg_b", "msg_sub"])
        #expect(second[0]["output_tokens"]?.intValue == 123 && second[1]["output_tokens"]?.intValue == 77)
        #expect(ledger.read().usage.isEmpty)
    }

    static let adapter = ClaudeCodeAdapter(
        executable: URL(filePath: "/x"), cli: InstalledCLI(path: URL(filePath: "/y"), version: nil, source: "path"))

    static func trace(_ account: Account) -> (Traces, TraceSession) {
        let traces = Traces(folder: account.config.appending(path: "traces", directoryHint: .isDirectory))
        let session = traces.open(task: "t1", lease: "l", engineSession: "s")
        session.follow(adapter.ledger(stateRoot: account.config, engineSession: "s"))
        session.pollInterval = .seconds(60) // the test reads when it means to
        return (traces, session)
    }

    static func feed(_ session: TraceSession, _ params: JSONValue) {
        if let row = adapter.modelCall(fromNotification: "_claude/sdkMessage", params: params) {
            session.ingest(modelCall: row)
        }
    }

    static func modelCalls(_ traces: Traces) -> [JSONValue] {
        (traces.records(task: "t1") ?? []).filter { $0["kind"]?.stringValue == "model-call" }
    }

    /// The stream's partial rows wait for the transcript's final ones: each call is recorded once, complete, while
    /// the turn runs; the last call's line, which lands just after the result, is waited for at the turn's end.
    @Test func streamRowsWaitForTheTranscriptsFinalRows() async throws {
        let account = try Account()
        defer { account.remove() }
        let (traces, session) = Self.trace(account)
        session.turnStarted(prompt: nil)
        Self.feed(session, ClaudeCodeUsageTests.assistant("msg_a", output: 2))
        Self.feed(session, ClaudeCodeUsageTests.assistant("msg_a", output: 2)) // its next content block
        Self.feed(session, ClaudeCodeUsageTests.assistant("msg_b", output: 2))
        #expect(session.progress.turnModelCalls == 2) // held rows count toward the turn's limit
        try account.append(
            Self.line("msg_a", output: 321) + Self.line("msg_a", block: "tool_use", output: 321), to: account.transcript)
        await session.pollLedger()
        session.writer.flush()
        let live = Self.modelCalls(traces)
        #expect(live.count == 1)
        #expect(live.first?["output"]?.intValue == 321 && live.first?["outputPartial"] == .bool(false))
        #expect(live.first?["basis"]?.stringValue == "engine-transcript")

        Self.feed(session, ClaudeCodeUsageTests.result(input: 6, output: 450, cacheRead: 1800, cacheWrite: 80, cost: 0.002))
        let late = Task {
            try? await Task.sleep(for: .milliseconds(60))
            try? account.append(Self.line("msg_b", output: 123, stop: "end_turn"), to: account.transcript)
        }
        let turn = await session.turnEnded(stopReason: "end_turn", usage: nil)
        await late.value
        #expect(turn["modelCalls"]?.intValue == 2)
        #expect(turn["callLedger"]?["output"]?.intValue == 444) // every call's final count
        #expect(turn["ledger"]?["output"]?.intValue == 450) // the engine's totals, side calls included
        #expect(turn["basis"]?.stringValue == "engine-turn-totals")
        let calls = Self.modelCalls(traces)
        #expect(calls.map { $0["output"]?.intValue } == [321, 123])
        #expect(calls.allSatisfy { $0["outputPartial"] == .bool(false) })
        traces.close(task: "t1")
    }

    /// No transcript line in time: the stream's rows go out as they are, partial, once their thread's next call has
    /// begun (after `holdAfterNext`) or at the turn's end (after `finalGrace`). A subagent's calls are a thread of
    /// their own, so the session's next call doesn't hurry them.
    @Test func withoutTheTranscriptStreamRowsGoOutPartial() async throws {
        let account = try Account()
        defer { account.remove() }
        let (traces, session) = Self.trace(account)
        session.holdAfterNext = .zero
        session.finalGrace = .milliseconds(50)
        session.turnStarted(prompt: nil)
        func subagent(_ id: String) -> JSONValue {
            ClaudeCodeUsageTests.assistant(id, output: 3).setting(
                "message",
                to: (ClaudeCodeUsageTests.assistant(id, output: 3)["message"] ?? [:]).setting(
                    "parent_tool_use_id", to: "toolu_1"))
        }
        Self.feed(session, ClaudeCodeUsageTests.assistant("msg_a", output: 2))
        Self.feed(session, subagent("msg_s1"))
        Self.feed(session, ClaudeCodeUsageTests.assistant("msg_b", output: 2)) // msg_a has ended
        await session.pollLedger()
        session.writer.flush()
        let early = Self.modelCalls(traces)
        #expect(early.map { $0["output"]?.intValue } == [2])
        #expect(early.first?["outputPartial"] == .bool(true) && early.first?["basis"]?.stringValue == "engine-stream")

        let turn = await session.turnEnded(stopReason: "end_turn", usage: nil)
        #expect(turn["modelCalls"]?.intValue == 3)
        #expect(Self.modelCalls(traces).allSatisfy { $0["outputPartial"] == .bool(true) })
        traces.close(task: "t1")
    }
}
