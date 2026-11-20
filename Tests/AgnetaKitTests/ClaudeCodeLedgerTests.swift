// Claude Code's per-call usage from its session transcript, and how the trace completes the stream's partial rows
// with it. The lines follow the shape measured on Claude Code 2.1.326 through claude-agent-acp 0.107.2 (against a
// fake Messages API: no account), abridged to the keys that matter; the values are made up.
import Darwin
import Foundation
import Testing

@testable import AgnetaKit

@Suite struct ClaudeCodeLedgerTests {
    static let session = "5d0c6a1e-0000-4000-8000-000000000001"

    /// One transcript line for one content block of an assistant message, as Claude Code writes it.
    static func line(
        _ id: String, block: String = "text", output: Int, stop: String? = "tool_use",
        model: String = "claude-haiku-5-5"
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
        var transcript: URL { project.appending(path: "\(session).jsonl") }
        var subagents: URL { project.appending(path: "\(session)/subagents", directoryHint: .isDirectory) }
        var subagent: URL { subagents.appending(path: "agent-a1.jsonl") }
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
        func ledger() throws -> ClaudeCodeTranscriptLedger {
            try #require(ClaudeCodeTranscriptLedger(config: config, session: session))
        }
        func remove() { try? FileManager.default.removeItem(at: config) }
    }

    @Test func readsEachFinalCallOnceIncrementally() throws {
        let account = try Account()
        defer { account.remove() }
        let ledger = try account.ledger()
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
        #expect(first[0]["output_partial"] == JSONValue.bool(false))
        #expect(first[0]["basis"]?.stringValue == "engine-transcript")
        #expect(first[0]["model"]?.stringValue == "claude-haiku-5-5")

        try account.append(
            String(Self.line("msg_b", output: 123, stop: "end_turn").dropFirst(60)), to: account.transcript)
        try account.append(Self.line("msg_sub", output: 77), to: account.subagent) // a subagent's call
        let second = ledger.read().usage
        #expect(second.map { $0["id"]?.stringValue } == ["msg_b", "msg_sub"])
        #expect(second[0]["output_tokens"]?.intValue == 123 && second[1]["output_tokens"]?.intValue == 77)
        #expect(ledger.read().usage.isEmpty)
    }

    /// The session's folder is the engine's to write: a FIFO (which would block an open), a link to a device, to
    /// another task's transcript or in place of a folder are all left alone, and reading never hangs.
    @Test(.timeLimit(.minutes(1))) func plantedFilesAreSkippedWithoutHanging() throws {
        let account = try Account()
        defer { account.remove() }
        try account.append(Self.line("msg_a", output: 321), to: account.transcript)
        try FileManager.default.createDirectory(at: account.subagents, withIntermediateDirectories: true)
        #expect(mkfifo(account.subagents.appending(path: "agent-fifo.jsonl").path(percentEncoded: false), 0o600) == 0)
        try FileManager.default.createSymbolicLink(
            at: account.subagents.appending(path: "agent-zero.jsonl"), withDestinationURL: URL(filePath: "/dev/zero"))
        let other = account.config.appending(path: "projects/-other/other.jsonl")
        try account.append(Self.line("msg_other", output: 999), to: other)
        try FileManager.default.createSymbolicLink(
            at: account.subagents.appending(path: "agent-other.jsonl"), withDestinationURL: other)
        try account.append(Self.line("msg_sub", output: 77), to: account.subagent)
        let ledger = try account.ledger()
        #expect(ledger.read().usage.map { $0["id"]?.stringValue } == ["msg_a", "msg_sub"])

        // A session folder that's a link to another task's: not followed.
        try FileManager.default.removeItem(at: account.project.appending(path: Self.session))
        try FileManager.default.createSymbolicLink(
            at: account.project.appending(path: Self.session),
            withDestinationURL: account.config.appending(path: "projects/-other", directoryHint: .isDirectory))
        try account.append(Self.line("msg_b", output: 5, stop: "end_turn"), to: account.transcript)
        #expect(ledger.read().usage.map { $0["id"]?.stringValue } == ["msg_b"])

        // The transcript itself swapped for a FIFO: skipped too.
        try FileManager.default.removeItem(at: account.transcript)
        #expect(mkfifo(account.transcript.path(percentEncoded: false), 0o600) == 0)
        #expect(ledger.read().usage.isEmpty)

        #expect(ClaudeCodeTranscriptLedger(config: account.config, session: "../../etc") == nil) // not a UUID
    }

    /// On resume, what's there is skipped by its size, without reading it; later lines are read.
    @Test func aResumedLedgerStartsAfterWhatsThere() throws {
        let account = try Account()
        defer { account.remove() }
        try account.append(Self.line("msg_old", output: 10, stop: "end_turn"), to: account.transcript)
        try account.append(Self.line("msg_old_sub", output: 10, stop: "end_turn"), to: account.subagent)
        let ledger = try account.ledger()
        #expect(ledger.startAfterExisting())
        try account.append(Self.line("msg_new", output: 20, stop: "end_turn"), to: account.transcript)
        #expect(ledger.read().usage.map { $0["id"]?.stringValue } == ["msg_new"])

        // Replaced by a shorter file: what's there is taken as read, so earlier turns aren't counted again.
        try (Self.line("msg_old", output: 10, stop: "end_turn")).write(
            to: account.transcript, atomically: true, encoding: .utf8)
        #expect(ledger.read().usage.isEmpty)
    }

    /// A sparse file of zeros (no disk used), `size` bytes long.
    static func sparse(_ file: URL, size: UInt64) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: size)
        try handle.close()
    }

    /// Huge files without a newline, planted and planted again under new names, keep what the reader holds within
    /// its caps; a line after an overlong one is still read.
    @Test func plantedHugeFilesKeepMemoryBounded() throws {
        let account = try Account()
        defer { account.remove() }
        try account.append(Self.line("msg_a", output: 1, stop: "end_turn"), to: account.transcript)
        let ledger = try account.ledger()
        for round in 0..<2 {
            for n in 0..<12 {
                try Self.sparse(account.subagents.appending(path: "agent-r\(round)-\(n).jsonl"), size: 64 << 20)
            }
            for _ in 0..<5 {
                _ = ledger.read()
                #expect(ledger.held.bytes <= ClaudeCodeTranscriptLedger.maxBuffered)
            }
            #expect(ledger.held.files <= 13)
            for n in 0..<12 {
                try FileManager.default.removeItem(at: account.subagents.appending(path: "agent-r\(round)-\(n).jsonl"))
            }
        }
        _ = ledger.read()
        #expect(ledger.held.files == 1) // the planted ones are forgotten

        // A line longer than any kept, then a call: the call is read once the long line is behind.
        let long = account.subagents.appending(path: "agent-long.jsonl")
        try Self.sparse(long, size: UInt64(ClaudeCodeTranscriptLedger.maxLine) + (1 << 20))
        try account.append("\n" + Self.line("msg_after", output: 2, stop: "end_turn"), to: long)
        var ids: [String] = []
        for _ in 0..<8 { ids += ledger.read().usage.compactMap { $0["id"]?.stringValue } }
        #expect(ids == ["msg_after"])
    }

    /// At most `maxRowsPerRead` new calls per read, the rest at the next, said once in the trace.
    @Test func callsPerReadAreCapped() throws {
        let account = try Account()
        defer { account.remove() }
        let count = ClaudeCodeTranscriptLedger.maxRowsPerRead + 904
        try (0..<count).map { Self.line("msg_\($0)", output: 1, stop: "end_turn") }.joined()
            .write(to: account.transcript, atomically: true, encoding: .utf8)
        let ledger = try account.ledger()
        let first = ledger.read().usage
        #expect(first.count == ClaudeCodeTranscriptLedger.maxRowsPerRead)
        #expect(ledger.takeNotice() != nil && ledger.takeNotice() == nil)
        let second = ledger.read().usage
        #expect(
            second.count == 904
                && second.first?["id"]?.stringValue == "msg_\(ClaudeCodeTranscriptLedger.maxRowsPerRead)")
        #expect(ledger.read().usage.isEmpty)
    }

    static let adapter = ClaudeCodeAdapter(
        executable: URL(filePath: "/x"), cli: InstalledCLI(path: URL(filePath: "/y"), version: nil, source: "path"))

    static func trace(_ account: Account) -> (Traces, TraceSession) {
        let traces = Traces(folder: account.config.appending(path: "traces", directoryHint: .isDirectory))
        let trace = traces.open(task: "t1", lease: "l", engineSession: "s")
        trace.follow(adapter.ledger(stateRoot: account.config, engineSession: session))
        trace.pollInterval = .seconds(60) // the test reads when it means to
        return (traces, trace)
    }

    static func feed(_ trace: TraceSession, _ params: JSONValue) {
        if let row = adapter.modelCall(fromNotification: "_claude/sdkMessage", params: params) {
            trace.ingest(modelCall: row)
        }
    }

    static func modelCalls(_ traces: Traces) -> [JSONValue] {
        traces.session("t1")?.writer.flush()
        return (traces.records(task: "t1") ?? []).filter { $0["kind"]?.stringValue == "model-call" }
    }

    /// The stream's partial rows wait for the transcript's final ones: each call is recorded once, complete, while
    /// the turn runs; the last call's line, which lands just after the result, is waited for at the turn's end.
    @Test func streamRowsWaitForTheTranscriptsFinalRows() async throws {
        let account = try Account()
        defer { account.remove() }
        let (traces, trace) = Self.trace(account)
        trace.turnStarted(prompt: nil)
        Self.feed(trace, ClaudeCodeUsageTests.assistant("msg_a", output: 2))
        Self.feed(trace, ClaudeCodeUsageTests.assistant("msg_a", output: 2)) // its next content block
        Self.feed(trace, ClaudeCodeUsageTests.assistant("msg_b", output: 2))
        #expect(trace.progress.turnModelCalls == 2) // held rows count toward the turn's limit
        try account.append(
            Self.line("msg_a", output: 321) + Self.line("msg_a", block: "tool_use", output: 321), to: account.transcript
        )
        await trace.pollLedger()
        let live = Self.modelCalls(traces)
        #expect(live.count == 1)
        #expect(live.first?["output"]?.intValue == 321 && live.first?["outputPartial"] == JSONValue.bool(false))
        #expect(live.first?["basis"]?.stringValue == "engine-transcript")

        Self.feed(
            trace, ClaudeCodeUsageTests.result(input: 6, output: 450, cacheRead: 1800, cacheWrite: 80, cost: 0.002))
        let late = Task {
            try? await Task.sleep(for: .milliseconds(60))
            try? account.append(Self.line("msg_b", output: 123, stop: "end_turn"), to: account.transcript)
        }
        let turn = await trace.turnEnded(stopReason: "end_turn", usage: nil)
        await late.value
        #expect(turn["modelCalls"]?.intValue == 2)
        #expect(turn["callLedger"]?["output"]?.intValue == 444) // every call's final count
        #expect(turn["ledger"]?["output"]?.intValue == 450) // the engine's totals, side calls included
        #expect(turn["basis"]?.stringValue == "engine-turn-totals")
        let calls = Self.modelCalls(traces)
        #expect(calls.map { $0["output"]?.intValue } == [321, 123])
        #expect(calls.allSatisfy { $0["outputPartial"] == JSONValue.bool(false) })
        traces.close(task: "t1")
    }

    /// No transcript line in time: the stream's rows go out as they are, partial, once their thread's next call has
    /// begun (after `holdAfterNext`) or at the turn's end (after `finalGrace`). A subagent's calls are a thread of
    /// their own, so the session's next call doesn't hurry them. With nothing read at all, later rows aren't held.
    @Test func withoutTheTranscriptStreamRowsGoOutPartial() async throws {
        let account = try Account()
        defer { account.remove() }
        let (traces, trace) = Self.trace(account)
        trace.holdAfterNext = .zero
        trace.finalGrace = .milliseconds(50)
        trace.turnStarted(prompt: nil)
        func subagent(_ id: String) -> JSONValue {
            ClaudeCodeUsageTests.assistant(id, output: 3).setting(
                "message",
                to: (ClaudeCodeUsageTests.assistant(id, output: 3)["message"] ?? [:]).setting(
                    "parent_tool_use_id", to: "toolu_1"))
        }
        Self.feed(trace, ClaudeCodeUsageTests.assistant("msg_a", output: 2))
        Self.feed(trace, subagent("msg_s1"))
        Self.feed(trace, ClaudeCodeUsageTests.assistant("msg_b", output: 2)) // msg_a has ended
        await trace.pollLedger()
        let early = Self.modelCalls(traces)
        #expect(early.map { $0["output"]?.intValue } == [2])
        #expect(early.first?["outputPartial"] == JSONValue.bool(true))
        #expect(early.first?["basis"]?.stringValue == "engine-stream")

        // Given up on with nothing read: the next calls are recorded at once, and the turn's end doesn't wait.
        Self.feed(trace, ClaudeCodeUsageTests.assistant("msg_c", output: 2))
        #expect(Self.modelCalls(traces).count == 2)
        trace.finalGrace = .seconds(30)
        let turn = await trace.turnEnded(stopReason: "end_turn", usage: nil)
        #expect(turn["modelCalls"]?.intValue == 4)
        #expect(Self.modelCalls(traces).allSatisfy { $0["outputPartial"] == JSONValue.bool(true) })

        // Once the transcript gives rows again, rows are held again.
        try account.append(Self.line("msg_c", output: 50, stop: "end_turn"), to: account.transcript)
        trace.turnStarted(prompt: nil)
        await trace.pollLedger()
        Self.feed(trace, ClaudeCodeUsageTests.assistant("msg_d", output: 2))
        #expect(Self.modelCalls(traces).count == 4)
        try account.append(Self.line("msg_d", output: 60, stop: "end_turn"), to: account.transcript)
        let next = await trace.turnEnded(stopReason: "end_turn", usage: nil)
        #expect(next["ledger"]?["output"]?.intValue == 60)
        #expect(Self.modelCalls(traces).last?["outputPartial"] == JSONValue.bool(false))
        traces.close(task: "t1")
    }

    /// A turn Agneta stopped (a limit: `max_turn_requests` for maxTurns) isn't waited for, and a session ended
    /// mid-turn records what was still held.
    @Test func cutOffTurnsAndClosedSessionsDontWaitOrLoseCalls() async throws {
        let account = try Account()
        defer { account.remove() }
        let (traces, trace) = Self.trace(account)
        trace.finalGrace = .seconds(30)
        try account.append(Self.line("msg_0", output: 1, stop: "end_turn"), to: account.transcript)
        trace.turnStarted(prompt: nil)
        await trace.pollLedger() // the transcript is there
        Self.feed(trace, ClaudeCodeUsageTests.assistant("msg_a", output: 2))
        let started = ContinuousClock.now
        let turn = await trace.turnEnded(stopReason: "max_turn_requests", usage: nil, cutOff: true)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(turn["modelCalls"]?.intValue == 2)

        trace.turnStarted(prompt: nil)
        Self.feed(trace, ClaudeCodeUsageTests.assistant("msg_b", output: 2))
        #expect(Self.modelCalls(traces).count == 2) // held
        traces.close(task: "t1")
        let calls = (traces.records(task: "t1") ?? []).filter { $0["kind"]?.stringValue == "model-call" }
        #expect(calls.map { $0["outputPartial"] } == [.bool(false), .bool(true), .bool(true)])
    }
}
