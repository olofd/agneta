// The parts of a task trace that interpret other programs' output: the ACP
// normalizer (upserts, timing, first token), frame attribution (responses
// matched to their requests), and the reader for Goose's own database, against
// a fixture with goose-acp 1.59.2's measured schema (docs/DIAGNOSTICS.md).
import Foundation
import GRDB
import Testing
@testable import AgnetaKit

@Suite struct TraceNormalizerTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "agneta-norm-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func read(_ traces: Traces, _ task: String) throws -> [JSONValue] {
        try traces.text(of: task).split(separator: "\n").map { try JSONCoding.decode(Data($0.utf8)) }
    }

    private func events(_ records: [JSONValue], _ kind: String) -> [JSONValue] {
        records.filter { $0["type"]?.stringValue == "event" && $0["kind"]?.stringValue == kind }
    }

    @Test func toolCallsAreUpsertsWithTaskScopedIdsAndTiming() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let traces = Traces(folder: folder)
        let session = traces.open(task: "t", lease: "acct/x", engineSession: "e1")
        session.identify(with: GooseAdapter(executable: URL(filePath: "/usr/bin/false")))
        session.turnStarted(prompt: [["type": "text", "text": "go"]])
        // The first sighting can be a placeholder; input and title follow in an update.
        session.update(["sessionUpdate": "tool_call", "toolCallId": "call_1", "status": "pending",
                        "_meta": ["goose": ["toolCall": ["toolName": "echo", "extensionName": "app"], "messageId": "resp-1"]]])
        session.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Calling"]])
        session.update(["sessionUpdate": "tool_call_update", "toolCallId": "call_1", "rawInput": ["text": "hi"], "title": "echo · hi"])
        try await Task.sleep(for: .milliseconds(20))
        session.update(["sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "completed",
                        "content": [["type": "content", "content": ["type": "text", "text": "hi"]]]])
        // Engines reuse ids across turns: the same engine id later is a new call.
        session.update(["sessionUpdate": "tool_call", "toolCallId": "call_1", "title": "swatch", "rawInput": [:]])
        session.update(["sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "failed", "content": [["type": "content", "content": ["type": "text", "text": "boom"]]]])
        session.update(["sessionUpdate": "usage_update", "size": 1000, "used": 120])
        session.update(["sessionUpdate": "session_info_update"])
        await session.turnEnded(stopReason: "end_turn", usage: ["inputTokens": 10, "outputTokens": 2])
        traces.close(task: "t")

        let records = try read(traces, "t")
        let calls = events(records, "tool-call"), results = events(records, "tool-result")
        #expect(calls.map { $0["call"]?.stringValue } == ["c1", "c2"])
        #expect(calls.first?["tool"]?.stringValue == "echo" && calls.first?["extension"]?.stringValue == "app")
        #expect(calls.first?["message"]?.stringValue == "resp-1")
        #expect(events(records, "tool-input").first?["input"]?["text"]?.stringValue == "hi")
        #expect(results.map { $0["call"]?.stringValue } == ["c1", "c2"])
        #expect(results.map { $0["isError"]?.boolValue } == [false, true])
        let ms: Double = switch results.first?["ms"] { case .double(let v)?: v; case .int(let v)?: Double(v); default: 0 }
        #expect(ms >= 15)
        #expect(results.first?["bytes"]?.intValue ?? 0 > 0)
        #expect(events(records, "usage").first?["cumulative"]?.boolValue == true)
        // Only kinds Agneta understands become events; the rest stays in the raw lines.
        #expect(Set(records.compactMap { $0["kind"]?.stringValue }) == ["prompt", "tool-call", "text-delta", "tool-input", "tool-result", "usage", "turn"])
        let turn = try #require(events(records, "turn").first)
        #expect(turn["msToFirstToken"] != .null)
        #expect(turn["usage"]?["inputTokens"]?.intValue == 10)
        #expect(turn["cost"] == .null) // no known cost stays unknown
        #expect(records.allSatisfy { $0["type"]?.stringValue == "event" ? $0["turn"]?.intValue == 1 : true })
    }

    @Test func framesAreAttributedBySessionOrByTheRequestTheyAnswer() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let traces = Traces(folder: folder)
        _ = traces.open(task: "t", lease: "acct/shared", engineSession: "e1")
        _ = traces.open(task: "u", lease: "acct/shared", engineSession: "e2")
        let engine = traces.engineAttributor(lease: "acct/shared")
        func frame(_ value: JSONValue) -> Data { Data(String(decoding: try! JSONCoding.encode(value), as: UTF8.self).utf8) }
        engine.frame(.sent, frame(["jsonrpc": "2.0", "id": 7, "method": "session/prompt", "params": ["sessionId": "e1"]]))
        engine.frame(.received, frame(["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "e2", "update": [:]]]))
        engine.frame(.received, frame(["jsonrpc": "2.0", "id": 7, "result": ["stopReason": "end_turn"]])) // answers t's request
        engine.frame(.received, frame(["jsonrpc": "2.0", "id": 3, "method": "session/request_permission", "params": ["sessionId": "e2"]]))
        engine.frame(.sent, frame(["jsonrpc": "2.0", "id": 3, "result": ["outcome": "x"]]))                 // answers u's request
        engine.frame(.received, frame(["jsonrpc": "2.0", "id": 99, "result": [:]]))                        // unknown: dropped
        engine.frame(.received, Data("not json".utf8))
        let app = traces.appAttributor()
        app.frame(.received, frame(["jsonrpc": "2.0", "id": 1, "method": "session/prompt", "params": ["sessionId": "t"]]))
        app.frame(.received, frame(["jsonrpc": "2.0", "id": 2, "method": "session/prompt", "params": ["sessionId": "someone-else"]]))
        traces.close(task: "t")
        traces.close(task: "u")

        let t = try read(traces, "t"), u = try read(traces, "u")
        #expect(t.map { $0["leg"]?.stringValue } == ["agneta→engine", "engine→agneta", "app→agneta"])
        #expect(t[1]["msg"]?["result"]?["stopReason"]?.stringValue == "end_turn")
        #expect(u.map { $0["leg"]?.stringValue } == ["engine→agneta", "engine→agneta", "agneta→engine"])
        #expect(u.last?["msg"]?["id"]?.intValue == 3)
    }

    /// goose-acp 1.59.2's tables, as measured (only what the reader touches, plus neighbours).
    private func gooseDatabase(at file: URL) throws -> DatabaseQueue {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: file.path(percentEncoded: false))
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', working_dir TEXT NOT NULL);
                CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, message_id TEXT, session_id TEXT NOT NULL REFERENCES sessions(id),
                    role TEXT NOT NULL, content_json TEXT NOT NULL, created_timestamp INTEGER NOT NULL,
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP, tokens INTEGER, metadata_json TEXT);
                CREATE TABLE usage_ledger (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    created_timestamp INTEGER NOT NULL, model TEXT, input_tokens INTEGER, output_tokens INTEGER, total_tokens INTEGER,
                    cache_read_tokens INTEGER, cache_write_tokens INTEGER, cost REAL, cost_source TEXT, is_compaction INTEGER DEFAULT 0);
                INSERT INTO sessions (id, working_dir) VALUES ('e1', '/w'), ('other', '/w');
                """)
        }
        try queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
        return queue
    }

    private func addCall(_ queue: DatabaseQueue, session: String = "e1", input: Int, output: Int, cacheRead: Int? = nil, cost: Double? = nil, compaction: Bool = false) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO usage_ledger (session_id, created_timestamp, model, input_tokens, output_tokens, total_tokens, cache_read_tokens, cost, cost_source, is_compaction)
                VALUES (?, 1794927221, 'gpt-x', ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [session, input, output, input + output, cacheRead, cost, cost == nil ? nil : "provider", compaction ? 1 : 0])
            try db.execute(sql: "INSERT INTO messages (session_id, role, content_json, created_timestamp, message_id) VALUES (?, 'assistant', ?, 1794927221, 'm')",
                           arguments: [session, #"[{"type":"text","text":"ok"}]"#])
        }
    }

    @Test func readsGoosesLedgerIncrementallyPerTurn() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "goose/data/sessions/sessions.db")
        let goose = try gooseDatabase(at: file)
        let traces = Traces(folder: folder.appending(path: "Traces", directoryHint: .isDirectory))
        let session = traces.open(task: "t", lease: "acct/x", engineSession: "e1")
        session.set(billing: "subscription")
        session.follow(GooseLedgerReader(database: file, session: "e1"))

        session.turnStarted(prompt: nil)
        try addCall(goose, input: 100, output: 10, cacheRead: 80, cost: 0.01)
        try addCall(goose, input: 120, output: 5, cost: 0.02)
        try addCall(goose, session: "other", input: 999, output: 999) // another session in a shared engine
        await session.turnEnded(stopReason: "end_turn", usage: nil)
        session.turnStarted(prompt: nil)
        try addCall(goose, input: 50, output: 50, compaction: true)
        await session.turnEnded(stopReason: "end_turn", usage: nil)
        traces.close(task: "t")

        let records = try read(traces, "t")
        let calls = events(records, "model-call")
        #expect(calls.map { $0["n"]?.intValue } == [1, 2, 3])
        #expect(calls.map { $0["turn"]?.intValue } == [1, 1, 2])
        #expect(calls.allSatisfy { $0["costKind"]?.stringValue == "plan-equivalent" })
        #expect(calls.last?["compaction"]?.boolValue == true)
        let turns = events(records, "turn")
        #expect(turns.map { $0["modelCalls"]?.intValue } == [2, 1])
        #expect(turns.first?["ledger"]?["input"]?.intValue == 220 && turns.first?["ledger"]?["cacheRead"]?.intValue == 80)
        let cost: Double = switch turns.first?["cost"] { case .double(let v)?: v; default: -1 }
        #expect(abs(cost - 0.03) < 1e-9)
        #expect(turns.last?["cost"] == .null) // that call had no cost
        #expect(records.filter { $0["type"]?.stringValue == "engine.message" }.count == 3)
        #expect(!records.contains { $0["type"]?.stringValue == "lifecycle" })
    }

    @Test func anUnknownGooseSchemaIsReportedOnceAndLeftAlone() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "sessions.db")
        let queue = try DatabaseQueue(path: file.path(percentEncoded: false))
        try await queue.write { try $0.execute(sql: "CREATE TABLE messages (id INTEGER PRIMARY KEY); CREATE TABLE usage_ledger (id INTEGER PRIMARY KEY)") }
        let traces = Traces(folder: folder.appending(path: "Traces", directoryHint: .isDirectory))
        let session = traces.open(task: "t", lease: "acct/x", engineSession: "e1")
        session.follow(GooseLedgerReader(database: file, session: "e1"))
        for _ in 0..<3 {
            session.turnStarted(prompt: nil)
            await session.turnEnded(stopReason: "end_turn", usage: nil)
        }
        traces.close(task: "t")
        let records = try read(traces, "t")
        #expect(records.filter { $0["event"]?.stringValue == "engine-db-unavailable" }.count == 1)
        #expect(events(records, "turn").count == 3)
    }

    @Test func aMissingDatabaseIsWaitedForQuietly() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let traces = Traces(folder: folder)
        let session = traces.open(task: "t", lease: "acct/x", engineSession: "e1")
        session.follow(GooseLedgerReader(database: folder.appending(path: "not-yet.db"), session: "e1"))
        session.turnStarted(prompt: nil)
        await session.turnEnded(stopReason: "end_turn", usage: nil)
        traces.close(task: "t")
        let records = try read(traces, "t")
        #expect(!records.contains { $0["type"]?.stringValue == "lifecycle" })
        #expect(events(records, "turn").first?["modelCalls"]?.intValue == 0)
    }

    @Test func deletingTracesRemovesFilesAndBlobs() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let traces = Traces(folder: folder)
        let session = traces.open(task: "gone", lease: "l", engineSession: "e")
        session.writer.record("event", ["kind": "test"])
        traces.close(task: "gone")
        try FileManager.default.createDirectory(at: folder.appending(path: "gone/blobs"), withIntermediateDirectories: true)
        _ = traces.open(task: "kept", lease: "l", engineSession: "e2")
        traces.close(task: "kept")
        traces.delete(tasks: ["gone"])
        #expect(!FileManager.default.fileExists(atPath: traces.file(for: "gone").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "gone").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: traces.file(for: "kept").path(percentEncoded: false)))
    }
}
