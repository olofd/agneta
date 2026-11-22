import Foundation

public enum SessionEnd: Sendable, Equatable {
    case closed
    case stopped(by: String, detail: String?)
    case disconnected(AgnetaError)
}
public enum SessionEvent: Sendable, Equatable {
    case update(SessionUpdate)
    case queued(position: Int, waitingFor: String?)
    case rateLimited(JSONValue)
    case trace([TraceRecord])
    case traceOverflow(after: Int64)
    case configOptions([ConfigOption])
    case mode(String)
    case ended(SessionEnd)
}
public enum TurnEvent: Sendable, Equatable {
    case update(SessionUpdate)
    case queued(position: Int, waitingFor: String?)
    case rateLimited(JSONValue)
    case stopped(by: String, detail: String?)
}
public struct TurnResult: Sendable, Equatable {
    public let stopReason: String
    public let text: String
    public let thought: String
    public let usage: AgnetaUsage?
    public let engineUsage: JSONValue?
    public let limit: LimitHit?
    public let stoppedBy: String?
    public let toolCalls: [ToolCallState]
    public let resultCalls: [ToolCallState]
    public let raw: JSONValue
    public var structured: StructuredResult? {
        raw["_meta"]?[resultExtension].flatMap { try? StructuredResult(raw: $0) }
    }
    public var cancelled: Bool { stopReason == "cancelled" }
}

/// One prompt. Events replay from the start for each new stream. Await `result` for the accumulated reply.
@MainActor public final class Turn {
    public let session: Session
    public private(set) var text = ""
    public private(set) var thought = ""
    private var calls: [ToolCallState] = []
    public var toolCalls: [ToolCallState] { calls.filter { $0.raw["_meta"]?["agneta"]?["result"] == nil } }
    public var resultCalls: [ToolCallState] { calls.filter { $0.raw["_meta"]?["agneta"]?["result"] != nil } }
    public private(set) var history: [TurnEvent] = []
    public private(set) var done = false
    private var stoppedBy: String?
    private var completion: Result<TurnResult, any Error>?
    private var running: Task<TurnResult, any Error>?
    private var enqueued = false
    private var enqueueWaiters: [CheckedContinuation<Void, Never>] = []
    private var subscribers: [UUID: AsyncThrowingStream<TurnEvent, any Error>.Continuation] = [:]
    private let maximumEvents: Int
    private let maximumBytes: Int
    private var bufferedBytes = 0

    init(session: Session, maximumEvents: Int, maximumBytes: Int) {
        self.session = session; self.maximumEvents = maximumEvents; self.maximumBytes = maximumBytes
    }
    func start(prompt: [ContentBlock], meta: [String: JSONValue], timeout: TimeInterval) {
        running = Task { @MainActor [self] in
            do {
                var params: [String: JSONValue] = [
                    "sessionId": .string(session.id), "prompt": try JSONValue(encoding: prompt)
                ]
                if !meta.isEmpty { params["_meta"] = .object(meta) }
                let raw: JSONValue
                do {
                    raw = try await session.request(
                        "session/prompt", params: .object(params), options: .init(timeout: timeout),
                        onEnqueued: { [self] in markEnqueued() })
                } catch {
                    // Ending our wait does not stop the engine; explicitly cancel the running turn too.
                    if error is CancellationError || (error as? AgnetaError)?.kind == .timeout {
                        try? await session.cancel()
                    }
                    throw error
                }
                if case .failure(let failure) = completion { throw failure }
                guard let stopReason = raw["stopReason"]?.string else {
                    throw AgnetaError(.protocolViolation, "Prompt result has no stopReason.")
                }
                let usage: AgnetaUsage? = try raw["_meta"]?["agneta/usage"].map {
                    try decodeResult($0, method: "session/prompt usage")
                }
                let limit: LimitHit? = try raw["_meta"]?["agneta/limit"].map {
                    try decodeResult($0, method: "session/prompt limit")
                }
                let result = TurnResult(
                    stopReason: stopReason, text: text, thought: thought, usage: usage,
                    engineUsage: raw["usage"], limit: limit,
                    stoppedBy: stoppedBy ?? (limit?.sessionEnded == true ? "limit" : nil),
                    toolCalls: toolCalls, resultCalls: resultCalls, raw: raw)
                finish(.success(result))
                return result
            } catch {
                // A replay-buffer failure takes precedence over the request's subsequent cancellation.
                if case .failure(let failure) = completion { throw failure }
                finish(.failure(error)); throw error
            }
        }
    }
    /// Cancelling the task awaiting this property asks Agneta to cancel the turn; its result still reports why it ended.
    public var result: TurnResult {
        get async throws {
            guard let running else { throw AgnetaError(.internalError, "The turn has not started.") }
            return try await withTaskCancellationHandler {
                try await running.value
            } onCancel: {
                Task { @MainActor [weak self] in try? await self?.cancel() }
            }
        }
    }
    /// Each access creates an independent stream, including events already received. Slow streams are bounded;
    /// overflow closes the connection and its sessions rather than silently dropping chunks.
    public var events: AsyncThrowingStream<TurnEvent, any Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<TurnEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(maximumEvents))
        for event in history { continuation.yield(event) }
        if let completion {
            switch completion {
            case .success: continuation.finish();
            case .failure(let error): continuation.finish(throwing: error)
            }
        } else {
            subscribers[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.subscribers.removeValue(forKey: id) }
            }
        }
        return stream
    }
    public func cancel() async throws {
        guard !done, session.turn === self else { return }
        try await session.cancel()
    }
    func waitUntilEnqueued() async {
        if enqueued || done { return }
        await withCheckedContinuation { enqueueWaiters.append($0) }
    }
    private func markEnqueued() {
        enqueued = true
        let waiters = enqueueWaiters; enqueueWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    public func steer(_ text: String) async throws -> JSONValue { try await steer([.text(text)]) }
    public func steer(_ content: [ContentBlock]) async throws -> JSONValue {
        await waitUntilEnqueued()
        guard !done, session.turn === self else { throw AgnetaError(.noTurnRunning, "This turn has ended.") }
        return try await session.steer(content)
    }
    func push(_ event: TurnEvent) {
        guard !done else { return }
        let bytes: Int
        switch event {
        case .update(let update): bytes = update.raw.payloadSize
        case .rateLimited(let value): bytes = value.payloadSize
        case .stopped(let by, let detail): bytes = by.utf8.count + (detail?.utf8.count ?? 0) + 64
        case .queued: bytes = 64
        }
        guard history.count < maximumEvents, bytes <= maximumBytes - bufferedBytes else {
            let error = AgnetaError(
                .bufferOverflow,
                "The turn exceeded its replay buffer. Increase ClientOptions.buffers for larger retained turns.")
            finish(.failure(error))
            // Synchronous shutdown prevents a late cancel from ever targeting a subsequent prompt.
            session.connection.invalidate(error)
            return
        }
        if case .update(let update) = event {
            if update.kind == "agent_message_chunk" { text += update.text ?? "" }
            if update.kind == "agent_thought_chunk" { thought += update.text ?? "" }
            if ["tool_call", "tool_call_update"].contains(update.kind), let id = update.toolCallID,
                var fields = update.raw.object
            {
                fields.removeValue(forKey: "sessionUpdate")
                if let index = calls.firstIndex(where: { $0.id == id }) {
                    calls[index].raw.merge(fields, uniquingKeysWith: { _, latest in latest })
                } else {
                    calls.append(ToolCallState(id: id, raw: fields))
                }
            }
        }
        if case .stopped(let by, _) = event { stoppedBy = by }
        bufferedBytes += bytes
        history.append(event)
        for continuation in subscribers.values { continuation.yield(event) }
    }
    private func finish(_ result: Result<TurnResult, any Error>) {
        guard !done else { return }
        completion = result; done = true
        markEnqueued()
        session.release(self)
        for continuation in subscribers.values {
            switch result {
            case .success: continuation.finish();
            case .failure(let error): continuation.finish(throwing: error)
            }
        }
        subscribers.removeAll()
    }
}

/// A handle belongs to the connection it opened on. Reloading a task retires its previous handle.
@MainActor public final class Session {
    public let id: String
    public let raw: JSONValue
    public let connection: Connection
    public private(set) var history: [SessionUpdate] = []
    public private(set) var configOptions: [ConfigOption]
    public private(set) var modes: JSONValue?
    public private(set) var turn: Turn?
    public private(set) var ended: SessionEnd?
    public var permissions: PermissionHandler?
    public let capabilities: SessionCapabilities
    public var engine: String { capabilities.engine }
    public var account: String? { raw["_meta"]?["agneta"]?["account"]?.string }
    public var sandbox: String? { raw["_meta"]?["agneta"]?["sandbox"]?.string }
    public var appTools: JSONValue? { raw["_meta"]?["agneta"]?["appTools"] }
    public var builtins: [String]? { raw["_meta"]?["agneta"]?["builtins"]?.array?.compactMap(\.string) }
    public var dedicatedEngine: Bool { raw["_meta"]?["agneta"]?["dedicatedEngine"]?.bool == true }
    public var resumed: Bool { raw["_meta"]?["agneta"]?["resumed"]?.bool == true }
    public var forkOf: String? { raw["_meta"]?["agneta"]?["forkOf"]?.string }
    public var results: SessionResults? { try? raw["_meta"]?["agneta"]?["results"]?.decode() }
    public func supports(_ name: String) -> Bool { extensions.contains(name) }
    private let extensions: [String]
    public var model: ConfigOption? { option(category: "model") }
    public var effort: ConfigOption? { option(category: "thought_level") }
    private weak var client: AgnetaClient?
    private let events = EventHub<SessionEvent>()
    private let timeouts: Timeouts
    private let buffers: BufferLimits

    init(client: AgnetaClient, connection: Connection, id: String, raw: JSONValue, options: SessionOptions) throws {
        guard let capabilities = raw["_meta"]?["agneta"]?["capabilities"] else {
            throw AgnetaError(.protocolViolation, "Session result has no capabilities.")
        }
        self.capabilities = try decodeResult(capabilities, method: "session/new capabilities")
        self.client = client; self.connection = connection; self.id = id; self.raw = raw
        extensions = client.extensions
        buffers = client.options.buffers
        timeouts = client.options.timeouts; permissions = options.permissions
        configOptions =
            try raw["configOptions"].flatMap { $0 == .null ? nil : try decodeResult($0, method: "session config") }
            ?? []
        modes = raw["modes"] == .null ? nil : raw["modes"]
        if let listener = options.onEvent { _ = events.on(listener) }
    }
    @discardableResult public func onEvent(_ listener: @escaping @MainActor (SessionEvent) -> Void)
        -> @MainActor () -> Void
    { events.on(listener) }
    public func prompt(
        _ text: String, options: RequestOptions = .init(), meta: [String: JSONValue] = [:], result: ResultAsk? = nil
    ) throws -> Turn {
        try prompt([.text(text)], options: options, meta: meta, result: result)
    }
    public func prompt(
        _ content: [ContentBlock], options: RequestOptions = .init(), meta: [String: JSONValue] = [:],
        result: ResultAsk? = nil
    ) throws -> Turn {
        try requireActive()
        if let turn, !turn.done { throw AgnetaError(.turnBusy, "A turn is already running; steer it or wait.") }
        var meta = meta
        if let result {
            guard supports(resultExtension) else {
                throw AgnetaError(.unsupportedByAgneta, "This Agneta does not offer structured results.")
            }
            meta[resultExtension] = try result.wire()
        }
        let turn = Turn(session: self, maximumEvents: buffers.turnEvents, maximumBytes: buffers.turnBytes)
        self.turn = turn
        turn.start(prompt: content, meta: meta, timeout: options.timeout ?? timeouts.prompt)
        return turn
    }
    public func cancel() async throws {
        try requireActive()
        if let current = turn {
            await current.waitUntilEnqueued()
            guard !current.done, turn === current else { return }
        }
        try requireActive()
        try await connection.notify("session/cancel", params: ["sessionId": .string(id)])
    }
    public func steer(_ text: String) async throws -> JSONValue { try await steer([.text(text)]) }
    public func steer(_ content: [ContentBlock]) async throws -> JSONValue {
        try await request(
            "agneta/steer", params: ["sessionId": .string(id), "prompt": try JSONValue(encoding: content)])
    }
    public func close(options: RequestOptions = .init()) async throws {
        guard ended == nil else { return }
        do { _ = try await request("session/close", params: ["sessionId": .string(id)], options: options) } catch let
            error as AgnetaError where error.kind == .invalidParams && error.message == "Unknown session"
        {}
        end(.closed)
    }
    @discardableResult public func setConfigOption(_ id: String, value: JSONValue) async throws -> [ConfigOption] {
        let raw = try await request(
            "session/set_config_option",
            params: ["sessionId": .string(self.id), "configId": .string(id), "value": value])
        if let options = raw["configOptions"] {
            configOptions = try decodeResult(options, method: "session/set_config_option")
        } else if let index = configOptions.firstIndex(where: { $0.id == id }),
            var fields = configOptions[index].raw.object
        {
            fields["currentValue"] = value; configOptions[index] = try ConfigOption(raw: .object(fields))
        }
        events.emit(.configOptions(configOptions)); return configOptions
    }
    @discardableResult public func setModel(_ model: String) async throws -> [ConfigOption] {
        try await setCategory("model", value: model)
    }
    @discardableResult public func setEffort(_ effort: String) async throws -> [ConfigOption] {
        try await setCategory("thought_level", value: effort)
    }
    public func setMode(_ mode: String) async throws {
        _ = try await request("session/set_mode", params: ["sessionId": .string(id), "modeId": .string(mode)])
        if var state = modes?.object { state["currentModeId"] = .string(mode); modes = .object(state) }
        events.emit(.mode(mode))
    }
    public func setInstructions(_ text: String, mode: String = "replace", key: String? = nil) async throws {
        var params: [String: JSONValue] = ["sessionId": .string(id), "text": .string(text), "mode": .string(mode)]
        if let key { params["key"] = .string(key) }
        _ = try await request("agneta/instructions/set", params: .object(params))
    }
    public func fork(_ options: SessionOptions = .init()) async throws -> Session {
        guard let client else { throw AgnetaError(.connectionClosed, "The owning client has been released.") }
        return try await client.fork(id, options: options)
    }
    public func readTrace(after: Int64 = 0, types: [String]? = nil, limit: Int = 500) async throws -> TracePage {
        guard let client else { throw AgnetaError(.connectionClosed, "The owning client has been released.") }
        return try await client.readTrace(id, after: after, types: types, limit: limit)
    }
    func request(
        _ method: String, params: JSONValue, options: RequestOptions = .init(),
        onEnqueued: (@MainActor () -> Void)? = nil
    ) async throws -> JSONValue {
        try requireActive()
        if method != "session/prompt", let current = turn {
            await current.waitUntilEnqueued()
            if method == "agneta/steer", current.done || turn !== current {
                throw AgnetaError(.noTurnRunning, "This turn has ended.")
            }
        }
        try requireActive()
        return try await connection.request(method, params: params, options: options, onEnqueued: onEnqueued)
    }
    private func requireActive() throws {
        if case .disconnected(let error) = ended { throw error }
        guard ended == nil else { throw AgnetaError(.invalidParams, "This session handle has ended.") }
    }
    private func option(category: String) -> ConfigOption? {
        configOptions.first { $0.category == category }
            ?? (category == "model" ? configOptions.first { $0.id == "model" } : nil)
    }
    private func setCategory(_ category: String, value: String) async throws -> [ConfigOption] {
        guard let option = option(category: category) else {
            throw AgnetaError(.invalidParams, "This engine offers no \(category) setting.")
        }
        return try await setConfigOption(option.id, value: .string(value))
    }
    func release(_ turn: Turn) { if self.turn === turn { self.turn = nil } }
    func end(_ reason: SessionEnd) {
        guard ended == nil else { return }
        ended = reason; client?.forget(self); events.emit(.ended(reason))
    }
    func receive(_ method: String, params: JSONValue, replay: Bool = false) {
        switch method {
        case "session/update":
            guard let value = params["update"], let update = try? SessionUpdate(raw: value) else { return }
            if replay { history.append(update) }
            if update.kind == "config_option_update", let value = update.raw["configOptions"],
                let options = try? value.decode([ConfigOption].self)
            {
                configOptions = options; events.emit(.configOptions(options))
            }
            if update.kind == "current_mode_update", let mode = update.raw["currentModeId"]?.string {
                if var state = modes?.object { state["currentModeId"] = .string(mode); modes = .object(state) };
                events.emit(.mode(mode))
            }
            turn?.push(.update(update)); events.emit(.update(update))
        case "agneta/queued":
            if let position = params["position"]?.integer.flatMap(Int.init(exactly:)) {
                let wait = params["waitingFor"]?.string
                turn?.push(.queued(position: position, waitingFor: wait));
                events.emit(.queued(position: position, waitingFor: wait))
            }
        case "agneta/rateLimited": turn?.push(.rateLimited(params)); events.emit(.rateLimited(params))
        case "agneta/sessionStopped":
            let by = params["stoppedBy"]?.string ?? "engine", detail = params["reason"]?.string
            turn?.push(.stopped(by: by, detail: detail)); end(.stopped(by: by, detail: detail))
        case "agneta/trace":
            if let records = params["records"], let decoded = try? records.decode([TraceRecord].self), !decoded.isEmpty
            {
                events.emit(.trace(decoded))
            }
            if let after = params["overflow"]?["after"]?.integer { events.emit(.traceOverflow(after: after)) }
        default: break
        }
    }
}

public struct TraceRecords: AsyncSequence, Sendable {
    public typealias Element = TraceRecord
    let client: AgnetaClient
    let id: String
    let after: Int64
    let types: [String]?
    let limit: Int
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(client: client, id: id, after: after, types: types, limit: limit)
    }
    public struct AsyncIterator: AsyncIteratorProtocol {
        let client: AgnetaClient
        let id: String
        var after: Int64
        let types: [String]?
        let limit: Int
        var buffer: [TraceRecord] = []
        var index = 0
        var complete = false
        public mutating func next() async throws -> TraceRecord? {
            try Task.checkCancellation()
            while index >= buffer.count {
                guard !complete else { return nil }
                let page = try await client.readTrace(id, after: after, types: types, limit: limit)
                complete = page.complete
                buffer = page.records; index = 0
                if !page.complete {
                    guard let next = page.next ?? page.records.last?.seq, next > after else {
                        throw AgnetaError(.protocolViolation, "Trace pagination did not advance.")
                    }
                    after = next
                }
                // An empty filtered page can still advance; loop without growing an async recursion stack.
                try Task.checkCancellation()
            }
            defer { index += 1 }; return buffer[index]
        }
    }
}
