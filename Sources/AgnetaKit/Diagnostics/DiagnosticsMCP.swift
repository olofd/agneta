// Diagnostics for agents and tools (docs/DIAGNOSTICS.md): an MCP server over
// Streamable HTTP on loopback, so an agent debugging an app's run, or a
// developer, can ask "which tool calls failed in turn 12" without
// parsing megabytes. Off until the user creates a token; every request needs
// it. Tools read task traces and Agneta's history, and return compact text
// unless asked for JSON.
import CryptoKit
import Foundation

public final class DiagnosticsMCP: @unchecked Sendable {
    public let traces: Traces
    /// Agneta's data root, for engine homes (engine logs).
    public let root: URL
    /// Agneta's own operational log, for `agneta_log`.
    public let log: OperationalLog?
    private let tokenHash: Data
    private var server: LocalHTTPServer?

    public init(traces: Traces, root: URL, token: String, log: OperationalLog? = nil) {
        self.traces = traces
        self.root = root
        self.log = log
        tokenHash = Data(SHA256.hash(data: Data(token.utf8)))
    }

    public func start(port: UInt16) async throws {
        let server = try LocalHTTPServer(port: port) { [weak self] request in
            await self?.handle(request) ?? .init(status: 404)
        }
        try await server.start()
        self.server = server
    }

    public func stop() { server?.stop() }

    // MARK: HTTP and JSON-RPC

    func handle(_ request: LocalHTTPServer.Request) async -> LocalHTTPServer.Response {
        guard request.path.split(separator: "?").first == "/mcp" else { return .init(status: 404) }
        guard request.method == "POST" else { return .init(status: 405, headers: ["Allow": "POST"]) }
        guard authorized(request.headers["authorization"]) else {
            return .init(
                status: 401, headers: ["Content-Type": "application/json", "WWW-Authenticate": "Bearer"],
                body: Data(#"{"error":"Create a diagnostics token in Agneta's Settings → Advanced"}"#.utf8))
        }
        guard let message = try? JSONCoding.decode(request.body), let method = message["method"]?.stringValue else {
            return .init(
                status: 400,
                body: Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#.utf8))
        }
        guard let id = message["id"] else { return .init(status: 202) } // a notification, e.g. notifications/initialized
        let result: Result<JSONValue, RPCError>
        switch method {
        case "initialize":
            result = .success([
                "protocolVersion": message["params"]?["protocolVersion"] ?? "2025-06-18",
                "capabilities": ["tools": [:]], "serverInfo": ["name": "agneta-diagnostics", "version": "1"],
                "instructions":
                    "Read Agneta's task traces: list_tasks, then task_summary, tool_calls, model_calls, read_trace or tail."
            ])
        case "ping": result = .success([:])
        case "tools/list": result = .success(["tools": .array(Self.tools)])
        case "tools/call":
            let name = message["params"]?["name"]?.stringValue ?? ""
            let arguments = message["params"]?["arguments"] ?? [:]
            do {
                let text = try await call(name, arguments)
                result = .success(["content": [["type": "text", "text": .string(text)]]])
            } catch let error as RPCError {
                result = .success(["content": [["type": "text", "text": .string(error.message)]], "isError": true])
            } catch {
                result = .success(["content": [["type": "text", "text": .string("\(error)")]], "isError": true])
            }
        default: result = .failure(RPCError(code: RPCError.methodNotFound, message: "Method not found: \(method)"))
        }
        let body = (try? RPCMessage.response(id: RPCID(id) ?? .int(0), result: result).encoded()) ?? Data()
        return .init(status: 200, body: body)
    }

    private func authorized(_ header: String?) -> Bool {
        guard let header, header.lowercased().hasPrefix("bearer ") else { return false }
        let given = Data(SHA256.hash(data: Data(header.dropFirst(7).trimmingCharacters(in: .whitespaces).utf8)))
        // Constant-time comparison of the hashes.
        return given.count == tokenHash.count && zip(given, tokenHash).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: Tools

    static func tool(_ name: String, _ description: String, _ properties: [String: JSONValue], required: [String] = [])
        -> JSONValue
    {
        [
            "name": .string(name), "description": .string(description),
            "inputSchema": [
                "type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string))
            ]
        ]
    }

    /// The longest a `tail` waits: under LocalHTTPServer's 10 s per connection.
    static let maxTailWait = 8_000
    static let task: JSONValue = ["type": "string", "description": "A task id, or any unique prefix of one"]
    static let json: JSONValue = ["type": "boolean", "description": "Return JSON instead of compact text"]
    static let tools: [JSONValue] = [
        tool(
            "list_tasks",
            "Agneta's tasks with traces, newest first: id, app, title, account, start, turns, whether it ended.",
            ["app": ["type": "string"], "limit": ["type": "integer"], "json": json]),
        tool(
            "task_summary",
            "One task: turns with time, model calls and tokens; tools by total time with failures and p95; model usage; shell commands; permission decisions; lifecycle (stops, limits, queueing).",
            ["task": task, "json": json], required: ["task"]),
        tool(
            "tool_calls",
            "A task's tool calls with input, result, status and exact timing. Input and result are cut to 2000 characters unless full is true.",
            [
                "task": task, "name": ["type": "string", "description": "Only this tool (e.g. echo or app/echo)"],
                "errors_only": ["type": "boolean"], "turn": ["type": "integer"], "full": ["type": "boolean"],
                "json": json
            ], required: ["task"]),
        tool(
            "model_calls",
            "A task's model calls from the engine's ledger: model, input, output, cache tokens, cost, compaction.",
            ["task": task, "turn": ["type": "integer"], "json": json], required: ["task"]),
        tool(
            "read_trace",
            "A task's trace records (agneta/trace) after a sequence number, filtered by type. Raw ACP frames only when types includes acp.",
            [
                "task": task, "after": ["type": "integer"], "types": ["type": "array", "items": ["type": "string"]],
                "limit": ["type": "integer"]
            ], required: ["task"]),
        tool(
            "tail",
            "Waits up to wait_ms (at most 8000) for records after a sequence number of a running task, then returns them; call it again to keep following.",
            ["task": task, "after": ["type": "integer"], "wait_ms": ["type": "integer"]], required: ["task", "after"]),
        tool(
            "engine_log", "The last lines of the engine's own log for a task with a dedicated engine.",
            ["task": task, "lines": ["type": "integer"]], required: ["task"]),
        tool(
            "agneta_log",
            "The last lines of Agneta's own log: starts, pairing, tasks, limits, sign-in, reset; ids and timing, never content.",
            ["lines": ["type": "integer"], "errors_only": ["type": "boolean"]])
    ]

    func call(_ name: String, _ arguments: JSONValue) async throws -> String {
        let asJSON = arguments["json"]?.boolValue == true
        switch name {
        case "list_tasks":
            return listTasks(
                app: arguments["app"]?.stringValue, limit: Int(arguments["limit"]?.intValue ?? 20), json: asJSON)
        case "task_summary": return summary(try resolve(arguments), json: asJSON)
        case "tool_calls":
            return try toolCalls(
                resolve(arguments), name: arguments["name"]?.stringValue,
                errorsOnly: arguments["errors_only"]?.boolValue == true,
                turn: arguments["turn"]?.intValue, full: arguments["full"]?.boolValue == true, json: asJSON)
        case "model_calls": return try modelCalls(resolve(arguments), turn: arguments["turn"]?.intValue, json: asJSON)
        case "read_trace":
            let types = arguments["types"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) } ?? Traces.defaultTypes
            let page = traces.read(
                task: try resolve(arguments), after: arguments["after"]?.intValue ?? 0, types: types,
                limit: min(max(Int(arguments["limit"]?.intValue ?? 200), 1), 2000))
            return Self.encode([
                "records": .array(page?.records ?? []), "next": page?.next.map(JSONValue.int) ?? .null,
                "complete": .bool(page?.complete ?? true)
            ])
        case "tail":
            let task = try resolve(arguments)
            let after = arguments["after"]?.intValue ?? 0
            // Under the HTTP server's 10 s per connection, so the answer always gets back.
            let deadline =
                ContinuousClock.now
                + .milliseconds(min(max(Int(arguments["wait_ms"]?.intValue ?? 5_000), 0), Self.maxTailWait))
            while true {
                let page = traces.read(task: task, after: after, types: Traces.defaultTypes.union(["acp"]), limit: 500)
                if let page, !page.records.isEmpty || page.complete || ContinuousClock.now >= deadline {
                    return Self.encode([
                        "records": .array(page.records), "next": page.next.map(JSONValue.int) ?? .null,
                        "complete": .bool(page.complete)
                    ])
                }
                if page == nil { throw RPCError(code: RPCError.invalidParams, message: "No trace for \(task)") }
                try await Task.sleep(for: .milliseconds(250))
            }
        case "engine_log":
            let task = try resolve(arguments)
            guard let key = traces.meta(task: task)?["engine"]?["key"]?.stringValue, !EngineKeys.isShared(key),
                !key.contains("..")
            else {
                return "This task ran on a shared engine; its log is shared with other tasks and not shown here."
            }
            let log = EngineHomes.home(root: root, key: key).appending(path: "engine.log")
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let count = min(max(Int(arguments["lines"]?.intValue ?? 100), 1), 2000)
            return text.isEmpty
                ? "The engine log is empty or gone." : traces.mask.mask(lines.suffix(count).joined(separator: "\n"))
        case "agneta_log":
            guard let log else { return "Agneta's log isn't available here." }
            var lines = log.tail(min(max(Int(arguments["lines"]?.intValue ?? 100), 1), 5000))
            if arguments["errors_only"]?.boolValue == true { lines = lines.filter { $0.contains(#""level":"error""#) } }
            return lines.isEmpty ? "Nothing logged yet." : lines.joined(separator: "\n")
        default:
            throw RPCError(code: RPCError.methodNotFound, message: "Unknown tool \(name)")
        }
    }

    private func resolve(_ arguments: JSONValue) throws -> String {
        guard let prefix = arguments["task"]?.stringValue, !prefix.isEmpty, !prefix.contains("/"),
            !prefix.contains("..")
        else {
            throw RPCError(code: RPCError.invalidParams, message: "task is required")
        }
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: traces.folder.path(percentEncoded: false))) ?? []
        let matches = names.filter { $0.hasSuffix(".jsonl") && $0.hasPrefix(prefix) }.map { String($0.dropLast(6)) }
        guard matches.count == 1 else {
            throw RPCError(
                code: RPCError.invalidParams,
                message: matches.isEmpty
                    ? "No task starts with \(prefix)" : "\(prefix) matches \(matches.count) tasks; give more of the id")
        }
        return matches[0]
    }

    private func records(_ task: String) throws -> [JSONValue] {
        guard let records = traces.records(task: task) else {
            throw RPCError(code: RPCError.invalidParams, message: "No trace for \(task)")
        }
        return records
    }

    static func encode(_ value: JSONValue) -> String {
        var text = ""
        TraceJSON.encode(value, into: &text)
        return text
    }

    static func cut(_ value: JSONValue?, _ full: Bool) -> JSONValue {
        guard let value else { return .null }
        let text = value.stringValue ?? encode(value)
        return full || text.count <= 2000
            ? value : .string(String(text.prefix(2000)) + "… (\(text.count) characters; full: true for all)")
    }

    private func listTasks(app: String?, limit: Int, json: Bool) -> String {
        let folder = traces.folder
        let files =
            ((try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                        ?? .distantPast)
            }
        var rows: [JSONValue] = []
        for file in files {
            let task = file.deletingPathExtension().lastPathComponent
            guard let meta = traces.meta(task: task) else { continue }
            if let app, meta["app"]?["name"]?.stringValue?.lowercased() != app.lowercased() { continue }
            let last = TraceWriter.lastRecord(of: file)
            rows.append([
                "task": .string(task), "app": meta["app"]?["name"] ?? .null,
                "title": meta["request"]?["_meta"]?["agneta/task"]?["title"] ?? "AI task",
                "account": meta["account"]?["label"] ?? .null,
                "started": meta["t"] ?? .null, "turns": last?["turn"] ?? 0,
                "ended": .bool(last?["type"]?.stringValue == "end")
            ])
            if rows.count >= limit { break }
        }
        if json { return Self.encode(.array(rows)) }
        if rows.isEmpty { return "No tasks with traces." }
        return rows.map { row in
            "\(row["task"]?.stringValue ?? "")  \(row["started"]?.stringValue ?? "")  \(row["app"]?.stringValue ?? "?")  \(row["title"]?.stringValue ?? "")  \(row["account"]?.stringValue ?? "")  \(row["turns"]?.intValue ?? 0) turns  \(row["ended"]?.boolValue == true ? "ended" : "running")"
        }.joined(separator: "\n")
    }

    private func summary(_ task: String, json: Bool) -> String {
        guard let records = traces.records(task: task) else { return "No trace for \(task)." }
        let s = TraceSummary(records: records)
        if json {
            return Self.encode([
                "task": .string(task), "app": s.app.map(JSONValue.string) ?? .null,
                "account": s.account.map(JSONValue.string) ?? .null,
                "billing": s.billing.map(JSONValue.string) ?? .null, "ended": .bool(s.ended),
                "cost": s.cost.map(JSONValue.double) ?? .null,
                "turns": .array(
                    s.turns.map {
                        [
                            "n": .int(Int64($0.n)), "stopReason": .string($0.stopReason),
                            "ms": $0.ms.map(JSONValue.double) ?? .null,
                            "modelCalls": .int(Int64($0.modelCalls)), "input": .int(Int64($0.input)),
                            "output": .int(Int64($0.output)),
                            "error": $0.error.map(JSONValue.string) ?? .null
                        ]
                    }),
                "tools": .array(
                    s.toolStats.map {
                        [
                            "name": .string($0.name), "calls": .int(Int64($0.calls)), "errors": .int(Int64($0.errors)),
                            "totalMs": .double($0.totalMs), "p95Ms": .double($0.p95Ms)
                        ]
                    }),
                "modelCalls": .int(Int64(s.modelCalls)), "input": .int(Int64(s.input)), "output": .int(Int64(s.output)),
                "cacheRead": .int(Int64(s.cacheRead)), "shellCommands": .int(Int64(s.shellCommands)),
                "shellFailures": .int(Int64(s.shellFailures)),
                "permissions": .object(s.permissions.mapValues { .int(Int64($0)) }), "lifecycle": .array(s.lifecycle)
            ])
        }
        var lines = [
            "Task \(task): \(s.app ?? "?") on \(s.account ?? "?") (\(s.billing ?? "?")), \(s.ended ? "ended" : "running"), \(s.records) records"
        ]
        for turn in s.turns {
            lines.append(
                "turn \(turn.n): \(turn.stopReason), \(Int(turn.ms ?? 0)) ms, first token \(Int(turn.msToFirstToken ?? 0)) ms, \(turn.modelCalls) model calls, in \(turn.input) out \(turn.output)\(turn.error.map { ", error: \($0)" } ?? "")"
            )
        }
        lines.append(
            "tools (\(s.toolCalls) calls\(s.unfinishedToolCalls > 0 ? ", \(s.unfinishedToolCalls) unfinished" : "")):")
        for tool in s.toolStats {
            lines.append(
                "  \(tool.name): \(tool.calls)×, \(tool.errors) failed, \(Int(tool.totalMs)) ms total, p95 \(Int(tool.p95Ms)) ms"
            )
        }
        lines.append(
            "model: \(s.modelCalls) calls, in \(s.input), out \(s.output), cache read \(s.cacheRead), compactions \(s.compactions)\(s.cost.map { String(format: ", cost $%.4f", $0) } ?? "")"
        )
        lines.append(
            "shell: \(s.shellCommands) commands, \(s.shellFailures) failed, \(s.shellRefused) refused; permissions: \(s.permissions.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))"
        )
        for record in s.lifecycle {
            let fields = (record.objectValue ?? [:]).filter {
                !["v", "seq", "t", "mono", "task", "type", "request"].contains($0.key)
            }
            lines.append("lifecycle: \(Self.encode(.object(fields)))")
        }
        return lines.joined(separator: "\n")
    }

    private func toolCalls(_ task: String, name: String?, errorsOnly: Bool, turn: Int64?, full: Bool, json: Bool) throws
        -> String
    {
        let all = try records(task)
        var results: [String: JSONValue] = [:]
        for record in all where record["kind"]?.stringValue == "tool-result" {
            if let call = record["call"]?.stringValue { results[call] = record }
        }
        var rows: [JSONValue] = []
        for call in all where call["kind"]?.stringValue == "tool-call" {
            let id = call["call"]?.stringValue ?? ""
            let tool = call["tool"]?.stringValue ?? call["name"]?.stringValue ?? "?"
            let qualified = [call["extension"]?.stringValue, call["tool"]?.stringValue].compactMap { $0 }.joined(
                separator: "/")
            if let name, name != tool, name != qualified { continue }
            if let turn, call["turn"]?.intValue != turn { continue }
            let result = results[id]
            if errorsOnly && result?["isError"]?.boolValue != true { continue }
            rows.append([
                "call": .string(id), "turn": call["turn"] ?? .null,
                "tool": .string(qualified.isEmpty ? tool : qualified),
                "input": Self.cut(call["input"], full), "status": result?["status"] ?? "running",
                "isError": result?["isError"] ?? .null,
                "ms": result?["ms"] ?? .null, "result": Self.cut(result?["content"], full),
                "rawOutput": Self.cut(result?["rawOutput"], full)
            ])
        }
        if json { return Self.encode(.array(rows)) }
        if rows.isEmpty { return "No matching tool calls." }
        return rows.map { row in
            "\(row["call"]?.stringValue ?? "") turn \(row["turn"]?.intValue ?? 0) \(row["tool"]?.stringValue ?? "") \(row["status"]?.stringValue ?? "")\(row["ms"].flatMap { $0 == .null ? nil : " \(Self.encode($0)) ms" } ?? "")\n  input: \(Self.encode(row["input"] ?? .null))\n  result: \(Self.encode(row["result"] ?? .null))"
        }.joined(separator: "\n")
    }

    private func modelCalls(_ task: String, turn: Int64?, json: Bool) throws -> String {
        let calls = try records(task).filter {
            $0["kind"]?.stringValue == "model-call" && (turn == nil || $0["turn"]?.intValue == turn)
        }
        if json { return Self.encode(.array(calls)) }
        if calls.isEmpty { return "No model calls recorded (the engine's ledger may not be available)." }
        return calls.map { call in
            "#\(call["n"]?.intValue ?? 0) turn \(call["turn"]?.intValue ?? 0) \(call["model"]?.stringValue ?? "?"): in \(call["input"]?.intValue ?? 0) out \(call["output"]?.intValue ?? 0) cache \(call["cacheRead"]?.intValue ?? 0)/\(call["cacheWrite"]?.intValue ?? 0)\(call["cost"].flatMap { $0 == .null ? nil : " cost \(Self.encode($0)) (\(call["costKind"]?.stringValue ?? ""))" } ?? "")\(call["compaction"]?.boolValue == true ? " compaction" : "")"
        }.joined(separator: "\n")
    }
}
