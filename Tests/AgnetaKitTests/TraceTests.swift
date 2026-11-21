// Task trace building blocks: secret masking, line format, ordering, and
// dropping under pressure (docs/DIAGNOSTICS.md).
import Foundation
import Testing

@testable import AgnetaKit

@Suite struct TraceTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "agneta-trace-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func records(_ file: URL) throws -> [JSONValue] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try JSONCoding.decode(Data($0.utf8))
        }
    }

    @Test func sharedEngineStderrStaysOutOfTaskTraces() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let traces = Traces(folder: folder)
        let shared = EngineKeys.shared(account: "account", engine: "goose")
        _ = traces.open(task: "first", lease: shared, engineSession: "one")
        traces.stderr(lease: shared, line: "before second task")
        _ = traces.open(task: "second", lease: shared, engineSession: "two")
        traces.stderr(lease: shared, line: "during both tasks")
        traces.close(task: "first")
        traces.stderr(lease: shared, line: "after first task")
        traces.close(task: "second")
        _ = traces.open(task: "dedicated", lease: "account/dedicated", engineSession: "three")
        traces.stderr(lease: "account/dedicated", line: "dedicated output")
        traces.close(task: "dedicated")

        for task in ["first", "second", "dedicated"] {
            let lines = try records(traces.file(for: task)).filter { $0["type"] == "stderr" }
            #expect(lines.compactMap { $0["text"]?.stringValue } == (task == "dedicated" ? ["dedicated output"] : []))
        }
    }

    @Test func masksSecretsButNotUsage() {
        let mask = SecretMask()
        mask.register("app-token-1234567890")
        let value: JSONValue = [
            "headers": [["name": "Authorization", "value": "Bearer abcdefghijklmnop"]],
            "api_key": "anything", "refresh_token": "r-123",
            "text":
                "use sk-ant-REDACTED-abcdefghijkl and app-token-1234567890 then eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.c2lnbmF0dXJlcw",
            "usage": ["inputTokens": 42, "cache_read_tokens": 3, "outputTokens": 7]
        ]
        let masked = mask.mask(value)
        #expect(masked["headers"]?.arrayValue?.first?["value"]?.stringValue == SecretMask.replacement)
        #expect(masked["api_key"]?.stringValue == SecretMask.replacement)
        #expect(masked["refresh_token"]?.stringValue == SecretMask.replacement)
        let text = masked["text"]?.stringValue ?? ""
        #expect(!text.contains("sk-ant") && !text.contains("app-token-1234567890") && !text.contains("eyJhbGci"))
        #expect(text.hasPrefix("use ") && text.contains(" then "))
        #expect(masked["usage"] == value["usage"]) // token counts aren't secrets
    }

    @Test func linesHaveAFixedHeaderAndEscapeText() throws {
        let line = String(
            decoding: TraceJSON.line(
                header: [("v", 1), ("seq", 7)], fields: ["b": "x\n\"y\"\u{1}", "a": [1.5, .null, true]]), as: UTF8.self)
        #expect(line == #"{"v":1,"seq":7,"a":[1.5,null,true],"b":"x\n\"y\"\u0001"}"# + "\n")
        #expect(try JSONCoding.decode(Data(line.utf8))["b"]?.stringValue == "x\n\"y\"\u{1}")
    }

    /// A turn can end after its task's trace was closed (Stop on an engine that stopped responding): flushing or
    /// closing a closed trace asked the closed file for its descriptor, which raises an exception Swift can't catch,
    /// and took Agneta down (seen in CI). Now it does nothing.
    @Test func aClosedTraceCanBeFlushedAndClosedAgain() throws {
        let folder = try folder()
        let writer = TraceWriter(task: "closed", file: folder.appending(path: "closed.jsonl"), mask: SecretMask())
        writer.record("event", ["kind": "turn", "n": 1])
        writer.close()
        writer.flush()
        writer.close()
        writer.record("event", ["kind": "turn", "n": 2])
        writer.flush()
        let lines = try String(contentsOf: folder.appending(path: "closed.jsonl"), encoding: .utf8).split(
            separator: "\n")
        #expect(lines.count == 1)
    }

    @Test func concurrentRecordsAreWrittenInSequenceOrder() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = TraceWriter(task: "t1", file: folder.appending(path: "t1.jsonl"), mask: SecretMask())
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for index in 0..<250 {
                        // A large record now and then, so encoding times differ.
                        let payload: JSONValue =
                            index % 50 == 0 ? .string(String(repeating: "x", count: 100_000)) : .int(Int64(index))
                        writer.record("event", ["kind": "test", "worker": .int(Int64(worker)), "payload": payload])
                    }
                }
            }
        }
        writer.close()
        let seqs = try records(folder.appending(path: "t1.jsonl")).compactMap { $0["seq"]?.intValue }
        #expect(seqs == Array(1...2000))
    }

    @Test func dropsOnlyDroppableRecordsPastTheCapAndSaysSo() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = TraceWriter(
            task: "t2", file: folder.appending(path: "t2.jsonl"), mask: SecretMask(),
            limits: .init(maxBytes: 2_000, maxPending: 10_000))
        for index in 0..<200 {
            writer.record(
                "acp", ["leg": "engine→agneta", "msg": .string(String(repeating: "r", count: 100))], droppable: true)
            writer.record("event", ["kind": "tool-call", "n": .int(Int64(index))])
            if index == 20 { writer.flush() } // let the byte count catch up
        }
        writer.close()
        let all = try records(folder.appending(path: "t2.jsonl"))
        #expect(all.filter { $0["type"]?.stringValue == "event" }.count == 200) // normalized events are never dropped
        #expect(all.filter { $0["type"]?.stringValue == "acp" }.count < 200)
        #expect(all.contains { $0["event"]?.stringValue == "trace-truncated" })
        #expect(all.contains { $0["event"]?.stringValue == "dropped" && ($0["records"]?.intValue ?? 0) > 0 })
        let seqs = all.compactMap { $0["seq"]?.intValue }
        #expect(seqs == Array(1...Int64(seqs.count))) // drops leave no gaps
        let mode =
            try FileManager.default.attributesOfItem(
                atPath: folder.appending(path: "t2.jsonl").path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}

@Suite struct TraceSummaryTests {
    static let records: [JSONValue] = [
        [
            "type": "meta", "app": ["name": "Example App"], "account": ["label": "Claude", "billing": "subscription"],
            "engine": ["info": ["name": "goose", "version": "1.59.2"], "dedicated": true],
            "policy": ["tools": "workspace", "network": "none"],
            "request": ["cwd": "/w"], "instructions": "secret plan"
        ],
        ["type": "event", "kind": "prompt", "prompt": [["type": "text", "text": "model the knee"]]],
        [
            "type": "event", "kind": "tool-call", "call": "c1", "tool": "echo", "extension": "app",
            "name": "echo · knee", "input": ["text": "knee"]
        ],
        [
            "type": "event", "kind": "tool-result", "call": "c1", "ms": 40, "isError": false,
            "content": [["type": "text", "text": "knee"]]
        ],
        ["type": "event", "kind": "tool-call", "call": "c2", "tool": "echo", "extension": "app", "name": "echo · x"],
        ["type": "event", "kind": "tool-result", "call": "c2", "ms": 60.5, "isError": true],
        ["type": "event", "kind": "tool-call", "call": "c3", "tool": "shell", "extension": "developer"],
        ["type": "event", "kind": "model-call", "input": 100, "output": 10, "cacheRead": 80, "compaction": false],
        ["type": "event", "kind": "model-call", "input": 50, "output": 5, "cacheRead": 0, "compaction": true],
        [
            "type": "event", "kind": "turn", "n": 1, "stopReason": "end_turn", "ms": 900, "modelCalls": 2,
            "ledger": ["input": 150, "output": 15], "cost": 0.25
        ],
        ["type": "shell", "command": "rm -rf x", "exit": 1],
        ["type": "permission", "decision": "allowed-by-policy"],
        ["type": "lifecycle", "event": "stop", "by": "user"],
        ["type": "end"]
    ]

    @Test func addsUpATask() {
        let s = TraceSummary(records: Self.records)
        #expect(s.app == "Example App" && s.billing == "subscription" && s.engine == "goose 1.59.2" && s.dedicated)
        #expect(s.toolCalls == 3 && s.unfinishedToolCalls == 1)
        #expect(s.toolStats.map(\.name) == ["app/echo"])
        #expect(
            s.toolStats.first?.errors == 1 && s.toolStats.first?.totalMs == 100.5 && s.toolStats.first?.p95Ms == 60.5)
        #expect(s.modelCalls == 2 && s.input == 150 && s.cacheRead == 80 && s.compactions == 1)
        #expect(s.turns.first?.modelCalls == 2 && s.cost == 0.25)
        #expect(s.shellCommands == 1 && s.shellFailures == 1 && s.permissions == ["allowed-by-policy": 1])
        #expect(s.lifecycle.count == 1 && s.ended && s.records == Self.records.count)
    }

    @Test func redactedExportsKeepStructureButNoContent() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "agneta-export-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try TraceExport.write(Self.records, to: file, redactContent: true)
        let text = try String(contentsOf: file, encoding: .utf8)
        // Content, names and paths go: the app's name, the account's label, the working folder, tool names.
        for secret in [
            "model the knee", "secret plan", "rm -rf", "echo · knee", "\"knee\"", "Example App", "\"Claude\"", "\"/w\"",
            "\"echo\""
        ] {
            #expect(!text.contains(secret), "\(secret)")
        }
        let lines = text.split(separator: "\n").compactMap { try? JSONCoding.decode(Data($0.utf8)) }
        #expect(lines.count == Self.records.count)
        // Structure, timing and what's structural stay; one tool keeps one token within the export.
        #expect(
            lines[2]["tool"]?.stringValue?.hasPrefix("‹name ") == true && lines[2]["tool"] == lines[4]["tool"]
                && lines[2]["tool"] != lines[6]["tool"])
        #expect(
            lines[3]["ms"]?.intValue == 40 && lines[9]["stopReason"]?.stringValue == "end_turn"
                && lines[11]["decision"]?.stringValue == "allowed-by-policy")
        #expect(
            lines[0]["engine"]?["info"]?["name"]?.stringValue == "goose"
                && lines[0]["account"]?["billing"]?.stringValue == "subscription")
        #expect(lines[1]["prompt"]?.stringValue?.hasPrefix("‹content removed") == true)
        // Content inside lists goes too.
        let nested = TraceRedactor().redact([
            "kind": "plan", "list": [["text": "secret step"], ["error": "secret error"]]
        ])
        var encoded = ""
        TraceJSON.encode(nested, into: &encoded)
        #expect(!encoded.contains("secret"))
    }

    /// Exporting from the trace file, record by record, writes what exporting the records in memory writes.
    @Test func aStreamedExportMatchesTheRecords() throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "agneta-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let trace = folder.appending(path: "trace.jsonl")
        try TraceExport.write(Self.records, to: trace, redactContent: false)
        for redact in [false, true] {
            let streamed = folder.appending(path: "streamed-\(redact).jsonl"),
                whole = folder.appending(path: "whole-\(redact).jsonl")
            try TraceExport.write(trace: trace, to: streamed, redactContent: redact)
            try TraceExport.write(Self.records, to: whole, redactContent: redact)
            // Tool names are tokens salted per export: the same up to the token.
            func normalized(_ file: URL) throws -> String {
                try String(contentsOf: file, encoding: .utf8).replacingOccurrences(
                    of: "‹name [0-9a-f]{8}›", with: "‹name›", options: .regularExpression)
            }
            #expect(try normalized(streamed) == normalized(whole))
            #expect(
                (try FileManager.default.attributesOfItem(atPath: streamed.path(percentEncoded: false))[
                    .posixPermissions] as? Int) == 0o600)
        }
        // No trace, no file.
        let missing = folder.appending(path: "missing.jsonl")
        #expect(throws: (any Error).self) {
            try TraceExport.write(trace: folder.appending(path: "none.jsonl"), to: missing, redactContent: true)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path(percentEncoded: false)))
    }
}

@Suite struct OperationalLogTests {
    @Test func logsEventsRotatesAndMasks() throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "agneta-log-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = OperationalLog(folder: folder, maxBytes: 600)
        for n in 0..<12 { log.log("turn-ended", ["task": .string("s_\(n)"), "stopReason": "end_turn"]) }
        log.error("sign-in-failed", ["reason": "Bearer abcdefghijklmnopqrstu"])
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
        #expect(files == ["agneta.1.jsonl", "agneta.2.jsonl", "agneta.jsonl"]) // rotated, at most three files
        let tail = log.tail(3)
        #expect(tail.count == 3 && tail.last?.contains(#""level":"error""#) == true)
        #expect(tail.last?.hasPrefix(#"{"t":""#) == true && !(tail.last ?? "").contains("abcdefghijkl"))
        let mode =
            try FileManager.default.attributesOfItem(atPath: log.file.path(percentEncoded: false))[.posixPermissions]
            as? Int
        #expect(mode == 0o600)
    }
}

/// Traces stay bounded and honest: hard caps, oversize records, unwritable files, streamed pages and live overflow.
@Suite struct TraceBoundsTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "agneta-bounds-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func lines(_ file: URL) throws -> [JSONValue] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try JSONCoding.decode(Data($0.utf8))
        }
    }

    /// Past the hard cap only the note that says so and the task's end go in; everything else is counted.
    @Test func theHardCapStopsEverythingButTheEnd() throws {
        let file = try folder().appending(path: "t.jsonl")
        let writer = TraceWriter(
            task: "t", file: file, mask: SecretMask(), limits: .init(maxBytes: 1_000, maxTotalBytes: 3_000))
        for index in 0..<200 {
            writer.record(
                "event",
                ["kind": "tool-result", "n": .int(Int64(index)), "content": .string(String(repeating: "x", count: 100))]
            )
        }
        writer.record("end", [:])
        writer.close()
        let records = try lines(file)
        #expect(records.contains { $0["event"]?.stringValue == "trace-full" })
        #expect(records.last?["type"]?.stringValue == "end")
        #expect(records.filter { $0["kind"]?.stringValue == "tool-result" }.count < 40)
        #expect(records.map { $0["seq"]?.intValue ?? 0 } == (1...Int64(records.count)).map { $0 }) // still gapless
    }

    /// A record past the per-record cap is written as a stub that keeps what identifies it, and its size.
    @Test func anOversizeRecordBecomesAStub() throws {
        let file = try folder().appending(path: "t.jsonl")
        let writer = TraceWriter(task: "t", file: file, mask: SecretMask(), limits: .init(maxRecordBytes: 2_000))
        writer.record(
            "event", ["kind": "tool-result", "call": "c1", "content": .string(String(repeating: "y", count: 10_000))])
        writer.close()
        let record = try #require(try lines(file).first)
        #expect(record["kind"]?.stringValue == "tool-result" && record["call"]?.stringValue == "c1")
        #expect(record["content"] == nil && (record["oversize"]?.intValue ?? 0) > 10_000)
    }

    /// A trace that can't be written says so instead of pretending to be whole.
    @Test func anUnwritableTraceReportsAProblem() throws {
        let directory = try folder() // a folder where the file should be: it can't be opened for writing
        let writer = TraceWriter(task: "t", file: directory, mask: SecretMask())
        #expect(writer.problem != nil)
        writer.record("event", ["kind": "prompt"]) // ignored, not a crash
        writer.close()
    }

    /// Pages are capped by size as well as count, always hold at least one record, follow on from the previous
    /// page, and are complete only at the trace's end.
    /// A new task's `meta` is its trace's first record: what `prepare` writes happens before the engine session leads
    /// to the task, so no engine message can be attributed ahead of it. (CI found `acp` records before `meta` twice
    /// on 2026-11-18, when meta was written after the trace was registered.)
    @Test func metaComesBeforeAnythingTheEngineSends() async throws {
        let traces = Traces(folder: try folder())
        let session = traces.open(task: "t", lease: "l", engineSession: "e") { trace in
            #expect(traces.task(lease: "l", engineSession: "e") == nil && traces.session("t") == nil)
            trace.writer.record("meta", ["format": "agneta/trace"])
        }
        #expect(traces.task(lease: "l", engineSession: "e") == "t")
        session.writer.record("acp", ["leg": "engine→agneta"])
        traces.close(task: "t")
        #expect(try lines(traces.file(for: "t")).map { $0["type"]?.stringValue } == ["meta", "acp"])
    }

    /// A resumed task goes on from what it had used: the cost its limits count, and its model calls' numbering,
    /// whether it last finished a turn or stopped in the middle of one.
    @Test func aResumedTraceKeepsItsCostAndCallCount() async throws {
        let traces = Traces(folder: try folder())
        let first = traces.open(task: "t", lease: "l", engineSession: "e")
        first.turnStarted(prompt: nil)
        first.ingest(modelCall: ["id": "a", "model": "m", "cost": 0.25])
        _ = await first.turnEnded(stopReason: "end_turn", usage: nil)
        first.turnStarted(prompt: nil)
        first.ingest(modelCall: ["id": "b", "model": "m", "cost": 0.5]) // stopped mid-turn: no turn record follows
        traces.close(task: "t")
        let resumed = traces.open(task: "t", lease: "l2", engineSession: "e")
        #expect(resumed.progress.taskCost == 0.75)
        resumed.turnStarted(prompt: nil)
        resumed.ingest(modelCall: ["id": "c", "model": "m", "cost": 0.125])
        #expect(resumed.progress.taskCost == 0.875)
        traces.close(task: "t")
        let calls = try lines(traces.file(for: "t")).filter { $0["kind"]?.stringValue == "model-call" }
        #expect(calls.map { $0["n"]?.intValue } == [1, 2, 3])
    }

    /// A turn's summary counts the rows a poll still in flight has read: the turn's end waits for that poll
    /// before its own last read, since the ledger hands each row out only once.
    @Test func aPollInFlightIsCountedInItsTurn() async throws {
        final class SlowLedger: UsageLedger, @unchecked Sendable {
            let reading = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var handedOut = false
            func read() -> (messages: [[String: JSONValue]], usage: [[String: JSONValue]], problem: String?) {
                guard
                    lock.withLock({ () -> Bool in
                        defer { handedOut = true }; return !handedOut
                    })
                else { return ([], [], nil) }
                reading.signal()
                release.wait() // the poll is in flight: it has its row but hasn't counted it
                return ([], [["id": "1", "model": "m", "cost": 0.5]], nil)
            }
        }
        let traces = Traces(folder: try folder())
        let session = traces.open(task: "t", lease: "l", engineSession: "e")
        let ledger = SlowLedger()
        session.follow(ledger)
        session.pollInterval = .milliseconds(10)
        session.turnStarted(prompt: nil)
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                ledger.reading.wait(); done.resume()
            }
        }
        let ended = Task { await session.turnEnded(stopReason: "end_turn", usage: nil) }
        try await Task.sleep(for: .milliseconds(100))
        ledger.release.signal()
        let summary = await ended.value
        #expect(summary["modelCalls"]?.intValue == 1 && summary["cost"] == .double(0.5))
        traces.close(task: "t")
    }

    /// The trace is read backwards in 1 MB chunks: a record cut by a chunk's edge, or behind a line longer than a
    /// chunk, is still found.
    @Test func usageIsFoundAcrossChunkEdges() throws {
        let folder = try folder()
        let call = #"{"v":1,"seq":1,"turn":1,"type":"event","kind":"model-call","n":4,"taskCost":1.5}"# + "\n"
        for (index, fillerLength) in [(1 << 20) - 10, 5 << 19].enumerated() {
            let head = #"{"v":1,"seq":2,"turn":1,"type":"event","kind":"tool-result","content":""#, tail = "\"}\n"
            let filler = head + String(repeating: "x", count: fillerLength - head.utf8.count - tail.utf8.count) + tail
            let file = folder.appending(path: "t\(index).jsonl")
            try Data((call + filler).utf8).write(to: file)
            let found = TraceWriter.usageSoFar(of: file)
            #expect(found.taskCost == 1.5 && found.modelCalls == 4, "filler \(fillerLength): \(found)")
        }
    }

    @Test func pagesStreamInOrderAndFinish() throws {
        let root = try folder()
        let traces = Traces(folder: root)
        let session = traces.open(task: "t", lease: "l", engineSession: "e")
        for index in 0..<50 {
            session.writer.record(
                "event",
                ["kind": "tool-result", "n": .int(Int64(index)), "content": .string(String(repeating: "z", count: 300))]
            )
        }
        session.writer.record("end", [:])
        traces.close(task: "t")
        var after: Int64 = 0
        var seen: [Int64] = []
        var pages = 0
        while true {
            let page = try #require(
                traces.read(task: "t", after: after, types: Traces.defaultTypes, limit: 500, maxBytes: 2_000))
            #expect(!page.records.isEmpty || page.complete)
            seen += page.records.compactMap { $0["seq"]?.intValue }
            pages += 1
            guard let next = page.next else { #expect(page.complete); break }
            after = next
            if pages > 100 { Issue.record("paging didn't finish"); break }
        }
        #expect(seen == (1...51).map { Int64($0) } && pages > 5)
    }

    /// Live delivery to an app that can't keep up stops at its limit and says where, without a gap.
    @Test func liveDeliveryOverflowsCleanly() async throws {
        let sent = Recorder()
        let stopped = Recorder()
        let forwarder = TraceForwarder(
            include: ["event"], limit: 3,
            send: { records in
                for record in records { sent.add("\(record["seq"]?.intValue ?? 0)") }
            }, overflow: { after in stopped.add("\(after)") })
        for seq in 1...5 { forwarder.accept(["type": "event", "seq": .int(Int64(seq))]) }
        await forwarder.finish()
        #expect(sent.all == ["1", "2", "3"] && stopped.all == ["3"])
    }
}
