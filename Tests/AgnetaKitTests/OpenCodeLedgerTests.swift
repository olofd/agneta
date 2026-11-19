// OpenCode's usage rows, read as OpenCode 2.3.0 writes them: a step's assistant row appears when the step starts,
// without tokens, and is filled in when it ends. Each step's usage must be read once, complete.
import Foundation
import GRDB
import Testing
@testable import AgnetaKit

struct OpenCodeLedgerTests {
    @Test func aStepIsReadOnceItEnds() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agneta-opencode-ledger-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "opencode.db")
        let database = try DatabaseQueue(path: file.path(percentEncoded: false))
        try database.write { db in
            try db.execute(sql: "CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL, time_created INTEGER NOT NULL, data TEXT NOT NULL)")
        }
        func insert(_ id: String, _ type: String, _ seq: Int, _ data: String) throws {
            try database.write { db in
                try db.execute(sql: "INSERT INTO session_message VALUES (?, 's1', ?, ?, 1795123280000, ?)", arguments: [id, type, seq, data])
            }
        }
        func complete(_ id: String, cost: Double) throws {
            try database.write { db in
                try db.execute(sql: "UPDATE session_message SET data = ? WHERE id = ?", arguments: [
                    #"{"tokens":{"input":42,"output":7,"reasoning":0,"cache":{"read":0,"write":0}},"cost":\#(cost),"time":{"created":1,"completed":2}}"#, id])
            }
        }
        let reader = OpenCodeLedgerReader(database: file, session: "s1")
        try insert("m1", "user", 1, #"{"time":{"created":1}}"#)
        try insert("m2", "assistant", 2, #"{"time":{"created":1}}"#) // the first step, running
        #expect(reader.read().usage.isEmpty)
        try complete("m2", cost: 0.25)
        try insert("m3", "assistant", 3, #"{"time":{"created":2}}"#) // the second step, running
        let first = reader.read().usage
        #expect(first.count == 1 && first.first?["cost"] == .double(0.25) && first.first?["input_tokens"] == .int(42))
        try complete("m3", cost: 0.5)
        #expect(reader.read().usage.map { $0["cost"] } == [.double(0.5)])
        // A step that never completed (the turn was stopped) is taken as it is once a later row shows it ended.
        try insert("m4", "assistant", 4, #"{"tokens":{"input":5,"output":0},"time":{"created":3}}"#)
        #expect(reader.read().usage.isEmpty)
        try insert("m5", "user", 5, #"{"time":{"created":4}}"#)
        #expect(reader.read().usage.map { $0["input_tokens"] } == [.int(5)])
        #expect(reader.read().usage.isEmpty)
    }
}
