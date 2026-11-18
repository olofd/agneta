// The fake model provider and the stand-in app's tool server that tests run engines against, on loopback. The
// Swift tests serve them from the test process; Project Chat's smoke test and the round scripts in scripts/dev
// run them with `agneta-fakes`. Each request is logged as one JSON line. Development only: never in the app.
//
// Why not Python, as these were first: on GitHub's macOS runners a Python server on 127.0.0.1 often never accepts a
// connection (measured 2026-11-18: /usr/local/bin/python3 on every runner, /opt/homebrew/bin/python3 on macOS 26,
// curl hanging for its whole timeout), while Swift listeners are reached every time (the sandbox acceptance test,
// the app connections). They are also ready the moment start() returns: no sleep.
import Foundation
import Network

/// A small HTTP/1.1 server on 127.0.0.1: one request per connection, answered with a Content-Length body, then closed.
public final class FakeServer: @unchecked Sendable {
    struct Request {
        var method: String
        var path: String
        var headers: [String: String] // lowercased names
        var body: Data
    }

    struct Response {
        var status: Int
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = Data()
        static func json(_ value: Any, status: Int = 200) -> Response {
            Response(status: status, body: (try? JSONSerialization.data(withJSONObject: value)) ?? Data())
        }
    }

    typealias Handler = @Sendable (Request) async -> Response
    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "agneta.tests.fake-server", attributes: .concurrent)

    private init(port: Int, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    /// Starts listening; returns once the port accepts connections.
    static func start(port: Int, handler: @escaping Handler) async throws -> FakeServer {
        let server = try FakeServer(port: port, handler: handler)
        let started = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if started.take() { continuation.resume() }
                case .failed(let error): if started.take() { continuation.resume(throwing: error) }
                default: break
                }
            }
            server.listener.newConnectionHandler = { [weak server] connection in server?.serve(connection) }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    public func stop() { listener.cancel() }

    /// True the first time only: the listener's state handler may report ready or failed more than once.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    private func serve(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak connection] state in
            if case .failed = state { connection?.cancel() }
        }
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil { connection.cancel(); return }
            if let request = Self.parse(buffer) {
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    connection.send(content: Self.encode(response), completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if complete {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    /// A complete request, or nil while more bytes are needed.
    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = head.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private static func encode(_ response: Response) -> Data {
        let reasons = [200: "OK", 202: "Accepted", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 429: "Too Many Requests"]
        var head = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Status")\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + response.body
    }

    /// Appends one JSON line to a log file.
    fileprivate static func log(_ value: [String: Any], to file: URL) {
        guard var line = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(line); try? handle.close()
        } else {
            try? line.write(to: file)
        }
    }
}

// MARK: - The fake model provider

extension FakeServer {
    /// An OpenAI-compatible model that follows a tiny script. When the latest message is a tool result it answers in
    /// text; "CALL <tool> <json>" calls a tool with exact arguments; "use tool <name>" calls that tool once;
    /// "LONGREPLY <kilobytes>" streams a long reply; "slowly" delays the reply by 5 s and "PAUSE <ms>" by that long;
    /// "RATELIMIT" answers 429 as OpenAI does; anything else gets fixed text. Every request is logged to `log`.
    /// Files to download, by path: a GET answers with the bytes (and their length), anything else 404. For download
    /// tests, which need a real HTTP server on loopback and can't use Python's (see the top of this file).
    public static func files(port: Int, _ files: [String: Data]) async throws -> FakeServer {
        try await start(port: port) { request in
            guard request.method == "GET", let data = files[request.path] else { return Response(status: 404, body: Data("not found".utf8)) }
            return Response(status: 200, headers: ["Content-Type": "application/octet-stream"], body: data)
        }
    }

    public static func model(port: Int, log: URL) async throws -> FakeServer {
        let lock = NSLock()
        return try await start(port: port) { request in
            let body = (try? JSONSerialization.jsonObject(with: request.body.isEmpty ? Data("{}".utf8) : request.body)) as? [String: Any] ?? [:]
            if request.method == "GET" {
                guard request.path.hasSuffix("/models") || request.path.hasSuffix("/models/") else { return Response(status: 404) }
                return .json(["object": "list", "data": [["id": "fake-model", "object": "model", "owned_by": "agneta"]]])
            }
            lock.withLock { FakeServer.log(["path": request.path, "body": body], to: log) }
            guard request.path.hasSuffix("/chat/completions") else { return Response(status: 404) }
            let messages = body["messages"] as? [[String: Any]] ?? []
            let last = messages.last ?? [:]
            let lastText = String(decoding: (try? JSONSerialization.data(withJSONObject: [last])) ?? Data(), as: UTF8.self)
            if lastText.contains("RATELIMIT") {
                var response = Response.json(["error": ["message": "Rate limit reached for requests. Please try again in 20s.",
                                                        "type": "requests", "code": "rate_limit_exceeded"]], status: 429)
                response.headers["Retry-After"] = "20"
                response.headers["x-ratelimit-reset-requests"] = "20s"
                return response
            }
            let reply = modelReply(body)
            if lastText.contains("slowly") { try? await Task.sleep(for: .seconds(5)) }
            if let ms = firstNumber(after: "PAUSE ", in: lastText) { try? await Task.sleep(for: .milliseconds(ms)) }
            let usage = ["prompt_tokens": 42, "completion_tokens": 7, "total_tokens": 49]
            let delta: [String: Any]
            let finish: String
            if let tool = reply.tool {
                let arguments = String(decoding: (try? JSONSerialization.data(withJSONObject: reply.arguments)) ?? Data("{}".utf8), as: UTF8.self)
                delta = ["role": "assistant", "tool_calls": [["index": 0, "id": "call_1", "type": "function",
                                                              "function": ["name": tool, "arguments": arguments]]]]
                finish = "tool_calls"
            } else {
                delta = ["role": "assistant", "content": reply.content]
                finish = "stop"
            }
            let created = Int(Date().timeIntervalSince1970)
            func chunk(_ value: [String: Any]) -> Data {
                var value = value
                value["id"] = "chatcmpl-fake"; value["object"] = "chat.completion.chunk"; value["created"] = created; value["model"] = "fake-model"
                return Data("data: ".utf8) + ((try? JSONSerialization.data(withJSONObject: value)) ?? Data()) + Data("\n\n".utf8)
            }
            guard body["stream"] as? Bool == true else {
                return .json(["id": "chatcmpl-fake", "object": "chat.completion", "created": created, "model": "fake-model",
                              "choices": [["index": 0, "message": delta, "finish_reason": finish]], "usage": usage])
            }
            var stream = Data()
            if let kilobytes = firstNumber(after: "LONGREPLY ", in: lastText) {
                // A long reply in many chunks (megabytes, for flow-control tests).
                let piece = String(repeating: "x", count: 1024)
                for n in 0..<kilobytes {
                    stream += chunk(["choices": [["index": 0, "delta": n == 0 ? ["role": "assistant", "content": piece] : ["content": piece]]]])
                }
                stream += chunk(["choices": [["index": 0, "delta": [String: Any](), "finish_reason": "stop"]]])
            } else {
                stream += chunk(["choices": [["index": 0, "delta": delta]]])
                stream += chunk(["choices": [["index": 0, "delta": [String: Any](), "finish_reason": finish]]])
            }
            stream += chunk(["choices": [Any](), "usage": usage])
            stream += Data("data: [DONE]\n\n".utf8)
            return Response(status: 200, headers: ["Content-Type": "text/event-stream"], body: stream)
        }
    }

    private static func firstNumber(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber })
    }

    private static func modelReply(_ body: [String: Any]) -> (content: String, tool: String?, arguments: Any) {
        let messages = body["messages"] as? [[String: Any]] ?? []
        let last = messages.last ?? [:]
        if last["role"] as? String == "tool" {
            let content = last["content"].map { $0 as? String ?? String(describing: $0) } ?? ""
            return ("The tool said: " + String(content.prefix(200)), nil, [String: Any]())
        }
        let raw = last["content"] as? String ?? ""
        let text = String(decoding: (try? JSONSerialization.data(withJSONObject: [last["content"] ?? ""])) ?? Data(), as: UTF8.self)
        if let call = raw.range(of: "CALL ") {
            // CALL <tool> <json arguments>
            let rest = raw[call.upperBound...]
            if let space = rest.firstIndex(of: " ") {
                let name = String(rest[..<space])
                let json = rest[rest.index(after: space)...].components(separatedBy: "\n<turn-context>")[0]
                return ("", name, (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [String: Any]())
            }
        }
        let tools = (body["tools"] as? [[String: Any]] ?? []).compactMap { tool -> String? in
            tool["type"] as? String == "function" ? (tool["function"] as? [String: Any])?["name"] as? String : nil
        }
        for name in tools where text.contains("use tool \(name)") || text.contains("use tool \(name.components(separatedBy: "__").last ?? name)") {
            return ("", name, ["text": "hello from the fake model"])
        }
        return ("Hello from the fake model.", nil, [String: Any]())
    }
}

// MARK: - The stand-in app's tool server

extension FakeServer {
    /// An MCP server (Streamable HTTP, JSON responses) that requires `Authorization: Bearer <bearer>`. Its tools:
    /// `echo` returns text, `swatch` a small PNG. Every request is logged to `log`.
    public static func mcp(port: Int, bearer: String, log: URL) async throws -> FakeServer {
        let lock = NSLock()
        return try await start(port: port) { request in
            switch request.method {
            case "GET": return Response(status: 405)
            case "DELETE": return Response(status: 200)
            default: break
            }
            let authorized = request.headers["authorization"] == "Bearer \(bearer)"
            let message = (try? JSONSerialization.jsonObject(with: request.body.isEmpty ? Data("null".utf8) : request.body, options: .fragmentsAllowed)) ?? NSNull()
            lock.withLock { FakeServer.log(["authorized": authorized, "body": message], to: log) }
            guard authorized else { return Response(status: 401) }
            let batch = message as? [[String: Any]]
            let replies = (batch ?? [message as? [String: Any] ?? [:]]).compactMap(mcpReply)
            guard !replies.isEmpty else { return Response(status: 202) }
            var response = Response.json(batch != nil ? replies : replies[0])
            response.headers["Mcp-Session-Id"] = "fake-session"
            return response
        }
    }

    private static func mcpReply(_ message: [String: Any]) -> [String: Any]? {
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch message["method"] as? String {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18", "capabilities": ["tools": [String: Any]()],
                      "serverInfo": ["name": "app-fake", "version": "0"]]
        case "tools/list":
            result = ["tools": [
                ["name": "echo", "description": "Echo text back.",
                 "inputSchema": ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]],
                ["name": "swatch", "description": "Return a colour swatch image.",
                 "inputSchema": ["type": "object", "properties": ["text": ["type": "string"]]]],
            ]]
        case "tools/call":
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            switch params["name"] as? String {
            case "echo":
                result = ["content": [["type": "text", "text": "echo: " + (arguments["text"].map { $0 as? String ?? String(describing: $0) } ?? "None")]]]
            case "swatch":
                result = ["content": [["type": "text", "text": "A fjord-blue swatch."],
                                      ["type": "image", "mimeType": "image/png", "data": swatchPNG.base64EncodedString()]]]
            default:
                return ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": -32602, "message": "unknown tool"]]
            }
        default:
            guard let id else { return nil } // a notification
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": message["method"] as? String ?? ""]]
        }
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    /// An 8×8 fjord-blue PNG.
    static let swatchPNG: Data = {
        func chunk(_ type: String, _ data: Data) -> Data {
            var out = Data()
            var length = UInt32(data.count).bigEndian
            out.append(Data(bytes: &length, count: 4))
            let typed = Data(type.utf8) + data
            out.append(typed)
            var crc = crc32(typed).bigEndian
            out.append(Data(bytes: &crc, count: 4))
            return out
        }
        var header = Data()
        for value in [UInt32(8), UInt32(8)] { var v = value.bigEndian; header.append(Data(bytes: &v, count: 4)) }
        header.append(contentsOf: [8, 2, 0, 0, 0])
        var raw = Data()
        for _ in 0..<8 { raw.append(0); for _ in 0..<8 { raw.append(contentsOf: [47, 95, 122]) } }
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + chunk("IHDR", header) + chunk("IDAT", zlibStored(raw)) + chunk("IEND", Data())
    }()

    /// zlib data in stored (uncompressed) blocks: a valid PNG IDAT without a compressor.
    private static func zlibStored(_ data: Data) -> Data {
        var out = Data([0x78, 0x01])
        let length = UInt16(data.count)
        out.append(1) // final block, stored
        out.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8(~length >> 8)])
        out.append(data)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        var adler = ((b << 16) | a).bigEndian
        out.append(Data(bytes: &adler, count: 4))
        return out
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        return ~crc
    }
}
