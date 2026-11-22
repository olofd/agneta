// A minimal HTTP/1.1 server on loopback for Agneta's own MCP servers (diagnostics, structured results; Streamable
// HTTP, JSON responses). One request per connection, bodies capped, browser requests (with an Origin) refused. Port 0
// takes a free port, which `port` reports once started.
import Foundation
import Network

public final class LocalHTTPServer: @unchecked Sendable {
    public struct Request: Sendable {
        public var method: String
        public var path: String
        /// Lowercased names.
        public var headers: [String: String]
        public var body: Data
    }

    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data
        public init(status: Int, headers: [String: String] = ["Content-Type": "application/json"], body: Data = Data())
        {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    public typealias Handler = @Sendable (Request) async -> Response
    static let maxBody = 1 << 20

    private let listener: NWListener
    private let handler: Handler
    private var bound: UInt16
    /// The port it listens on: the one asked for, or once started, the one the system gave for port 0.
    public var port: UInt16 { lock.withLock { bound } }

    public init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        // Reuse only lets a port held by closing connections be bound again: Network.framework never lets a second
        // listener share a listening port, either way round (measured, docs/PRIVACY.md). Raw BSD sockets with
        // SO_REUSEPORT would (the later bind gets the connections): keep listeners on Network.framework.
        parameters.allowLocalEndpointReuse = port != 0
        listener = try NWListener(using: parameters)
        self.handler = handler
        bound = port
    }

    public func start() async throws {
        let started = OnceFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let self {
                        self.lock.withLock {
                            if let given = self.listener.port?.rawValue { self.bound = given }
                            self.listening = true
                        }
                    }
                    if started.take() { continuation.resume() }
                case .failed(let error):
                    self?.lock.withLock { self?.listening = false }
                    self?.listener.cancel()
                    if started.take() { continuation.resume(throwing: error) }
                case .waiting(let error):
                    // Can't listen now (the port is taken, say): a failure, not a wait that never ends.
                    self?.listener.cancel()
                    if started.take() { continuation.resume(throwing: error) }
                case .cancelled:
                    self?.lock.withLock { self?.listening = false }
                    if started.take() { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: DispatchQueue(label: "agneta.http"))
        }
    }

    /// Stops listening and closes every connection, requests being answered included.
    public func stop() {
        listener.cancel()
        for connection in lock.withLock({ () -> [NWConnection] in
            defer { connections = [:] }
            return Array(connections.values)
        }) {
            connection.cancel()
        }
    }

    /// Whether it's listening: false before it starts, and after it stops or its listener fails.
    public var isListening: Bool { lock.withLock { listening } }

    /// Connections at most: reading a request, or being answered.
    static let maxConnections = 64
    /// How long a connection may take to send its whole request. Idle or trickling connections are closed then, so
    /// they can't hold the slots that real requests need.
    static let readDeadline: DispatchTimeInterval = .seconds(2)
    /// How long answering may take, from the request's arrival, before the connection is closed anyway (the handler's
    /// own work is bounded by its caller; this is the backstop).
    static let answerDeadline: DispatchTimeInterval = .seconds(60)
    private let lock = NSLock()
    private var open = 0
    private var listening = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Connections being served now.
    var openConnections: Int { lock.withLock { open } }

    /// At most `maxConnections`, each given `readDeadline` to send its request and then held until its answer is sent,
    /// so a slot is free only when its work is done. Each is counted out once: a connection that fails is cancelled,
    /// and then reports `.cancelled` as well.
    private func serve(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard
            lock.withLock({ () -> Bool in
                guard open < Self.maxConnections, listening else { return false }
                open += 1
                connections[id] = connection
                return true
            })
        else {
            connection.cancel()
            return
        }
        let ended = OnceFlag()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                connection?.cancel() // a failed connection keeps its resources until it's cancelled
                if ended.take() {
                    self?.lock.withLock {
                        self?.open -= 1
                        self?.connections[id] = nil
                    }
                }
            default: break
            }
        }
        let queue = DispatchQueue(label: "agneta.http.connection")
        connection.start(queue: queue)
        let arrived = OnceFlag()
        // Timers hold the connection weakly: once it's answered and gone, they keep nothing alive.
        queue.asyncAfter(deadline: .now() + Self.readDeadline) { [weak connection] in
            if arrived.take() { connection?.cancel() } // the request didn't arrive in time
        }
        read(connection, buffer: Data(), arrived: arrived, queue: queue)
    }

    private func read(_ connection: NWConnection, buffer: Data, arrived: OnceFlag, queue: DispatchQueue) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) {
            [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil { connection.cancel(); return }
            if buffer.count > Self.maxBody + (16 << 10) {
                // Too large to read: said so (413), not dropped without a word, so the caller (an engine's MCP client)
                // has an answer to give its model.
                guard arrived.take() else { return }
                connection.send(
                    content: Self.encode(Self.tooLarge),
                    completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if let request = Self.parse(buffer) {
                // In time: the read deadline no longer applies; the answer's does.
                guard arrived.take() else { return }
                queue.asyncAfter(deadline: .now() + Self.answerDeadline) { [weak connection] in connection?.cancel() }
                let handler = self.handler
                Task {
                    let response: Response
                    if request.method == "INVALID" {
                        response = Response(status: 400, body: Data(#"{"error":"bad request"}"#.utf8))
                    } else if request.method == "TOO_LARGE" {
                        response = Self.tooLarge
                    } else if request.headers["origin"] != nil {
                        response = Response(
                            status: 403, body: Data(#"{"error":"browsers can't use Agneta's local servers"}"#.utf8))
                    } else {
                        response = await handler(request)
                    }
                    connection.send(
                        content: Self.encode(response), completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if complete {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer, arrived: arrived, queue: queue)
            }
        }
    }

    /// A complete request, or nil while more bytes are needed.
    static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = head.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon]
            // Whitespace in a header name is malformed (RFC 9112): refused, so `Origin :` can't pass for no Origin.
            guard !name.isEmpty, !name.contains(where: \.isWhitespace) else {
                return Request(method: "INVALID", path: "", headers: [:], body: Data())
            }
            headers[name.lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // A missing length is 0; anything else must be a whole number (-1 trapped), and within the cap.
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
            return Request(method: "INVALID", path: "", headers: [:], body: Data())
        }
        guard length <= maxBody else { return Request(method: "TOO_LARGE", path: "", headers: [:], body: Data()) }
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(
            method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body.prefix(length)))
    }

    /// The answer to a request over the 1 MB cap, declared or sent: a JSON-RPC error an MCP client can show its model.
    static let tooLarge = Response(
        status: 413,
        body: Data(
            (#"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"# + #""message":"The request is larger than 1 MB"}}"#)
                .utf8))

    static func encode(_ response: Response) -> Data {
        let reason =
            [
                200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                405: "Method Not Allowed", 413: "Content Too Large"
            ][response.status] ?? "Status"
        var head =
            "HTTP/1.1 \(response.status) \(reason)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + response.body
    }
}
