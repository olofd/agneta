import Foundation

public struct RequestOptions: Sendable {
    /// Seconds; zero means no deadline. Nil uses the connection default (30 seconds).
    public var timeout: TimeInterval?
    public init(timeout: TimeInterval? = nil) { self.timeout = timeout }
}
public enum ConnectionEvent: Sendable, Equatable {
    case notification(method: String, params: JSONValue)
    /// Tokens are redacted; the value is detached from the message delivered to callers.
    case message(JSONValue, direction: Direction)
    case closed(AgnetaError)
    public enum Direction: Sendable { case incoming, outgoing }
}

/// JSON-RPC over a WebSocket. A timeout or cancellation ends only that request; late responses are ignored.
@MainActor public final class Connection {
    public let url: URL
    public let requestTimeout: TimeInterval
    public private(set) var isOpen = true
    public private(set) var closeError: AgnetaError?
    public typealias Handler = @MainActor (JSONValue) async throws -> JSONValue
    private let transport: any WebSocketTransport
    private let events = EventHub<ConnectionEvent>()
    private var receiver: Task<Void, Never>?
    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<JSONValue, any Error>
        var timer: Task<Void, Never>?
        var sender: Task<Void, Never>?
    }
    private var pending: [String: Pending] = [:]
    private var handlers: [String: (UUID, Handler)] = [:]
    private var lastSend: Task<Void, any Error>?
    private var sends: [UUID: Task<Void, any Error>] = [:]
    private var lastSendID: UUID?
    private var answering: [UUID: Task<Void, Never>] = [:]

    private init(url: URL, transport: any WebSocketTransport, requestTimeout: TimeInterval) {
        self.url = url; self.transport = transport; self.requestTimeout = requestTimeout
        receiver = Task { @MainActor [weak self, transport] in
            do {
                while !Task.isCancelled {
                    let text = try await transport.receive()
                    guard let self else { transport.close(); return }
                    self.receive(text)
                }
            } catch {
                self?.finish(error as? AgnetaError ?? AgnetaError(.connectionClosed, error.localizedDescription))
            }
        }
    }

    /// Custom transports are useful for tests. The default transport never redirects or sends an Origin header.
    public static func open(
        url: URL = AgnetaBuild.release.url, connectTimeout: TimeInterval = 5,
        requestTimeout: TimeInterval = 30, transport: (any WebSocketTransport)? = nil
    ) async throws -> Connection {
        try Task.checkCancellation()
        guard ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
            url.user == nil, url.password == nil, url.fragment == nil
        else {
            throw AgnetaError(.invalidParams, "Expected a WebSocket URL without credentials or a fragment.")
        }
        guard requestTimeout.isFinite, requestTimeout >= 0 else {
            throw AgnetaError(.invalidParams, "Invalid request timeout.")
        }
        let transport = transport ?? FoundationTransport(url: url)
        do {
            try await withDeadline(connectTimeout, method: "connect") { try await transport.start() }
            try Task.checkCancellation()
            return Connection(url: url, transport: transport, requestTimeout: requestTimeout)
        } catch {
            transport.close()
            throw transportError(error)
        }
    }
    deinit {
        receiver?.cancel()
        let transport = transport
        Task { @MainActor in transport.close() }
    }

    @discardableResult public func onEvent(_ listener: @escaping @MainActor (ConnectionEvent) -> Void)
        -> @MainActor () -> Void
    {
        events.on(listener)
    }
    /// Replacing a handler returns an unsubscribe function that cannot remove a later replacement.
    @discardableResult public func handle(_ method: String, handler: @escaping Handler) -> @MainActor () -> Void {
        let id = UUID()
        handlers[method] = (id, handler)
        return { [weak self] in if self?.handlers[method]?.0 == id { self?.handlers.removeValue(forKey: method) } }
    }
    public func request(_ method: String, params: JSONValue = [:], options: RequestOptions = .init()) async throws
        -> JSONValue
    {
        try await request(method, params: params, options: options, onEnqueued: nil)
    }
    func request(
        _ method: String, params: JSONValue, options: RequestOptions,
        onEnqueued: (@MainActor () -> Void)?
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        guard isOpen else { throw closeError ?? AgnetaError(.connectionClosed, "The connection is closed.") }
        let timeout = options.timeout ?? requestTimeout
        guard timeout.isFinite, timeout >= 0 else {
            throw AgnetaError(.invalidParams, "Invalid request timeout.", method: method)
        }
        let id = UUID().uuidString
        let message: JSONValue = ["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": params]
        // Encode before installing the continuation so invalid caller data cannot leave a pending request.
        let text = try encode(message)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = Pending(method: method, continuation: continuation)
                if timeout > 0 {
                    pending[id]?.timer = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                        self?.settle(
                            id,
                            .failure(
                                AgnetaError(.timeout, "\(method) timed out after \(timeout) seconds.", method: method)))
                    }
                }
                let sent = enqueue(message, text: text, requestID: id)
                pending[id]?.sender = Task { @MainActor [weak self] in
                    do { try await sent.value } catch { self?.settle(id, .failure(transportError(error))) }
                }
                onEnqueued?()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.settle(id, .failure(CancellationError())) }
        }
    }
    public func request<Params: Encodable, Result: Decodable>(
        _ method: String, params: Params,
        as type: Result.Type, options: RequestOptions = .init()
    ) async throws -> Result {
        let value = try await request(method, params: JSONValue(encoding: params), options: options)
        return try decodeResult(value, as: type, method: method)
    }
    public func notify(_ method: String, params: JSONValue = [:]) async throws {
        try Task.checkCancellation()
        guard isOpen else { throw closeError ?? AgnetaError(.connectionClosed, "The connection is closed.") }
        let message: JSONValue = ["jsonrpc": "2.0", "method": .string(method), "params": params]
        let text = try encode(message)
        let sent = enqueue(message, text: text)
        do {
            try await withTaskCancellationHandler {
                try await withDeadline(0, method: method) { try await sent.value }
            } onCancel: {
                sent.cancel()
            }
        } catch { throw transportError(error) }
    }

    // Enqueue synchronously before yielding. Requests, controls and replies all share this writer, so an async
    // transport cannot let cancel/steer or a later frame overtake a prompt whose send is still suspended.
    private func enqueue(_ message: JSONValue, text: String, requestID: String? = nil) -> Task<Void, any Error> {
        let previous = lastSend, key = UUID()
        let sent = Task { @MainActor [weak self, transport] in
            if let previous { _ = try? await previous.value }
            guard let self, isOpen else { throw AgnetaError(.connectionClosed, "The connection is closed.") }
            try Task.checkCancellation()
            // A request that expired before reaching the writer must never be sent later.
            if let requestID, pending[requestID] == nil { return }
            events.emit(.message(redacted(message), direction: .outgoing))
            guard isOpen else { throw closeError ?? AgnetaError(.connectionClosed, "The connection is closed.") }
            if let requestID, pending[requestID] == nil { return }
            do {
                try await withDeadline(requestTimeout, method: "send") { try await transport.send(text) }
            } catch {
                if isOpen {
                    finish(AgnetaError(.connectionClosed, "Could not send to Agneta: \(error.localizedDescription)"))
                }
                throw error
            }
        }
        lastSend = sent; lastSendID = key; sends[key] = sent
        Task { @MainActor [weak self] in
            _ = try? await sent.value
            self?.sends.removeValue(forKey: key)
            if self?.lastSendID == key { self?.lastSend = nil; self?.lastSendID = nil }
        }
        return sent
    }
    public func close() { finish(AgnetaError(.connectionClosed, "Closed by the app.")) }

    private func encode(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    private func settle(_ id: String, _ result: Result<JSONValue, any Error>) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.timer?.cancel(); call.sender?.cancel()
        call.continuation.resume(with: result)
    }
    private func receive(_ text: String) {
        guard isOpen else { return }
        guard text.utf8.count <= 16 * 1024 * 1024, withinJSONDepth(text) else {
            finish(AgnetaError(.protocolViolation, "Agneta sent a message exceeding the size or nesting limit."));
            return
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            finish(AgnetaError(.protocolViolation, "Agneta sent invalid JSON.")); return
        }
        // Agneta uses one object per frame; raw peers may send JSON-RPC batches too.
        for message in value.array ?? [value] { dispatch(message) }
    }
    private func dispatch(_ message: JSONValue) {
        guard isOpen, message["jsonrpc"]?.string == "2.0", message.object != nil else { return }
        events.emit(.message(redacted(message), direction: .incoming))
        guard isOpen else { return }
        if let method = message["method"]?.string {
            let params = message["params"] ?? .null
            if let id = message["id"], id != .null {
                guard id.string != nil || id.integer != nil else { return }
                let key = UUID()
                let handler = handlers[method]?.1
                answering[key] = Task { @MainActor [weak self] in
                    let response: JSONValue
                    do {
                        guard let handler else {
                            throw AgnetaError.rpc(code: -32601, message: "No handler for \(method)")
                        }
                        let result = try await handler(params)
                        response = ["jsonrpc": "2.0", "id": id, "result": result]
                    } catch {
                        let failure = error as? AgnetaError
                        response = [
                            "jsonrpc": "2.0", "id": id,
                            "error": [
                                "code": .integer(Int64(failure?.code ?? -32603)),
                                "message": .string(failure?.message ?? "The app could not answer this request.")
                            ]
                        ]
                    }
                    guard let self else { return }
                    answering.removeValue(forKey: key)
                    guard isOpen, !Task.isCancelled else { return }
                    let reply: JSONValue
                    let text: String
                    do { text = try encode(response); reply = response } catch {
                        reply = [
                            "jsonrpc": "2.0", "id": id,
                            "error": ["code": -32603, "message": "The app handler returned a value that is not JSON."]
                        ]
                        guard let encoded = try? encode(reply) else { return }
                        text = encoded
                    }
                    _ = try? await enqueue(reply, text: text).value
                }
            } else {
                events.emit(.notification(method: method, params: params))
            }
            return
        }
        guard let id = message["id"]?.string, let call = pending[id] else { return }
        let result = message["result"], error = message["error"]
        if (result != nil) == (error != nil) {
            settle(
                id,
                .failure(
                    AgnetaError(
                        .protocolViolation, "A JSON-RPC response must contain exactly one of result or error.",
                        method: call.method)))
        } else if let error {
            guard let code = error["code"]?.integer, let numericCode = Int(exactly: code),
                let text = error["message"]?.string
            else {
                settle(id, .failure(AgnetaError(.protocolViolation, "Malformed JSON-RPC error.", method: call.method)));
                return
            }
            settle(
                id,
                .failure(AgnetaError.rpc(code: numericCode, message: text, data: error["data"], method: call.method)))
        } else if let result {
            settle(id, .success(result))
        }
    }
    func invalidate(_ error: AgnetaError) { finish(error) }

    private func finish(_ error: AgnetaError) {
        guard isOpen else { return }
        isOpen = false; closeError = error
        receiver?.cancel(); receiver = nil
        transport.close()
        for send in sends.values { send.cancel() }
        sends.removeAll(); lastSend = nil; lastSendID = nil
        for id in Array(pending.keys) { settle(id, .failure(error)) }
        for task in answering.values { task.cancel() }
        answering.removeAll(); handlers.removeAll()
        events.emit(.closed(error))
    }
}

func decodeResult<T: Decodable>(_ value: JSONValue, as type: T.Type = T.self, method: String) throws -> T {
    do { return try value.decode(type) } catch {
        throw AgnetaError(.protocolViolation, "Agneta returned an invalid result for \(method).", method: method)
    }
}

private func redacted(_ message: JSONValue) -> JSONValue {
    guard var object = message.object else { return message }
    if var params = object["params"]?.object, var meta = params["_meta"]?.object, var agneta = meta["agneta"]?.object,
        agneta["token"] != nil
    {
        agneta["token"] = "[redacted]"; meta["agneta"] = .object(agneta); params["_meta"] = .object(meta);
        object["params"] = .object(params)
    }
    if var result = object["result"]?.object, result["token"] != nil {
        result["token"] = "[redacted]"; object["result"] = .object(result)
    }
    return .object(object)
}

// Bound recursive decoding before asking Foundation to construct the value. Brackets inside strings are data.
private func withinJSONDepth(_ text: String) -> Bool {
    var depth = 0, inString = false, escaped = false
    for byte in text.utf8 {
        if inString {
            if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { inString = false }
        } else if byte == 34 {
            inString = true
        } else if byte == 123 || byte == 91 {
            depth += 1; if depth > 128 { return false }
        } else if byte == 125 || byte == 93 {
            depth -= 1
        }
    }
    return true
}
