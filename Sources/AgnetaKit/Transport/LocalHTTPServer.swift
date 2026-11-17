// A minimal HTTP/1.1 server on loopback for the diagnostics MCP server
// (Streamable HTTP, JSON responses). One request per connection, bodies capped,
// browser requests (with an Origin) refused.
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
        public init(status: Int, headers: [String: String] = ["Content-Type": "application/json"], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    public typealias Handler = @Sendable (Request) async -> Response
    static let maxBody = 1 << 20

    private let listener: NWListener
    private let handler: Handler
    public let port: UInt16

    public init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.handler = handler
        self.port = port
    }

    public func start() async throws {
        let started = OnceFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if started.take() { continuation.resume() }
                case .failed(let error): if started.take() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: DispatchQueue(label: "agneta.http"))
        }
    }

    public func stop() { listener.cancel() }

    static let maxConnections = 16
    private let lock = NSLock()
    private var open = 0
    /// Connections being served now.
    var openConnections: Int { lock.withLock { open } }

    /// At most 16 connections, each closed after 10 s whatever it's doing (no slow-request pile-up). Each is
    /// counted out once: a connection that fails is cancelled, and then reports `.cancelled` as well.
    private func serve(_ connection: NWConnection) {
        guard lock.withLock({ () -> Bool in guard open < Self.maxConnections else { return false }; open += 1; return true }) else {
            connection.cancel()
            return
        }
        let ended = OnceFlag()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                connection?.cancel() // a failed connection keeps its resources until it's cancelled
                if ended.take() { self?.lock.withLock { self?.open -= 1 } }
            default: break
            }
        }
        let queue = DispatchQueue(label: "agneta.http.connection")
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || buffer.count > Self.maxBody + (16 << 10) { connection.cancel(); return }
            if let request = Self.parse(buffer) {
                let handler = self.handler
                Task {
                    let response: Response
                    if request.method == "INVALID" {
                        response = Response(status: 400, body: Data(#"{"error":"bad request"}"#.utf8))
                    } else if request.headers["origin"] != nil {
                        response = Response(status: 403, body: Data(#"{"error":"browsers can't use Agneta's diagnostics"}"#.utf8))
                    } else {
                        response = await handler(request)
                    }
                    connection.send(content: Self.encode(response), completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if complete {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
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
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // A missing length is 0; anything else must be a whole number within the cap (-1 trapped).
        guard let length = Int(headers["content-length"] ?? "0"), (0...maxBody).contains(length) else {
            return Request(method: "INVALID", path: "", headers: [:], body: Data())
        }
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body.prefix(length)))
    }

    static func encode(_ response: Response) -> Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][response.status] ?? "Status"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + response.body
    }
}
