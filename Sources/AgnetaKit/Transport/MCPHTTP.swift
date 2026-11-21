// MCP over Streamable HTTP for Agneta's own servers (diagnostics, structured results): JSON-RPC requests in POST bodies,
// JSON responses (no event streams), notifications accepted with 202. Each server supplies who may call it and what its
// tools do; the framing, the methods every MCP server answers and the error shapes are here, once.
import CryptoKit
import Foundation

enum MCPHTTP {
    /// MCP versions these servers speak, oldest first: what they answer needs nothing a later one added.
    static let versions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    /// What one server answers.
    struct Server: Sendable {
        var name: String
        var instructions: String?
        /// The tools to list, or nil when the caller may not list them (an unknown route).
        var tools: @Sendable () async -> [JSONValue]?
        /// A tool call's answer: its text, and whether it's an error the model should act on.
        var call: @Sendable (_ name: String, _ arguments: JSONValue) async -> (text: String, isError: Bool)
    }

    /// Answers one HTTP request that already passed the server's own checks (path, credentials).
    static func respond(_ request: LocalHTTPServer.Request, server: Server) async -> LocalHTTPServer.Response {
        guard request.method == "POST" else { return .init(status: 405, headers: ["Allow": "POST"]) }
        guard let message = try? JSONCoding.decode(request.body) else {
            return .init(
                status: 400,
                body: Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#.utf8))
        }
        // JSON, but not one request: a batch (an array), or an object without a method.
        guard let method = message["method"]?.stringValue else {
            return .init(
                status: 400,
                body: Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}"#.utf8))
        }
        guard let id = message["id"] else { return .init(status: 202) } // a notification, e.g. notifications/initialized
        guard let rpcID = RPCID(id) else {
            return .init(
                status: 400,
                body: Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}"#.utf8))
        }
        let result: Result<JSONValue, RPCError>
        switch method {
        case "initialize":
            // The client's version when it's one this server speaks, else the latest it does (MCP's negotiation).
            let asked = message["params"]?["protocolVersion"]?.stringValue ?? ""
            var answer: JSONValue = [
                "protocolVersion": .string(versions.contains(asked) ? asked : versions.last!),
                "capabilities": ["tools": [:]], "serverInfo": ["name": .string(server.name), "version": "1"]
            ]
            if let instructions = server.instructions {
                answer = answer.setting("instructions", to: .string(instructions))
            }
            result = .success(answer)
        case "ping": result = .success([:])
        case "tools/list":
            if let tools = await server.tools() {
                result = .success(["tools": .array(tools)])
            } else {
                result = .failure(RPCError(code: RPCError.invalidParams, message: "Unknown server"))
            }
        case "tools/call":
            let name = message["params"]?["name"]?.stringValue ?? ""
            let arguments = message["params"]?["arguments"] ?? [:]
            let answer = await server.call(name, arguments)
            var content: JSONValue = ["content": [["type": "text", "text": .string(answer.text)]]]
            if answer.isError { content = content.setting("isError", to: true) }
            result = .success(content)
        default: result = .failure(RPCError(code: RPCError.methodNotFound, message: "Method not found: \(method)"))
        }
        let body = (try? RPCMessage.response(id: rpcID, result: result).encoded()) ?? Data()
        return .init(status: 200, body: body)
    }

    /// Whether an `Authorization: Bearer …` header carries the token with this SHA-256 hash, compared in constant time.
    static func authorized(_ header: String?, tokenHash: Data) -> Bool {
        guard let header, header.lowercased().hasPrefix("bearer ") else { return false }
        let given = Data(SHA256.hash(data: Data(header.dropFirst(7).trimmingCharacters(in: .whitespaces).utf8)))
        return given.count == tokenHash.count && zip(given, tokenHash).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static let unauthorized = LocalHTTPServer.Response(
        status: 401, headers: ["Content-Type": "application/json", "WWW-Authenticate": "Bearer"],
        body: Data(#"{"error":"unauthorized"}"#.utf8))
}
