import Foundation
import Testing

@testable import AgnetaClient

@MainActor final class ScriptedTransport: WebSocketTransport {
    var onSend: (@MainActor (JSONValue, ScriptedTransport) async throws -> Void)?
    var startAction: (@MainActor () async throws -> Void)?
    var sent: [JSONValue] = []
    var started = false
    var closed = false
    private var queue: [String] = []
    private var waiting: CheckedContinuation<String, any Error>?
    func start() async throws {
        try Task.checkCancellation()
        if let startAction { try await startAction() }
        try Task.checkCancellation(); started = true
    }
    func send(_ text: String) async throws {
        guard !closed else { throw AgnetaError(.connectionClosed, "closed") }
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        sent.append(value)
        try await onSend?(value, self)
    }
    func receive() async throws -> String {
        try Task.checkCancellation()
        guard !closed else { throw AgnetaError(.connectionClosed, "closed") }
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in waiting = continuation }
        } onCancel: {
            Task { @MainActor [weak self] in self?.close() }
        }
    }
    func close() {
        closed = true
        let continuation = waiting; waiting = nil
        continuation?.resume(throwing: AgnetaError(.connectionClosed, "closed"))
    }
    func feed(_ message: JSONValue) {
        feedText(String(decoding: try! JSONEncoder().encode(message), as: UTF8.self))
    }
    func feedText(_ text: String) {
        if let continuation = waiting {
            waiting = nil; continuation.resume(returning: text)
        } else {
            queue.append(text)
        }
    }
    func reply(_ request: JSONValue, result: JSONValue) {
        feed(["jsonrpc": "2.0", "id": request["id"]!, "result": result])
    }
    func fail(_ request: JSONValue, code: Int, message: String = "failure", data: JSONValue = [:]) {
        feed([
            "jsonrpc": "2.0", "id": request["id"]!,
            "error": ["code": .integer(Int64(code)), "message": .string(message), "data": data]
        ])
    }
    func notify(_ method: String, _ params: JSONValue) {
        feed(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }
    func update(_ id: String, _ update: JSONValue) {
        notify("session/update", ["sessionId": .string(id), "update": update])
    }
    func calls(_ method: String) -> [JSONValue] { sent.filter { $0["method"]?.string == method } }
}

let accessFixture: JSONValue = [
    "providers": [
        [
            "id": "p1", "label": "Test", "kind": "openai-key", "paused": false, "needsSignIn": false,
            "engines": ["goose"], "defaultEngine": "goose", "uncontained": [],
            "sandboxLevels": ["goose": ["contained", "developer"]]
        ]
    ],
    "engines": [["id": "goose", "name": "Goose", "state": "ready"]], "allowedEngines": "all",
    "scope": ["tools": "workspace", "folders": ["/tmp/workspace"], "sandbox": "contained"],
    "workspace": "/tmp/workspace"
]
let capabilitiesFixture: JSONValue = [
    "engine": "goose", "steer": true, "fork": true, "instructionsBetweenTurns": true, "reportsCost": true
]
let configFixture: JSONValue = [
    ["id": "model", "name": "Model", "type": "select", "currentValue": "test", "options": [], "category": "model"]
]
let catalogFixture: JSONValue = ["providers": [], "engines": [], "connected": true, "version": "dev"]

@MainActor final class StandIn {
    let transport = ScriptedTransport()
    var count = 0
    var remembered = true
    var extensions = ["agneta/access", "agneta/result"]
    var catalog = catalogFixture
    var overrides: (@MainActor (String, JSONValue, ScriptedTransport) async throws -> Bool)?
    var savedResults: JSONValue?
    init() {
        transport.onSend = { [weak self] message, transport in
            guard let self, let method = message["method"]?.string else { return }
            if try await overrides?(method, message, transport) == true { return }
            switch method {
            case "agneta/catalog": transport.reply(message, result: catalog)
            case "agneta/setup": transport.reply(message, result: ["shown": true])
            case "agneta/pair":
                transport.notify("agneta/pairingCode", ["code": "123456", "name": "Example"])
                transport.reply(
                    message,
                    result: [
                        "token": "secret-token", "remembered": .bool(remembered), "access": accessFixture, "unmet": []
                    ])
            case "initialize":
                transport.reply(
                    message,
                    result: [
                        "protocolVersion": 1, "agentCapabilities": [:],
                        "_meta": [
                            "agneta": ["extensions": .array(extensions.map(JSONValue.string)), "access": accessFixture]
                        ]
                    ])
            case "agneta/access": transport.reply(message, result: accessFixture)
            case "session/new", "session/load", "agneta/fork":
                count += 1
                let id = method == "session/load" ? message["params"]!["sessionId"]!.string! : "s\(count)"
                if let declaration = message["params"]?["_meta"]?[resultExtension] {
                    savedResults = [
                        "declared": .array(declaration["schemas"]!.object!.keys.sorted().map(JSONValue.string)),
                        "every": declaration["every"] ?? .null, "mechanism": "tool", "schemas": declaration["schemas"]!
                    ]
                }
                var agneta: [String: JSONValue] = [
                    "account": "p1", "dedicatedEngine": true, "sandbox": "contained",
                    "capabilities": capabilitiesFixture,
                    "resumed": .bool(method == "session/load")
                ]
                if let savedResults { agneta["results"] = savedResults }
                if method == "session/load" {
                    transport.update(
                        id, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "history"]])
                }
                transport.reply(
                    message,
                    result: [
                        "sessionId": .string(id), "configOptions": configFixture, "_meta": ["agneta": .object(agneta)]
                    ])
            case "session/prompt":
                let id = message["params"]!["sessionId"]!.string!
                transport.update(
                    id, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Hello"]])
                transport.reply(message, result: ["stopReason": "end_turn"])
            case "session/close", "session/set_config_option", "session/set_mode", "agneta/instructions/set":
                transport.reply(message, result: [:])
            case "agneta/steer": transport.reply(message, result: ["delivery": "accepted", "runId": .null])
            default: if message["id"] != nil { transport.fail(message, code: -32601) }
            }
        }
    }
    func client(tokens: (any TokenStore)? = nil, configure: (inout ClientOptions) -> Void = { _ in }) throws
        -> AgnetaClient
    {
        var options = ClientOptions(name: "Example", tokens: tokens)
        options.transport = { [transport] _ in transport }
        configure(&options)
        return try AgnetaClient(options: options)
    }
}

@MainActor func eventually(_ condition: @MainActor () -> Bool) async throws {
    let start = ContinuousClock.now
    while !condition() {
        if start.duration(to: .now) > .seconds(3) {
            Issue.record("Condition did not become true"); throw AgnetaError(.timeout, "test wait")
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}
@MainActor func expectKind<T>(_ kind: AgnetaError.Kind, _ body: @MainActor () async throws -> T) async {
    do { _ = try await body(); Issue.record("Expected \(kind)") } catch let error as AgnetaError {
        #expect(error.kind == kind)
    } catch { Issue.record("Expected \(kind), got \(error)") }
}
