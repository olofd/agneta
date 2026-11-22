// What a task's trace adds up to (turns, tools, model calls, Agneta's
// decisions), and its export with or without content. Shared by agneta-diag,
// Settings → Activity and the diagnostics tools.
import CryptoKit
import Foundation

public struct TraceSummary: Sendable {
    public struct Turn: Sendable {
        public var n: Int
        public var stopReason: String
        public var ms: Double?
        public var msToFirstToken: Double?
        public var modelCalls: Int
        public var input: Int
        public var output: Int
        public var cacheRead: Int
        public var cacheWrite: Int
        public var cost: Double?
        public var error: String?
    }

    public struct Tool: Sendable {
        public var name: String
        public var calls: Int
        public var errors: Int
        public var totalMs: Double
        public var p95Ms: Double
    }

    public var app: String?
    public var account: String?
    public var billing: String?
    /// The account's kind (`AccountKind`), when the account still existed.
    public var kind: String?
    public var engine: String?
    public var dedicated: Bool
    public var tools: String?
    public var network: String?
    /// The sandbox mode the task ran in ("contained" or "developer").
    public var sandbox: String?
    public var turns: [Turn] = []
    /// By total time, longest first. Grouped by tool, not title: Goose's titles carry arguments.
    public var toolStats: [Tool] = []
    public var toolCalls = 0
    public var unfinishedToolCalls = 0
    public var modelCalls = 0
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var compactions = 0
    public var shellCommands = 0
    public var shellFailures = 0
    public var shellRefused = 0
    public var permissions: [String: Int] = [:]
    /// Each turn's structured result (docs/APP_PROTOCOL.md, Structured results), from its `final` record: the turn, the
    /// result's name, and its status with the reason, attempts and how many calls were refused.
    public struct Result: Sendable {
        public var turn: Int
        public var name: String
        public var status: String
        public var reason: String?
        public var attempts: Int
        public var refused: Int
    }
    public var results: [Result] = []
    public var lifecycle: [JSONValue] = []
    public var records = 0
    public var ended = false

    public init(records all: [JSONValue]) {
        func events(_ kind: String) -> [JSONValue] {
            all.filter { $0["type"]?.stringValue == "event" && $0["kind"]?.stringValue == kind }
        }
        func number(_ value: JSONValue?) -> Double? {
            switch value {
            case .double(let v)?: v;
            case .int(let v)?: Double(v);
            default: nil
            }
        }
        let meta = all.first { $0["type"]?.stringValue == "meta" }
        app = meta?["app"]?["name"]?.stringValue
        account = meta?["account"]?["label"]?.stringValue
        billing = meta?["account"]?["billing"]?.stringValue
        kind = meta?["account"]?["kind"]?.stringValue
        engine = [meta?["engine"]?["info"]?["name"]?.stringValue, meta?["engine"]?["info"]?["version"]?.stringValue]
            .compactMap { $0 }.joined(separator: " ")
        dedicated = meta?["engine"]?["dedicated"]?.boolValue == true
        tools = meta?["policy"]?["tools"]?.stringValue
        network = meta?["policy"]?["network"]?.stringValue
        sandbox = meta?["policy"]?["sandbox"]?.stringValue
        turns = events("turn").map { turn in
            Turn(
                n: Int(turn["n"]?.intValue ?? 0), stopReason: turn["stopReason"]?.stringValue ?? "?",
                ms: number(turn["ms"]),
                msToFirstToken: number(turn["msToFirstToken"]), modelCalls: Int(turn["modelCalls"]?.intValue ?? 0),
                input: Int(turn["ledger"]?["input"]?.intValue ?? 0),
                output: Int(turn["ledger"]?["output"]?.intValue ?? 0),
                cacheRead: Int(turn["ledger"]?["cacheRead"]?.intValue ?? 0),
                cacheWrite: Int(turn["ledger"]?["cacheWrite"]?.intValue ?? 0),
                cost: number(turn["cost"]), error: turn["error"]?.stringValue)
        }
        var names: [String: String] = [:]
        for call in events("tool-call") {
            guard let id = call["call"]?.stringValue else { continue }
            let tool = [call["extension"]?.stringValue, call["tool"]?.stringValue].compactMap { $0 }.joined(
                separator: "/")
            names[id] = tool.isEmpty ? (call["name"]?.stringValue ?? "?") : tool
        }
        var grouped: [String: (ms: [Double], errors: Int)] = [:]
        for result in events("tool-result") {
            let name = names[result["call"]?.stringValue ?? ""] ?? "?"
            grouped[name, default: ([], 0)].ms.append(number(result["ms"]) ?? 0)
            if result["isError"]?.boolValue == true { grouped[name, default: ([], 0)].errors += 1 }
        }
        toolStats = grouped.map { name, entry in
            let sorted = entry.ms.sorted()
            let p95 =
                sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.95).rounded()))]
            return Tool(
                name: name, calls: entry.ms.count, errors: entry.errors, totalMs: entry.ms.reduce(0, +), p95Ms: p95)
        }.sorted { $0.totalMs > $1.totalMs }
        toolCalls = events("tool-call").count
        unfinishedToolCalls = max(0, toolCalls - events("tool-result").count)
        let models = events("model-call")
        modelCalls = models.count
        // The calls' sums, except for turns whose ledger is the engine's own totals (Claude Code: its per-call
        // output counts are partial, and side calls aren't listed); those turns count by their ledger.
        let totalled = events("turn").filter { $0["basis"]?.stringValue == "engine-turn-totals" }
        let totalledTurns = Set(totalled.compactMap { $0["n"]?.intValue })
        let source =
            models.filter { !totalledTurns.contains($0["turn"]?.intValue ?? -1) } + totalled.compactMap { $0["ledger"] }
        input = source.reduce(0) { $0 + Int($1["input"]?.intValue ?? 0) }
        output = source.reduce(0) { $0 + Int($1["output"]?.intValue ?? 0) }
        cacheRead = source.reduce(0) { $0 + Int($1["cacheRead"]?.intValue ?? 0) }
        cacheWrite = source.reduce(0) { $0 + Int($1["cacheWrite"]?.intValue ?? 0) }
        compactions = models.filter { $0["compaction"]?.boolValue == true }.count
        let shells = all.filter { $0["type"]?.stringValue == "shell" }
        shellCommands = shells.count
        shellFailures = shells.filter { ($0["exit"]?.intValue ?? 0) != 0 || $0["signal"] != nil }.count
        shellRefused = shells.filter { $0["refused"] != nil }.count
        for record in all where record["type"]?.stringValue == "permission" {
            permissions[record["decision"]?.stringValue ?? "?", default: 0] += 1
        }
        let resultRecords = all.filter { $0["type"]?.stringValue == "result" }
        results = resultRecords.filter { $0["event"]?.stringValue == "final" }.map { final in
            let turn = Int(final["turn"]?.intValue ?? 0)
            let report = final["report"]
            return Result(
                turn: turn, name: final["name"]?.stringValue ?? "?", status: report?["status"]?.stringValue ?? "?",
                reason: report?["reason"]?.stringValue, attempts: Int(report?["attempts"]?.intValue ?? 0),
                refused: resultRecords.filter {
                    $0["event"]?.stringValue == "submitted" && $0["answer"]?.stringValue == "refused"
                        && $0["turn"]?.intValue == Int64(turn)
                }.count)
        }
        lifecycle = all.filter { $0["type"]?.stringValue == "lifecycle" }
        records = all.count
        ended = all.last?["type"]?.stringValue == "end"
    }

    /// The task's known cost: the sum of its turns' known costs, or nil if none was known.
    public var cost: Double? {
        let known = turns.compactMap(\.cost)
        return known.isEmpty ? nil : known.reduce(0, +)
    }
}

public enum TraceExport {
    /// Content-bearing fields, removed whole with `redactContent` (their size is kept). Tool titles carry
    /// arguments, so a tool event's `name` and every `title` go too.
    static let contentKeys: Set<String> = [
        "prompt", "delta", "input", "content", "rawOutput", "msg", "instructions", "request",
        "engineResult", "text", "stderrTail", "command", "title", "message", "entries", "configOptions", "error",
        "reason"
    ]

    /// Writes the records as JSON lines, owner-only.
    public static func write(_ records: [JSONValue], to file: URL, redactContent: Bool) throws {
        let redactor = TraceRedactor()
        var text = ""
        for record in records {
            TraceJSON.encode(redactContent ? redactor.redact(record) : record, into: &text)
            text += "\n"
        }
        guard
            FileManager.default.createFile(
                atPath: file.path(percentEncoded: false), contents: Data(text.utf8),
                attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

extension TraceExport {
    /// Writes a trace file's records to `file` as they're read, owner-only: a large trace is never held whole.
    /// A failed export leaves no partial file.
    public static func write(trace: URL, to file: URL, redactContent: Bool) throws {
        let input = try FileHandle(forReadingFrom: trace)
        defer { try? input.close() }
        guard
            FileManager.default.createFile(
                atPath: file.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            var splitter = LineSplitter(limit: 64 << 20)
            let redactor = TraceRedactor()
            func copy(_ lines: [Data]) throws {
                var text = ""
                for line in lines {
                    guard let record = try? JSONCoding.decode(line) else { continue }
                    TraceJSON.encode(redactContent ? redactor.redact(record) : record, into: &text)
                    text += "\n"
                }
                try output.write(contentsOf: Data(text.utf8))
            }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try copy(try splitter.push(chunk)) }
            if let rest = splitter.finish() { try copy([rest]) }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}

extension Traces {
    /// Every record of a task, or nil if it has no trace.
    public func records(task: String) -> [JSONValue]? {
        guard let text = try? String(contentsOf: file(for: task), encoding: .utf8) else { return nil }
        return text.split(separator: "\n").compactMap { try? JSONCoding.decode(Data($0.utf8)) }
    }
}

/// A trace record fit to share: an allow-list, not a list of what to hide. Content-bearing fields are removed whole
/// (their size is kept); then a string stays only where it's structural (a record's type and kind, a status, a
/// decision, a model or engine name), and every other one is removed with its size: app and account names,
/// identifiers, paths, anything a new field brings. Tool and server names become tokens, the same within one export
/// (so per-tool timings still add up) and different in the next (the salt is new each time). Numbers, true and
/// false stay: timings, sizes, counts, tokens and costs are what a bug report needs.
public struct TraceRedactor: Sendable {
    /// Keys whose strings are structural, wherever they are.
    static let structural: Set<String> = [
        "t", "task", "type", "kind", "event", "leg", "status", "stopReason", "decision", "by", "costKind", "costSource",
        "basis",
        "billing", "runner", "toolKind", "limit", "format", "role", "outcome", "optionId", "sessionUpdate", "delivery",
        "call", "engineCall", "model", "models", "stateFormat", "version", "tools", "network", "approval", "ending"
    ]
    /// Places whose strings are structural: the engine's own name in `meta`.
    static let structuralPaths: Set<String> = ["engine.id", "engine.info.name"]
    /// Keys whose strings become tokens: names that show which tool a record is about, not what it did.
    static let tokenized: Set<String> = ["tool", "extension", "server"]

    private let salt: [UInt8]

    public init() {
        salt = SecureRandom.bytes(16)
    }

    public func redact(_ value: JSONValue) -> JSONValue {
        let kind = value["type"] == "event" ? value["kind"]?.stringValue : nil
        return redact(value, path: [], eventKind: kind)
    }

    private func redact(_ value: JSONValue, path: [String], eventKind: String?) -> JSONValue {
        switch value {
        case .array(let items):
            return .array(items.map { redact($0, path: path, eventKind: nil) })
        case .object(let fields):
            let toolEvent = ["tool-call", "tool-input"].contains(fields["kind"]?.stringValue ?? "")
            var out: [String: JSONValue] = [:]
            let usage =
                (eventKind == "model-call" && path.isEmpty)
                || (eventKind == "turn" && (path == ["ledger"] || path == ["callLedger"]))
            for (key, field) in fields {
                if usage && key == "input" && field.intValue != nil {
                    out[key] = field
                } else if TraceExport.contentKeys.contains(key) || (toolEvent && key == "name"), field != .null {
                    var text = ""
                    TraceJSON.encode(field, into: &text)
                    out[key] = .string("‹content removed, \(text.utf8.count) bytes›")
                } else {
                    out[key] = redact(field, path: path + [key], eventKind: eventKind)
                }
            }
            return .object(out)
        case .string(let text):
            guard let key = path.last else { return .string("‹removed, \(text.utf8.count) bytes›") }
            if Self.structural.contains(key) || Self.structuralPaths.contains(path.suffix(3).joined(separator: "."))
                || Self.structuralPaths.contains(path.suffix(2).joined(separator: "."))
            {
                return value
            }
            if Self.tokenized.contains(key) {
                let digest = SHA256.hash(data: Data(salt) + Data(text.utf8)).prefix(4).map {
                    String(format: "%02x", $0)
                }.joined()
                return .string("‹name \(digest)›")
            }
            return .string("‹removed, \(text.utf8.count) bytes›")
        default:
            return value
        }
    }
}
