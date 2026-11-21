// The result server over real HTTP on loopback: started on first use, one route and bearer per session, MCP's methods,
// and every way a caller is turned away.
import Foundation
import Testing

@testable import AgnetaKit

@Suite struct ResultServerTests {
    /// Stands in for the router: records calls and answers as told.
    final class Sessions: ResultSessions, @unchecked Sendable {
        let lock = NSLock()
        var calls: [(session: String, tool: String, arguments: JSONValue)] = []
        var tools: [String: [JSONValue]] = [:]

        func resultTools(session: String) async -> [JSONValue]? { lock.withLock { tools[session] } }

        func submitResult(session: String, tool: String, arguments: JSONValue) async -> (text: String, isError: Bool) {
            lock.withLock { calls.append((session, tool, arguments)) }
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

    @Test func refusesBodiesOverTheCap() async throws {
        let server = ResultServer(sessions: Sessions())
        defer { Task { await server.stop() } }
        let route = try await server.register(session: "s1")
        let huge = Data(repeating: UInt8(ascii: " "), count: (1 << 20) + 1)
        let reply = try? await Self.post(route.url, huge, bearer: route.bearer)
        // Turned away: a 400, or the connection closed before a reply.
        #expect(reply == nil || reply?.status == 400)
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
