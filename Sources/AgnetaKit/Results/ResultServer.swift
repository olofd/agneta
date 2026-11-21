// The result server: Agneta's own MCP server, through which an engine's model submits a structured result.
//
// One loopback listener for all of Agneta, started the first time a session declares results, so an Agneta whose apps
// never use them has nothing new listening. Each session gets its own route and bearer token: knowing the port gives
// nothing, and a session can only reach its own route. The server keeps only that table; what a call means (which turn
// is open, whether the value is accepted) is the router's to decide, so the two can never disagree. It runs no command
// and touches no file. docs/ARCHITECTURE.md, The result server.
import CryptoKit
import Foundation

/// What decides a result server's answers: the router.
public protocol ResultSessions: AnyObject, Sendable {
    /// The session's result tools, or nil when it has none (it ended).
    func resultTools(session: String) async -> [JSONValue]?
    /// A call of one of the session's result tools: the text the model reads, and whether it's an error.
    func submitResult(session: String, tool: String, arguments: JSONValue) async -> (text: String, isError: Bool)
}

public actor ResultServer {
    /// The MCP server name engines know it by. Reserved: an app's server can't take it.
    public static let name = "agneta-result"

    /// A session's way in.
    public struct Route: Sendable, Equatable {
        public var url: String
        public var bearer: String
        /// As ACP's `mcpServers` entry: the server the engine is given for the session.
        public var server: JSONValue {
            [
                "type": "http", "name": .string(ResultServer.name), "url": .string(url),
                "headers": [["name": "Authorization", "value": .string("Bearer \(bearer)")]]
            ]
        }
    }

    private struct Registration {
        var session: String
        var tokenHash: Data
    }

    private weak var sessions: (any ResultSessions)?
    private var http: LocalHTTPServer?
    private var starting: Task<UInt16, Error>?
    /// Route id → whose it is.
    private var routes: [String: Registration] = [:]

    public init(sessions: any ResultSessions) {
        self.sessions = sessions
    }

    /// The listener's port, starting it on first use.
    public func port() async throws -> UInt16 {
        if let http { return http.port }
        if let starting { return try await starting.value }
        let task = Task<UInt16, Error> { [weak self] in
            let server = try LocalHTTPServer(port: 0) { [weak self] request in
                await self?.handle(request) ?? .init(status: 404)
            }
            try await server.start()
            await self?.started(server)
            return server.port
        }
        starting = task
        do {
            return try await task.value
        } catch {
            starting = nil // a later session may try again
            throw error
        }
    }

    private func started(_ server: LocalHTTPServer) {
        http = server
        starting = nil
    }

    /// A route for `session`: a fresh path and bearer, replacing any it had (a session reloaded gets new ones, as the
    /// app's own servers do).
    public func register(session: String) async throws -> Route {
        let port = try await port()
        unregister(session: session)
        let route = Self.hex(16), bearer = Self.hex(32)
        routes[route] = Registration(session: session, tokenHash: Data(SHA256.hash(data: Data(bearer.utf8))))
        return Route(url: "http://127.0.0.1:\(port)/result/\(route)", bearer: bearer)
    }

    /// Ends a session's route: its engine can reach nothing here any more.
    public func unregister(session: String) {
        routes = routes.filter { $0.value.session != session }
    }

    /// Stops listening (Agneta quitting); routes end with it.
    public func stop() {
        http?.stop()
        http = nil
        routes = [:]
    }

    static func hex(_ count: Int) -> String { SecureRandom.bytes(count).map { String(format: "%02x", $0) }.joined() }

    /// How many sessions have a route (for tests and diagnostics).
    public var routeCount: Int { routes.count }

    func handle(_ request: LocalHTTPServer.Request) async -> LocalHTTPServer.Response {
        let path = request.path.split(separator: "?").first.map(String.init) ?? ""
        guard path.hasPrefix("/result/") else { return .init(status: 404) }
        let route = String(path.dropFirst("/result/".count))
        // An unknown route and a wrong token answer alike, so neither reveals which routes exist.
        guard let registration = routes[route],
            MCPHTTP.authorized(request.headers["authorization"], tokenHash: registration.tokenHash)
        else { return MCPHTTP.unauthorized }
        let session = registration.session
        let sessions = self.sessions
        return await MCPHTTP.respond(
            request,
            server: MCPHTTP.Server(
                name: Self.name,
                instructions: "Submit the result a request asks for, once your work for it is done.",
                tools: { await sessions?.resultTools(session: session) },
                call: { name, arguments in
                    guard let sessions else { return ("Agneta is stopping", true) }
                    return await sessions.submitResult(session: session, tool: name, arguments: arguments)
                }))
    }

    // MARK: Tools

    /// The tools a declaration offers: one per schema, `submit_<name>`, whose input is the schema itself.
    public static func tools(_ declaration: ResultDeclaration) -> [JSONValue] {
        declaration.names.map { name in
            let schema = declaration.schemas[name]!
            var description =
                "Submit the \(name) result once your work for the request is done: call it once, with the result "
                + "itself as the arguments."
            if let about = schema.source["description"]?.stringValue { description += " The result: " + about }
            return [
                "name": .string(ResultDeclaration.tool(for: name)), "description": .string(description),
                "inputSchema": schema.source,
                // Claude Code defers MCP tools behind its tool search unless a tool asks to be loaded: a result tool the
                // model has to search for is one it may not call.
                "_meta": ["anthropic/alwaysLoad": true]
            ]
        }
    }
}
