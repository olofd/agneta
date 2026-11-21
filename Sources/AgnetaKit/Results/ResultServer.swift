// The result server: Agneta's own MCP server, through which an engine's model submits a structured result.
//
// One loopback listener for all of Agneta, started the first time a session declares results, so an Agneta whose apps
// never use them has nothing new listening. Each session gets its own route and bearer token: knowing the port gives
// nothing, and a session can only reach its own route. The server keeps only that table; what a call means (which turn
// is open, whether the value is accepted) is the router's to decide, so the two can never disagree. It runs no command
// and touches no file. docs/ARCHITECTURE.md, Structured results.
import CryptoKit
import Foundation

/// What decides a result server's answers: the router. Each call names the route it came through, so a call that
/// passed the route check just before the session was reloaded (and given a new route) is told it's too late, never
/// fed to the reloaded session's turn.
public protocol ResultSessions: AnyObject, Sendable {
    /// The session's result tools, or nil when the route is no longer the session's.
    func resultTools(session: String, route: String) async -> [JSONValue]?
    /// A call of one of the session's result tools: the text the model reads, and whether it's an error.
    func submitResult(session: String, route: String, tool: String, arguments: JSONValue) async -> (
        text: String, isError: Bool
    )
}

public actor ResultServer {
    /// The MCP server name engines know it by. Reserved: an app's server can't take it.
    public static let name = "agneta-result"

    /// A session's way in. Its description leaves the bearer out, so printing one never leaks it.
    public struct Route: Sendable, Equatable, CustomStringConvertible {
        /// The route's id: the last part of its path.
        public var id: String
        public var url: String
        public var bearer: String
        public var description: String { "Route(\(url))" }
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
    /// Counts stops: a start that finishes after a stop finds it changed and stops what it started.
    private var stops = 0
    /// Route id → whose it is.
    private var routes: [String: Registration] = [:]

    /// Runs once a listener has started, before it's kept (tests: to land a stop in between).
    private let afterStart: (@Sendable () async -> Void)?

    public init(sessions: any ResultSessions) {
        self.sessions = sessions
        afterStart = nil
    }

    init(sessions: any ResultSessions, afterStart: @escaping @Sendable () async -> Void) {
        self.sessions = sessions
        self.afterStart = afterStart
    }

    /// The listener's port, starting it on first use.
    public func port() async throws -> UInt16 {
        // A listener that failed since is replaced: its routes still hold, on the new port.
        if let http, http.isListening { return http.port }
        http = nil
        if let starting { return try await starting.value }
        let generation = stops
        let afterStart = self.afterStart
        let task = Task<UInt16, Error> { [weak self] in
            let server = try LocalHTTPServer(port: 0) { [weak self] request in
                await self?.handle(request) ?? .init(status: 404)
            }
            try await server.start()
            await afterStart?()
            guard let self, await self.started(server, generation: generation) else {
                server.stop()
                throw CancellationError()
            }
            return server.port
        }
        starting = task
        do {
            return try await task.value
        } catch {
            if stops == generation { starting = nil } // a later session may try again
            throw error
        }
    }

    /// Keeps a listener that started, unless the server was stopped meanwhile.
    private func started(_ server: LocalHTTPServer, generation: Int) -> Bool {
        guard stops == generation else { return false }
        http = server
        starting = nil
        return true
    }

    /// A route for `session`: a fresh path and bearer, replacing any it had (a session reloaded gets new ones, as the
    /// app's own servers do).
    public func register(session: String) async throws -> Route {
        let port = try await port()
        unregister(session: session)
        let route = Self.hex(16), bearer = Self.hex(32)
        routes[route] = Registration(session: session, tokenHash: Data(SHA256.hash(data: Data(bearer.utf8))))
        return Route(id: route, url: "http://127.0.0.1:\(port)/result/\(route)", bearer: bearer)
    }

    /// Ends a session's route: its engine can reach nothing here any more.
    public func unregister(session: String) {
        routes = routes.filter { $0.value.session != session }
    }

    /// Stops listening (Agneta quitting); routes end with it.
    public func stop() {
        stops += 1
        starting?.cancel()
        starting = nil
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
                tools: { await sessions?.resultTools(session: session, route: route) },
                call: { name, arguments in
                    guard let sessions else { return ("Agneta is stopping", true) }
                    return await sessions.submitResult(session: session, route: route, tool: name, arguments: arguments)
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
