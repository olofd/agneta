import Foundation

/// Injectable transport. Calls are serialized on the main actor; network I/O suspends without blocking it.
/// `start` and `receive` must respond to task cancellation or `close`. Send one text frame per call.
@MainActor public protocol WebSocketTransport: AnyObject, Sendable {
    func start() async throws
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

/// Foundation's WebSocket implementation. It uses an ephemeral session, no cookies, no credentials,
/// no proxy, and refuses redirects, so a local endpoint cannot redirect a pairing token elsewhere.
@MainActor final class FoundationTransport: NSObject, WebSocketTransport, URLSessionWebSocketDelegate {
    private let url: URL
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var opening: CheckedContinuation<Void, any Error>?
    private var ended = false

    init(url: URL) { self.url = url }

    func start() async throws {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        // Pairing and prompts have their own deadlines in Connection.
        configuration.timeoutIntervalForRequest = 7 * 24 * 60 * 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 16 * 1024 * 1024
        self.socket = socket
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if ended || Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                opening = continuation
                socket.resume()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.close() }
        }
    }

    func send(_ text: String) async throws {
        guard let socket, !ended else { throw AgnetaError(.connectionClosed, "The connection is closed.") }
        try await socket.send(.string(text))
    }
    func receive() async throws -> String {
        guard let socket, !ended else { throw AgnetaError(.connectionClosed, "The connection is closed.") }
        switch try await socket.receive() {
        case .string(let text): return text
        case .data: throw AgnetaError(.protocolViolation, "Agneta sent a binary frame; expected JSON text.")
        @unknown default: throw AgnetaError(.protocolViolation, "Unknown WebSocket message type.")
        }
    }
    func close() {
        guard !ended else { return }
        ended = true
        let continuation = opening; opening = nil
        continuation?.resume(throwing: CancellationError())
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        socket = nil; session = nil
    }
    nonisolated func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let continuation = opening; opening = nil
            continuation?.resume()
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let continuation = opening; opening = nil
            continuation?.resume(throwing: error ?? AgnetaError(.refused, "The WebSocket upgrade was refused."))
        }
    }
    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

func transportError(_ error: any Error) -> any Error {
    if error is CancellationError || error is AgnetaError { return error }
    let ns = error as NSError
    if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) {
        return AgnetaError(
            .networkBlocked, "This app may not connect to Agneta. Sandboxed apps need the network.client entitlement.")
    }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
        let mapped = transportError(underlying)
        if let failure = mapped as? AgnetaError, failure.kind == .networkBlocked { return failure }
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return AgnetaError(.notRunning, "Agneta is not running at this address.")
        case .timedOut: return AgnetaError(.timeout, "The connection to Agneta timed out.")
        case .badServerResponse, .unsupportedURL, .userAuthenticationRequired:
            return AgnetaError(.refused, "The endpoint refused the WebSocket connection.")
        default: break
        }
    }
    return AgnetaError(.connectionClosed, error.localizedDescription)
}
