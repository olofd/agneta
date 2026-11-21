// One side of a JSON-RPC connection: sends requests and awaits responses,
// and hands incoming requests and notifications to handlers. Transport
// agnostic, so the same peer drives engines over stdio and apps over WebSocket.
import Foundation

public actor RPCPeer {
    public typealias Send = @Sendable (Data) async throws -> Void
    public typealias RequestHandler =
        @Sendable (_ method: String, _ params: JSONValue?) async -> Result<JSONValue, RPCError>
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: JSONValue?) async -> Void

    public enum PeerError: Error, Equatable {
        case closed(String)
    }

    private let send: Send
    private var nextID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var closedReason: String?
    private var onRequest: RequestHandler = { method, _ in
        .failure(RPCError(code: RPCError.methodNotFound, message: "Method not found: \(method)"))
    }
    private var onNotification: NotificationHandler = { _, _ in }
    private var onClose: (@Sendable (String) -> Void)?
    private var tap: Tap?
    /// The last message queued to send: each waits for the one before, so messages leave in the order they were
    /// sent (a cancel right after a prompt never reaches the engine first).
    private var lastSend: Task<Void, Error>?

    public enum FrameDirection: Sendable { case received, sent }
    /// Sees every frame exactly as received or sent (task traces).
    public typealias Tap = @Sendable (FrameDirection, Data) -> Void

    /// Notifications and responses are handled one at a time, in arrival order (one Task each could
    /// reorder streamed chunks, and a turn's result could overtake its last updates). Requests start in order
    /// and run concurrently, since a handler may wait on another peer.
    private let inbox: AsyncStream<@Sendable () async -> Void>.Continuation

    public init(send: @escaping Send) {
        self.send = send
        let (jobs, inbox) = AsyncStream<@Sendable () async -> Void>.makeStream()
        self.inbox = inbox
        Task { for await job in jobs { await job() } }
    }

    public func handle(requests: @escaping RequestHandler) { onRequest = requests }
    public func handle(notifications: @escaping NotificationHandler) { onNotification = notifications }
    public func handle(close: @escaping @Sendable (String) -> Void) { onClose = close }
    public func handle(tap: @escaping Tap) { self.tap = tap }

    private var routed = false
    /// Installs a tap and handlers for requests and notifications, once: later calls do nothing. A connection
    /// shared by several sessions is wired by whichever arrives first, completely, before any other sees it.
    public func route(
        tap: Tap?, requests: @escaping RequestHandler, notifications: @escaping NotificationHandler,
        closed: (@Sendable (String) -> Void)? = nil
    ) {
        guard !routed else { return }
        routed = true
        self.tap = tap
        onRequest = requests
        onNotification = notifications
        if let closed {
            // Already closed (the engine died while starting): say so at once.
            if let closedReason { closed(closedReason) } else { onClose = closed }
        }
    }

    private func transmit(_ data: Data) async throws {
        try await enqueue(data).value
    }

    /// Queues `data` behind what's already queued, at once (synchronously, in the actor): the order of calls is the
    /// order on the wire, whatever the tasks awaiting them do.
    private func enqueue(_ data: Data) -> Task<Void, Error> {
        let previous = lastSend, send = send, tap = tap
        let task = Task {
            _ = await previous?.result
            tap?(.sent, data)
            try await send(data)
        }
        lastSend = task
        return task
    }

    /// Consumes incoming lines until the stream ends, then fails pending requests.
    public func run(_ lines: AsyncThrowingStream<Data, Error>) async {
        do {
            for try await line in lines { receive(line) }
            close("connection ended")
        } catch {
            close("connection failed: \(error)")
        }
    }

    public func request(_ method: String, _ params: JSONValue? = nil) async throws -> JSONValue {
        if let closedReason { throw PeerError.closed(closedReason) }
        let id = nextID
        nextID += 1
        let data = try RPCMessage.request(id: .int(id), method: method, params: params).encoded()
        // Cancelling the calling task abandons the request: it throws CancellationError and a late answer is dropped.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                pending[id] = continuation
                let sending = enqueue(data)
                Task { await self.wrote(sending, failing: id) }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    private func abandon(_ id: Int64) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    public func notify(_ method: String, _ params: JSONValue? = nil) async throws {
        if let closedReason { throw PeerError.closed(closedReason) }
        try await transmit(try RPCMessage.notification(method: method, params: params).encoded())
    }

    public func close(_ reason: String) {
        guard closedReason == nil else { return }
        closedReason = reason
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: PeerError.closed(reason)) }
        onClose?(reason)
        inbox.finish() // what's queued is still handled, then the delivery task ends
    }

    public var isClosed: Bool { closedReason != nil }

    private func wrote(_ sending: Task<Void, Error>, failing id: Int64) async {
        do { try await sending.value } catch {
            pending.removeValue(forKey: id)?.resume(throwing: error)
        }
    }

    private func receive(_ line: Data) {
        // A closed peer takes nothing more: no request runs after access was removed or Agneta reset.
        guard closedReason == nil else { return }
        tap?(.received, line)
        let message: RPCMessage
        do { message = try RPCMessage.parse(line) } catch {
            // Nested too deep to decode: still answered, so nothing waits for ever (a request gets an error; a reply to
            // one of ours fails that request). Anything else malformed has no usable id: not ours to answer, logged by
            // whoever owns the connection.
            if JSONCoding.nesting(of: line) > JSONCoding.maxDepth, let top = JSONCoding.topLevel(of: line),
                let raw = top.id, let id = RPCID(raw)
            {
                let error = RPCError(
                    code: RPCError.invalidRequest,
                    message: "The message is nested more than \(JSONCoding.maxDepth) levels deep")
                if top.method != nil {
                    if let data = try? RPCMessage.response(id: id, result: .failure(error)).encoded() {
                        Task { try? await self.transmit(data) }
                    }
                } else if case .int(let number) = id, let continuation = pending.removeValue(forKey: number) {
                    inbox.yield { continuation.resume(throwing: error) }
                }
            }
            return
        }
        switch message {
        case .response(.int(let id), let result):
            guard let continuation = pending.removeValue(forKey: id) else { return }
            inbox.yield {
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        case .response:
            return
        case .notification(let method, let params):
            let handler = onNotification
            inbox.yield { await handler(method, params) }
        case .request(let id, let method, let params):
            let handler = onRequest
            Task {
                let result = await handler(method, params)
                if let data = try? RPCMessage.response(id: id, result: result).encoded() {
                    try? await self.transmit(data)
                }
            }
        }
    }
}

extension RPCPeer {
    /// A peer over a child process's stdio, one JSON message per line.
    public static func stdio(_ process: ChildProcess) -> (RPCPeer, AsyncThrowingStream<Data, Error>) {
        let writer = LineWriter(process.stdin)
        let peer = RPCPeer { data in try await writer.write(data) }
        return (peer, LineStream.lines(from: process.stdout))
    }
}

/// Serializes writes so concurrent messages never interleave within a line. The blocking write runs on the
/// writer's own queue, never on Swift's shared pool: a write to an engine that stops reading its stdin blocks, and
/// on the pool each would hold a thread (measured: twenty such engines froze every task in Agneta).
public final class LineWriter: Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "agneta.line-writer")
    public init(_ handle: FileHandle) { self.handle = handle }
    public func write(_ data: Data) async throws {
        var line = data
        line.append(0x0A)
        let handle = self.handle, frame = line
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { continuation.resume(with: Result { try handle.write(contentsOf: frame) }) }
        }
    }
}
