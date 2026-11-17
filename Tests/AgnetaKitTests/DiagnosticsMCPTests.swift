// The diagnostics MCP server over real HTTP on loopback (docs/DIAGNOSTICS.md, D3).
import Foundation
import Testing
@testable import AgnetaKit

@Suite(.serialized) struct DiagnosticsMCPTests {
    struct Reply { var status: Int; var body: JSONValue? }

    static func post(_ port: UInt16, _ body: JSONValue, token: String? = "agd_test", origin: String? = nil) async throws -> Reply {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        request.httpBody = try JSONCoding.encode(body)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return Reply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: try? JSONCoding.decode(data))
    }

    static func call(_ port: UInt16, _ tool: String, _ arguments: JSONValue) async throws -> (text: String, isError: Bool) {
        let reply = try await post(port, ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(tool), "arguments": arguments]])
        let result = reply.body?["result"]
        return (result?["content"]?.arrayValue?.first?["text"]?.stringValue ?? "", result?["isError"]?.boolValue == true)
    }

    @Test func toolsReadTracesWithTheTokenOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agneta-dmcp-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let traces = Traces(folder: root.appending(path: "Traces", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: traces.folder, withIntermediateDirectories: true)
        // A finished task (seq numbers as a real trace has them) and one still running.
        let finished = TraceSummaryTests.records.enumerated().map { index, record in record.setting("seq", to: .int(Int64(index + 1))).setting("turn", to: 1) }
        try TraceExport.write(finished, to: traces.file(for: "s_finished"), redactContent: false)
        let running = traces.open(task: "s_running", lease: "acct/x", engineSession: "e")
        running.writer.record("meta", ["app": ["name": "Example App"], "engine": ["key": "acct/x", "dedicated": true]])
        running.writer.flush()

        let port: UInt16 = 47481
        let log = OperationalLog(folder: root.appending(path: "Logs", directoryHint: .isDirectory))
        log.log("start", ["port": 1])
        log.error("server-unavailable", ["port": 2])
        let server = DiagnosticsMCP(traces: traces, root: root, token: "agd_test", log: log)
        try await server.start(port: port)
        defer { server.stop() }

        #expect(try await Self.post(port, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"], token: nil).status == 401)
        #expect(try await Self.post(port, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"], token: "wrong").status == 401)
        #expect(try await Self.post(port, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"], origin: "https://example.com").status == 403)

        let initialized = try await Self.post(port, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        #expect(initialized.body?["result"]?["serverInfo"]?["name"]?.stringValue == "agneta-diagnostics")
        #expect(try await Self.post(port, ["jsonrpc": "2.0", "method": "notifications/initialized"]).status == 202)
        let tools = try await Self.post(port, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        #expect(tools.body?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }.count == 8)

        let list = try await Self.call(port, "list_tasks", [:])
        #expect(list.text.contains("s_finished") && list.text.contains("s_running"))
        let summary = try await Self.call(port, "task_summary", ["task": "s_fin"])
        #expect(summary.text.contains("app/echo: 2×, 1 failed") && summary.text.contains("ended"))
        let failed = try await Self.call(port, "tool_calls", ["task": "s_fin", "errors_only": true])
        #expect(failed.text.contains("c2") && !failed.text.contains("c1 "))
        let echo = try await Self.call(port, "tool_calls", ["task": "s_fin", "name": "app/echo", "json": true])
        #expect(try JSONCoding.decode(Data(echo.text.utf8)).arrayValue?.count == 2)
        let models = try await Self.call(port, "model_calls", ["task": "s_fin"])
        #expect(models.text.contains("in 100 out 10") && models.text.contains("compaction"))
        #expect(try await Self.call(port, "task_summary", ["task": "s_"]).isError) // ambiguous prefix
        #expect(try await Self.call(port, "task_summary", ["task": "../x"]).isError)
        let errors = try await Self.call(port, "agneta_log", ["errors_only": true])
        #expect(errors.text.contains("server-unavailable") && !errors.text.contains(#""event":"start""#))

        // tail waits for new records of a running task.
        let waiting = Task { try await Self.call(port, "tail", ["task": "s_running", "after": 1, "wait_ms": 5000]) }
        try await Task.sleep(for: .milliseconds(400))
        running.writer.record("event", ["kind": "tool-call", "call": "c1", "tool": "render"])
        running.writer.flush()
        let tail = try await waiting.value
        let page = try JSONCoding.decode(Data(tail.text.utf8))
        #expect(page["records"]?.arrayValue?.first?["tool"]?.stringValue == "render")
        #expect(page["complete"]?.boolValue == false)
        traces.close(task: "s_running")
    }
}
