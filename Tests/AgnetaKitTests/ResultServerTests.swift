// The result server over real HTTP on loopback: started on first use, one route and bearer per session, MCP's methods,
// and every way a caller is turned away.
import Foundation
import Testing

@testable import AgnetaKit

@Suite struct ResultServerTests {
    /// Stands in for the router: records calls and answers as told.
    final class Sessions: ResultSessions, @unchecked Sendable {
        let lock = NSLock()
        var calls: [(session: String, route: String, tool: String, arguments: JSONValue)] = []
        var tools: [String: [JSONValue]] = [:]
        /// How long each call takes to answer.
        var delay: Duration = .zero

        func resultTools(session: String, route: String) async -> [JSONValue]? { lock.withLock { tools[session] } }

        func submitResult(session: String, route: String, tool: String, arguments: JSONValue) async -> (
            text: String, isError: Bool
        ) {
            let delay = lock.withLock { self.delay }
            if delay > .zero { try? await Task.sleep(for: delay) }
            lock.withLock { calls.append((session, route, tool, arguments)) }
            return ("answer for \(session)", tool == "submit_bad")
        }
    }

    struct Reply { var status: Int; var body: JSONValue? }

    static func post(
        _ url: String, _ body: Data, bearer: String?, origin: String? = nil, method: String = "POST"
    ) async throws -> Reply {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if method == "POST" { request.httpBody = body }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return Reply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: try? JSONCoding.decode(data))
    }

    static func rpc(_ route: ResultServer.Route, _ method: String, _ params: JSONValue = [:], bearer: String? = nil)
        async throws -> Reply
    {
        let message: JSONValue = ["jsonrpc": "2.0", "id": 7, "method": .string(method), "params": params]
        return try await post(route.url, try JSONCoding.encode(message), bearer: bearer ?? route.bearer)
    }

    @Test func startsOnFirstUseAndOnce() async throws {
        let sessions = Sessions()
        let server = ResultServer(sessions: sessions)
        defer { Task { await server.stop() } }
        #expect(await server.routeCount == 0)
        async let a = server.port()
        async let b = server.port()
        let (first, second) = try await (a, b)
        #expect(first == second && first != 0)
        #expect(try await server.port() == first)
    }

    @Test func eachSessionGetsItsOwnRouteAndBearer() async throws {
        let sessions = Sessions()
        let server = ResultServer(sessions: sessions)
        defer { Task { await server.stop() } }
        let one = try await server.register(session: "s1")
        let two = try await server.register(session: "s2")
        let port = try await server.port()
        #expect(one.url.hasPrefix("http://127.0.0.1:\(port)/result/"))
        #expect(one.url != two.url && one.bearer != two.bearer)
        #expect(one.url.split(separator: "/").last?.count == 32 && one.bearer.count == 64)
        #expect(
            one.server
                == [
                    "type": "http", "name": "agneta-result", "url": .string(one.url),
                    "headers": [["name": "Authorization", "value": .string("Bearer \(one.bearer)")]]
                ])
        #expect(await server.routeCount == 2)
        // A session can't use another's bearer on its own route, nor its own on another's.
        #expect(try await Self.rpc(one, "ping", bearer: two.bearer).status == 401)
        #expect(try await Self.rpc(two, "ping", bearer: one.bearer).status == 401)
        #expect(try await Self.rpc(one, "ping").status == 200)
    }

    @Test func answersMCPsMethodsForItsSession() async throws {
        let sessions = Sessions()
        sessions.tools["s1"] = [["name": "submit_result"]]
        let server = ResultServer(sessions: sessions)
        defer { Task { await server.stop() } }
        let route = try await server.register(session: "s1")

        let initialized = try await Self.rpc(route, "initialize", ["protocolVersion": "2025-06-18"])
        #expect(initialized.body?["result"]?["serverInfo"]?["name"] == "agneta-result")
        #expect(initialized.body?["result"]?["protocolVersion"] == "2025-06-18")
        #expect(initialized.body?["result"]?["capabilities"]?["tools"] == [:])
        #expect(try await Self.rpc(route, "ping").body?["result"] == [:])
        #expect(try await Self.rpc(route, "tools/list").body?["result"]?["tools"] == [["name": "submit_result"]])

        let call = try await Self.rpc(route, "tools/call", ["name": "submit_result", "arguments": ["a": 1]])
        #expect(call.body?["result"]?["content"] == [["type": "text", "text": "answer for s1"]])
        #expect(call.body?["result"]?["isError"] == nil)
        let bad = try await Self.rpc(route, "tools/call", ["name": "submit_bad", "arguments": [:]])
        #expect(bad.body?["result"]?["isError"] == true)
        #expect(sessions.calls.map(\.session) == ["s1", "s1"] && sessions.calls[0].arguments == ["a": 1])
        #expect(sessions.calls.allSatisfy { $0.route == route.id }) // the router learns which route it came through

        #expect(try await Self.rpc(route, "resources/list").body?["error"]?["code"] == .int(RPCError.methodNotFound))
        let note = try JSONCoding.encode(["jsonrpc": "2.0", "method": "notifications/initialized"] as JSONValue)
        #expect(try await Self.post(route.url, note, bearer: route.bearer).status == 202)
    }

    @Test func aSessionWithoutToolsListsAnError() async throws {
        let server = ResultServer(sessions: Sessions())
        defer { Task { await server.stop() } }
        let route = try await server.register(session: "gone")
        #expect(try await Self.rpc(route, "tools/list").body?["error"]?["code"] == .int(RPCError.invalidParams))
    }

    @Test func turnsAwayEveryoneElse() async throws {
        let server = ResultServer(sessions: Sessions())
        defer { Task { await server.stop() } }
        let route = try await server.register(session: "s1")
        let ping = try JSONCoding.encode(["jsonrpc": "2.0", "id": 1, "method": "ping"] as JSONValue)
        let port = try await server.port()
        #expect(try await Self.post(route.url, ping, bearer: nil).status == 401)
        #expect(try await Self.post(route.url, ping, bearer: "0" + route.bearer.dropFirst()).status == 401)
        // An unknown route answers like a wrong token, so routes can't be probed.
        #expect(try await Self.post("http://127.0.0.1:\(port)/result/0123", ping, bearer: route.bearer).status == 401)
        #expect(try await Self.post("http://127.0.0.1:\(port)/mcp", ping, bearer: route.bearer).status == 404)
        #expect(try await Self.post(route.url, ping, bearer: route.bearer, origin: "https://example.com").status == 403)
        #expect(try await Self.post(route.url, Data(), bearer: route.bearer, method: "GET").status == 405)
        #expect(try await Self.post(route.url, Data("{not json".utf8), bearer: route.bearer).status == 400)
    }

    @Test func aRouteEndsWithItsSessionAndIsReplacedOnReload() async throws {
        let server = ResultServer(sessions: Sessions())
        defer { Task { await server.stop() } }
        let first = try await server.register(session: "s1")
        let second = try await server.register(session: "s1")
        #expect(first != second)
        #expect(await server.routeCount == 1)
        #expect(try await Self.rpc(first, "ping").status == 401)
        #expect(try await Self.rpc(second, "ping").status == 200)
        await server.unregister(session: "s1")
        #expect(await server.routeCount == 0)
        #expect(try await Self.rpc(second, "ping").status == 401)
    }

    @Test func refusesBodiesOverTheCapAndTakesOneAtIt() async throws {
        let server = ResultServer(sessions: Sessions())
        let route = try await server.register(session: "s1")
        let port = try await server.port()
        let path = String(route.url.dropFirst("http://127.0.0.1:\(port)".count))
        let over = try RawHTTP.send(
            port, "POST \(path) HTTP/1.1\r\nAuthorization: Bearer \(route.bearer)\r\nContent-Length: 1048577\r\n\r\n")
        #expect(over.hasPrefix("HTTP/1.1 400"))
        // Exactly 1 MB is read in full (and isn't JSON: a 400 parse error, not a closed connection).
        let body = String(repeating: " ", count: 1 << 20)
        let at = try RawHTTP.send(
            port,
            "POST \(path) HTTP/1.1\r\nAuthorization: Bearer \(route.bearer)\r\nContent-Length: \(1 << 20)\r\n\r\n"
                + body)
        #expect(at.hasPrefix("HTTP/1.1 400") && at.contains("-32700"))
        await server.stop()
    }

    @Test func malformedHeadersAndRequestsAreRefused() async throws {
        let server = ResultServer(sessions: Sessions())
        let route = try await server.register(session: "s1")
        let port = try await server.port()
        let path = String(route.url.dropFirst("http://127.0.0.1:\(port)".count))
        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        // "Origin :" is malformed, not a request without an Origin.
        let spaced = try RawHTTP.send(
            port,
            "POST \(path) HTTP/1.1\r\nOrigin : https://example.com\r\nAuthorization: Bearer \(route.bearer)\r\n"
                + "Content-Length: \(ping.utf8.count)\r\n\r\n\(ping)")
        #expect(spaced.hasPrefix("HTTP/1.1 400"))
        func post(_ body: String) throws -> String {
            try RawHTTP.send(
                port,
                "POST \(path) HTTP/1.1\r\nAuthorization: Bearer \(route.bearer)\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
                    + body)
        }
        #expect(try post(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#).contains("-32600")) // a batch
        #expect(try post(#"{"jsonrpc":"2.0","id":1}"#).contains("-32600")) // no method
        #expect(try post(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#).contains("-32600"))
        #expect(try post(ping).hasPrefix("HTTP/1.1 200"))
        await server.stop()
    }

    @Test func negotiatesTheProtocolVersion() async throws {
        let server = ResultServer(sessions: Sessions())
        let route = try await server.register(session: "s1")
        for (asked, answered) in [
            ("2025-06-18", "2025-06-18"), ("2024-11-05", "2024-11-05"), ("2099-01-01", "2025-11-25"), ("", "2025-11-25")
        ] {
            let reply = try await Self.rpc(route, "initialize", ["protocolVersion": .string(asked)])
            #expect(reply.body?["result"]?["protocolVersion"]?.stringValue == answered, "\(asked)")
        }
        await server.stop()
    }

    @Test func idleConnectionsDontHoldTheSlots() async throws {
        let server = ResultServer(sessions: Sessions())
        let route = try await server.register(session: "s1")
        let port = try await server.port()
        // Every slot taken by connections that send nothing.
        let idle = try (0..<LocalHTTPServer.maxConnections).map { _ in try RawHTTP.connect(port) }
        defer { idle.forEach { close($0) } }
        // They're closed once the time to send a request has passed, and the session's call goes through.
        try await Task.sleep(for: .milliseconds(2_500))
        #expect(try await Self.rpc(route, "ping").status == 200)
        await server.stop()
    }

    @Test func aSlowAnswerStillReachesTheCaller() async throws {
        let sessions = Sessions()
        sessions.delay = .milliseconds(3_000) // longer than a request may take to arrive
        let server = ResultServer(sessions: sessions)
        let route = try await server.register(session: "s1")
        let call = try await Self.rpc(route, "tools/call", ["name": "submit_result", "arguments": [:]])
        #expect(call.body?["result"]?["content"]?.arrayValue?.first?["text"] == "answer for s1")
        await server.stop()
    }

    @Test func stoppingDuringTheStartLeavesNothingListening() async throws {
        // The listener has started but isn't kept yet when the stop arrives.
        let server = ResultServer(sessions: Sessions()) { try? await Task.sleep(for: .milliseconds(300)) }
        let starting = Task { try await server.port() }
        try await Task.sleep(for: .milliseconds(100))
        await server.stop()
        let outcome = await starting.result
        guard case .failure = outcome else {
            Issue.record("a start the stop overtook still gave a port")
            return
        }
        // A stop is final (Agneta is resetting or quitting): nothing starts it again.
        await #expect(throws: (any Error).self) { _ = try await server.register(session: "s1") }
    }

    @Test func aStoppedServerClosesItsPort() async throws {
        let server = ResultServer(sessions: Sessions())
        let route = try await server.register(session: "s1")
        #expect(try await Self.rpc(route, "ping").status == 200)
        await server.stop()
        // The listener closes asynchronously: within 2 s the port refuses or closes every connection.
        let port = UInt16(URL(string: route.url)!.port!)
        var closed = false
        for _ in 0..<20 where !closed {
            closed = (try? RawHTTP.connect(port, closedWithin: .milliseconds(100))) == nil
            if !closed { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(closed)
    }

    @Test func stopClosesRequestsInFlight() async throws {
        let sessions = Sessions()
        sessions.delay = .seconds(30)
        let server = ResultServer(sessions: sessions)
        let route = try await server.register(session: "s1")
        let started = ContinuousClock.now
        async let call = try? Self.rpc(route, "tools/call", ["name": "submit_result", "arguments": [:]])
        try await Task.sleep(for: .milliseconds(300))
        await server.stop()
        let reply = await call
        #expect(reply == nil || reply?.status != 200)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func aRouteNeverPrintsItsBearer() async throws {
        let server = ResultServer(sessions: Sessions())
        let route = try await server.register(session: "s1")
        #expect(!"\(route)".contains(route.bearer))
        await server.stop()
    }

    @Test func toolsAreTheDeclaredSchemasLoadedUpFront() throws {
        let invoice: JSONValue = [
            "type": "object", "description": "One invoice", "properties": ["n": ["type": "string"]]
        ]
        let declaration = try #require(
            try ResultDeclaration.parse(["schemas": ["invoice": invoice, "contact": ["type": "object"]]]))
        let tools = ResultServer.tools(declaration)
        #expect(tools.map { $0["name"] } == ["submit_contact", "submit_invoice"])
        #expect(tools[1]["inputSchema"] == invoice)
        #expect(tools[1]["_meta"] == ["anthropic/alwaysLoad": true])
        #expect(tools[1]["description"]?.stringValue?.hasSuffix("The result: One invoice") == true)
        #expect(tools[0]["description"]?.stringValue?.contains("call it once") == true)
    }
}

/// Raw HTTP over a socket, for what URLSession won't send (malformed headers, exact lengths).
enum RawHTTP {
    struct Closed: Error {}

    static func connect(_ port: UInt16) throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(socket)
            throw POSIXError(.ECONNREFUSED)
        }
        return socket
    }

    /// Connects, and throws when the server refuses or closes the connection within `closedWithin`.
    static func connect(_ port: UInt16, closedWithin wait: Duration) throws -> Int32 {
        let socket = try connect(port)
        var timeout = timeval(tv_sec: 0, tv_usec: Int32(wait.components.attoseconds / 1_000_000_000_000))
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        if recv(socket, &byte, 1, 0) == 0 {
            close(socket)
            throw Closed()
        }
        close(socket)
        return socket
    }

    /// Sends a whole request and reads the answer until the server closes the connection.
    static func send(_ port: UInt16, _ request: String) throws -> String {
        let socket = try connect(port)
        defer { close(socket) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let bytes = Array(request.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { Darwin.send(socket, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break }
            sent += n
        }
        var answer = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = recv(socket, &buffer, buffer.count, 0)
            if n <= 0 { break }
            answer.append(contentsOf: buffer[..<n])
        }
        return String(decoding: answer, as: UTF8.self)
    }
}
