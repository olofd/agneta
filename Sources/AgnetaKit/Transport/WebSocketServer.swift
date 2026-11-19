// The local WebSocket apps connect to: ws://127.0.0.1:<port>/acp. One text
// frame carries one JSON-RPC message. Loopback only, bounded frames and a
// bounded outbound queue, so a stalled app can't grow Agneta's memory.
// Upgrades carrying a browser Origin are refused; app authentication happens
// in the first ACP message (Router), so any WebSocket client can use it.
import Foundation
import Network

public final class WebSocketServer: @unchecked Sendable {
    /// One accepted app connection.
    public final class Connection: @unchecked Sendable {
        public let id = UUID()
        /// The peer's local TCP port, used to identify the connecting process.
        public let remotePort: Int?
        /// Agneta's listening port, the other end of the client's connection.
        public var localPort: Int? = nil
        public let messages: AsyncThrowingStream<Data, Error>
        private let connection: NWConnection
        private let input: AsyncThrowingStream<Data, Error>.Continuation
        private let lock = NSLock()
        private var queued = 0
        private var queuedBytes = 0
        /// Closed (by either side, or for falling behind): nothing more is sent.
        private var closed = false
        /// What may wait for an app to read before it's taken to have stopped (see `WebSocketServer.init`).
        private let maxQueued: Int
        private let maxQueuedBytes: Int

        init(_ connection: NWConnection, maxQueued: Int, maxQueuedBytes: Int) {
            self.connection = connection
            self.maxQueued = maxQueued
            self.maxQueuedBytes = maxQueuedBytes
            if case .hostPort(_, let port) = connection.endpoint {
                remotePort = Int(port.rawValue)
            } else {
                remotePort = nil
            }
            (messages, input) = AsyncThrowingStream<Data, Error>.makeStream()
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let error):
                    // A failed connection keeps its resources until it's cancelled (an app killed mid-connection).
                    self?.lock.withLock { self?.closed = true }
                    self?.input.finish(throwing: error)
                    self?.connection.cancel()
                case .cancelled:
                    self?.lock.withLock { self?.closed = true }
                    self?.input.finish()
                default: break
                }
            }
            receive()
        }

        private func receive() {
            connection.receiveMessage { [weak self] content, context, _, error in
                guard let self else { return }
                if let error { self.input.finish(throwing: error); self.connection.cancel(); return }
                let metadata =
                    context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                switch metadata?.opcode {
                case .text?, .binary?: if let content { self.input.yield(content) }
                case .close?: self.input.finish(); self.connection.cancel(); return
                case nil where content == nil: self.input.finish(); self.connection.cancel(); return
                default: break
                }
                self.receive()
            }
        }

        private func reserve(_ bytes: Int) -> Bool {
            lock.withLock {
                guard !closed, queued < maxQueued, queuedBytes + bytes <= maxQueuedBytes else { return false }
                queued += 1
                queuedBytes += bytes
                return true
            }
        }

        /// Sends one message without waiting for the app to read it. Messages go out in order; while the app reads
        /// slowly they wait here, and past the bound the app has stopped reading and is disconnected. Waiting for each
        /// send instead held up the sender: the engine delivering it, and with it every other session on that engine.
        public func send(_ data: Data) async throws {
            guard reserve(data.count) else {
                close()
                throw WebSocketError.backpressure
            }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "acp", metadata: [metadata])
            let bytes = data.count
            connection.send(
                content: data, contentContext: context, isComplete: true,
                completion: .contentProcessed { [weak self] _ in
                    // A send that failed means the connection did: its receive side ends it.
                    self?.lock.withLock {
                        self?.queued -= 1
                        self?.queuedBytes -= bytes
                    }
                })
        }

        public func close() {
            lock.withLock { closed = true }
            connection.cancel()
            input.finish()
        }
    }

    public enum WebSocketError: Error { case backpressure }

    public let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "agneta.websocket")
    public let connections: AsyncStream<Connection>
    private let accepted: AsyncStream<Connection>.Continuation

    /// What may wait for an app to read before it's taken to have stopped and is disconnected: generous for a burst
    /// (a long reply streams thousands of small updates), bounded so one stalled app can't grow memory without limit.
    public let maxQueued: Int
    public let maxQueuedBytes: Int

    public init(port: UInt16, maxFrame: Int = 16 << 20, maxQueued: Int = 10_000, maxQueuedBytes: Int = 64 << 20) throws
    {
        self.port = port
        self.maxQueued = maxQueued
        self.maxQueuedBytes = maxQueuedBytes
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = maxFrame
        ws.setClientRequestHandler(queue) { _, headers in
            // Web pages must not drive Agneta: anything sending an Origin header is refused.
            let browser = headers.contains { $0.name.lowercased() == "origin" }
            return .init(status: browser ? .reject : .accept, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        (connections, accepted) = AsyncStream<Connection>.makeStream()
        listener.newConnectionHandler = { [accepted, queue] raw in
            let connection = Connection(raw, maxQueued: maxQueued, maxQueuedBytes: maxQueuedBytes)
            connection.localPort = Int(port)
            raw.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.start()
                    accepted.yield(connection)
                case .failed, .cancelled:
                    raw.cancel()
                default: break
                }
            }
            raw.start(queue: queue)
        }
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { continuation.resume() }
                case .failed(let error): if once.take() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
        accepted.finish()
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
