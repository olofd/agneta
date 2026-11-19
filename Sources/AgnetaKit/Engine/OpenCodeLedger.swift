// OpenCode's per-call usage: each assistant message (one per model step) in
// its SQLite `session_message` table carries model, tokens (input without
// cache, output, reasoning, cache read/write) and cost in its JSON `data`.
// Read only, rows newer than those already read; any other layout is reported
// once and left alone.
import Foundation
import GRDB

final class OpenCodeLedgerReader: UsageLedger, @unchecked Sendable {
    let database: URL
    let session: String
    private let lock = NSLock()
    private var queue: DatabaseQueue?
    private var sessionColumn = "session_id"
    private var lastRow: Int64 = 0
    private var disabled = false

    init(database: URL, session: String) {
        self.database = database
        self.session = session
    }

    func read() -> (messages: [[String: JSONValue]], usage: [[String: JSONValue]], problem: String?) {
        lock.withLock {
            guard !disabled, FileManager.default.fileExists(atPath: database.path(percentEncoded: false)) else { return ([], [], nil) }
            do {
                if queue == nil {
                    var configuration = Configuration()
                    configuration.readonly = true
                    configuration.busyMode = .timeout(0.5)
                    let opened = try DatabaseQueue(path: database.path(percentEncoded: false), configuration: configuration)
                    let columns = try opened.read { try Set($0.columns(in: "session_message").map(\.name)) }
                    guard columns.contains("data"), let column = ["session_id", "sessionID", "session"].first(where: columns.contains) else {
                        throw SchemaMismatch()
                    }
                    sessionColumn = column
                    queue = opened
                }
                return try queue!.read { db in
                    var messages: [[String: JSONValue]] = []
                    var usage: [[String: JSONValue]] = []
                    let rows = try Row.fetchAll(db, sql: "SELECT rowid AS agneta_row, * FROM session_message WHERE \(sessionColumn) = ? AND rowid > ? ORDER BY rowid",
                                                arguments: [session, lastRow])
                    for (index, row) in rows.enumerated() {
                        guard let text = row["data"] as String?, let data = try? JSONCoding.decode(Data(text.utf8)) else {
                            lastRow = row["agneta_row"]
                            continue
                        }
                        // Measured on 2.3.0: the role is the `type` column; times are in milliseconds.
                        let role = (row["type"] as String?) ?? data["role"]?.stringValue ?? "?"
                        // A step's row is written when the step starts and filled in when it ends, after the tools it
                        // called ran (its tokens, cost and `time.completed`; measured on 2.3.0). One still running is read
                        // again at the next poll, not taken half-written: its usage would be lost. A later row means it
                        // ended, completed or not.
                        if role == "assistant", data["time"]?["completed"] == nil, index == rows.count - 1 { break }
                        lastRow = row["agneta_row"]
                        let created = (row["time_created"] as Int64?).map { JSONValue.int($0 / 1000) } ?? data["time"]?["created"] ?? .null
                        messages.append(["row": .int(lastRow), "role": .string(role), "content": data["content"] ?? data["parts"] ?? .null,
                                         "meta": .null, "messageId": data["id"] ?? .null, "created": created])
                        guard role == "assistant", let tokens = data["tokens"] else { continue }
                        let model = [data["model"]?["providerID"]?.stringValue ?? data["providerID"]?.stringValue,
                                     data["model"]?["id"]?.stringValue ?? data["modelID"]?.stringValue].compactMap { $0 }.joined(separator: "/")
                        let input = tokens["input"]?.intValue, output = tokens["output"]?.intValue
                        usage.append([
                            "row": .int(lastRow), "created": created, "model": model.isEmpty ? .null : .string(model),
                            "input_tokens": input.map(JSONValue.int) ?? .null, "output_tokens": output.map(JSONValue.int) ?? .null,
                            "total_tokens": (input.flatMap { i in output.map { .int(i + $0) } }) ?? .null,
                            "cache_read_tokens": tokens["cache"]?["read"] ?? .null, "cache_write_tokens": tokens["cache"]?["write"] ?? .null,
                            "reasoning_tokens": tokens["reasoning"] ?? .null,
                            "cost": data["cost"] ?? .null, "cost_source": "opencode", "is_compaction": .int(data["summary"]?.boolValue == true ? 1 : 0),
                        ])
                    }
                    return (messages, usage, nil)
                }
            } catch is SchemaMismatch {
                disabled = true
                return ([], [], "OpenCode's database has a layout this Agneta doesn't know")
            } catch {
                queue = nil
                return ([], [], nil)
            }
        }
    }

    private struct SchemaMismatch: Error {}
}
