import Foundation

public enum ClientState: Sendable { case disconnected, connecting, pairing, connected, reconnecting }
public enum ClientEvent: Sendable, Equatable {
    case state(ClientState)
    case progress(ConnectProgress)
    case pairingCode(String)
    case accessChanged(Access)
    case catalogChanged(Catalog)
    case paired(remembered: Bool, unmet: [UnmetItem])
    case accessRemoved
    case disconnected(AgnetaError)
    case reconnecting(attempt: Int, delay: TimeInterval)
    case reconnected(Access)
    case engineDownloading(DownloadProgress)
    case notification(method: String, params: JSONValue)
    case error(AgnetaError)
}

/// The app-facing client. Mutable state and callbacks live on MainActor, ready for SwiftUI or AppKit.
/// Keep the client alive while using it, and call `close()` to stop its sessions and any reconnect attempt.
@MainActor public final class AgnetaClient {
    public let options: ClientOptions
    public let url: URL
    public private(set) var state: ClientState = .disconnected
    public private(set) var connection: Connection?
    public private(set) var access: Access?
    public private(set) var initializeResult: JSONValue?
    public private(set) var remembered = false
    public private(set) var pairingCode: String?
    public var workspace: String? { access?.workspace }
    public var extensions: [String] {
        initializeResult?["_meta"]?["agneta"]?["extensions"]?.array?.compactMap(\.string) ?? []
    }
    public var sessions: [Session] { Array(registered.values) }
    private let events = EventHub<ClientEvent>()
    private var registered: [String: Session] = [:]
    private var early: [String: [(String, JSONValue)]] = [:]
    private var heldBytes = 0
    private var loading: Set<String> = []
    private var opening: (UUID, Task<Connection, any Error>)?
    private var connecting: (UUID, Task<Access, any Error>)?
    private var reconnecting: Task<Void, Never>?
    private var generation = UUID()
    private var intentionalClose = false

    public init(options: ClientOptions) throws {
        guard !options.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgnetaError(.invalidParams, "The client needs your app's name.")
        }
        let buffers = options.buffers
        guard
            [
                buffers.turnEvents, buffers.turnBytes, buffers.earlySessions, buffers.earlyEventsPerSession,
                buffers.earlyBytes
            ].allSatisfy({ $0 > 0 })
        else {
            throw AgnetaError(.invalidParams, "Buffer limits must be positive.")
        }
        let timeouts = options.timeouts
        guard
            [
                timeouts.connect, timeouts.request, timeouts.pair, timeouts.session, timeouts.prompt,
                timeouts.open, timeouts.download, timeouts.downloadPoll
            ].allSatisfy({ $0.isFinite && $0 >= 0 }),
            timeouts.downloadPoll > 0
        else {
            throw AgnetaError(.invalidParams, "Timeouts must be finite and nonnegative; downloadPoll must be positive.")
        }
        if let settings = options.reconnect {
            guard settings.delay.isFinite, settings.maxDelay.isFinite, settings.delay > 0,
                settings.maxDelay >= settings.delay
            else {
                throw AgnetaError(.invalidParams, "Reconnect delays must be positive, finite, and ordered.")
            }
        }
        if let version = options.minimumVersion {
            guard version.range(of: #"^[0-9]+(\.[0-9]+){0,2}$"#, options: .regularExpression) != nil,
                compareVersions(version, version) != nil
            else { throw AgnetaError(.invalidParams, "minimumVersion must be numeric, such as 0.7.0.") }
        }
        self.options = options; url = options.url ?? options.build.url
    }
    public convenience init(name: String, build: AgnetaBuild = .release, tokens: (any TokenStore)? = nil) throws {
        try self.init(options: ClientOptions(name: name, build: build, tokens: tokens))
    }
    deinit {
        opening?.1.cancel(); connecting?.1.cancel(); reconnecting?.cancel()
        let connection = connection
        Task { @MainActor in connection?.close() }
    }

    @discardableResult public func onEvent(_ listener: @escaping @MainActor (ClientEvent) -> Void)
        -> @MainActor () -> Void
    { events.on(listener) }
    public func session(id: String) -> Session? { registered[id] }

    public func open() async throws -> Connection {
        try Task.checkCancellation()
        if let connection, connection.isOpen { return connection }
        if let opening { return try await awaitShared(opening.1) }
        intentionalClose = false
        let id = UUID(), epoch = generation
        let task = Task { @MainActor [weak self] () throws -> Connection in
            guard let self else { throw CancellationError() }
            setState(.connecting)
            let connection = try await Connection.open(
                url: url, connectTimeout: options.timeouts.connect,
                requestTimeout: options.timeouts.request, transport: options.transport?(url))
            guard generation == epoch, !Task.isCancelled else { connection.close(); throw CancellationError() }
            // A waitForAgneta call may have opened one meanwhile.
            if let existing = self.connection, existing.isOpen { connection.close(); return existing }
            attach(connection)
            return connection
        }
        opening = (id, task)
        defer { if opening?.0 == id { opening = nil } }
        do { return try await awaitShared(task) } catch {
            if connection == nil { setState(.disconnected) }; throw error
        }
    }

    public func connect(_ connect: ConnectOptions = .init()) async throws -> Access {
        try Task.checkCancellation()
        if state == .connected, let access, connection?.isOpen == true, connect.pair != .always { return access }
        if let connecting { return try await awaitShared(connecting.1) }
        intentionalClose = false
        let previousReconnect = reconnecting
        previousReconnect?.cancel(); reconnecting = nil
        let id = UUID(), epoch = generation
        let task = Task { @MainActor [weak self] () throws -> Access in
            await previousReconnect?.value
            guard let self else { throw CancellationError() }
            try ensure(epoch)
            return try await performConnect(connect, epoch: epoch)
        }
        connecting = (id, task)
        defer { if connecting?.0 == id { connecting = nil } }
        return try await awaitShared(task)
    }
    private func performConnect(_ connect: ConnectOptions, epoch: UUID) async throws -> Access {
        let previous = connection
        let wasConnected = state == .connected
        do {
            report(.looking, "Connecting to \(options.build.name)…", connect)
            _ = try await reach(connect, epoch: epoch)
            try ensure(epoch)
            try await checkVersion(connect, epoch: epoch)
            let token =
                connect.pair == .always
                ? nil
                : try await withDeadline(0, method: "load token") { [tokens = options.tokens] in try await tokens.load()
                }
            try ensure(epoch)
            var initialized = false
            if let token {
                do {
                    _ = try await initialize(token: token)
                    remembered = true; initialized = true
                } catch let error as AgnetaError where error.kind == .needsPairing {
                    try await options.tokens.clear(); try ensure(epoch)
                    remembered = false; events.emit(.accessRemoved)
                    if connect.pair == .never { throw error }
                }
            }
            if !initialized {
                guard connect.pair != .never else { throw AgnetaError(.needsPairing, "Pair with Agneta first.") }
                if connect.setup { try await setupIfNeeded(connect, epoch: epoch) }
                _ = try await pair(scope: connect.scope ?? options.scope)
            }
            try ensure(epoch)
            guard let access else { throw AgnetaError(.protocolViolation, "Initialization returned no access report.") }
            report(.connected, "Connected to \(options.build.name)", connect)
            return access
        } catch {
            if wasConnected, let previous, connection === previous, previous.isOpen {
                setState(.connected)
            } else if generation == epoch {
                connection?.close(); setState(.disconnected)
            }
            throw error
        }
    }
    public func pair(scope: PairingScope? = nil) async throws -> PairResult {
        let connection = try await open(), epoch = generation
        setState(.pairing)
        defer { pairingCode = nil; if state == .pairing { setState(access == nil ? .connecting : .connected) } }
        var params: [String: JSONValue] = ["name": .string(options.name)]
        if let scope = scope ?? options.scope { params["scope"] = try JSONValue(encoding: scope) }
        let raw = try await connection.request(
            "agneta/pair", params: .object(params), options: .init(timeout: options.timeouts.pair))
        let result: PairResult = try decodeResult(raw, method: "agneta/pair")
        try ensure(epoch)
        guard !result.token.isEmpty else { throw AgnetaError(.protocolViolation, "Pairing returned an empty token.") }
        if result.remembered { try await options.tokens.save(result.token) } else { try await options.tokens.clear() }
        try ensure(epoch)
        remembered = result.remembered
        events.emit(.paired(remembered: result.remembered, unmet: result.unmet))
        try ensure(epoch)
        _ = try await initialize(token: result.token)
        return result
    }
    @discardableResult public func initialize(token: String) async throws -> JSONValue {
        let connection = try await open(), epoch = generation
        let result = try await connection.request(
            "initialize",
            params: [
                "protocolVersion": .integer(Int64(protocolVersion)), "clientCapabilities": [:],
                "clientInfo": ["name": .string(options.name), "version": .string(options.version)],
                "_meta": ["agneta": ["token": .string(token)]]
            ])
        try ensure(epoch)
        guard self.connection === connection, connection.isOpen,
            result["protocolVersion"]?.integer == Int64(protocolVersion),
            let report = result["_meta"]?["agneta"]?["access"]
        else {
            throw AgnetaError(.protocolViolation, "Use an Agneta build that returns its app access report.")
        }
        access = try decodeResult(report, method: "initialize")
        initializeResult = result; setState(.connected)
        return result
    }
    public func catalog() async throws -> Catalog {
        let connection = try await open()
        return try decodeResult(try await connection.request("agneta/catalog"), method: "agneta/catalog")
    }
    @discardableResult public func setup(kind: String? = nil) async throws -> Bool {
        let connection = try await open()
        var params: [String: JSONValue] = ["name": .string(options.name)]
        if let kind { params["kind"] = .string(kind) }
        return try await connection.request("agneta/setup", params: .object(params))["shown"]?.bool == true
    }
    @discardableResult public func refreshAccess() async throws -> Access {
        let connection = try requireConnection()
        let result: Access = try decodeResult(try await connection.request("agneta/access"), method: "agneta/access")
        guard self.connection === connection else {
            throw AgnetaError(.connectionClosed, "The connection was replaced.")
        }
        access = result
        return result
    }
    public func forgetToken() async throws { remembered = false; try await options.tokens.clear() }
    public func close() {
        intentionalClose = true; generation = UUID()
        opening?.1.cancel(); opening = nil
        connecting?.1.cancel(); connecting = nil
        reconnecting?.cancel(); reconnecting = nil
        connection?.close(); setState(.disconnected)
    }

    public func newSession(_ options: SessionOptions = .init()) async throws -> Session {
        try await openSession("session/new", source: nil, options: options)
    }
    public func loadSession(_ id: String, options: SessionOptions = .init()) async throws -> Session {
        try await openSession("session/load", source: id, options: options)
    }
    public func fork(_ id: String, options: SessionOptions = .init()) async throws -> Session {
        try await openSession("agneta/fork", source: id, options: options)
    }
    private func openSession(_ method: String, source: String?, options: SessionOptions) async throws -> Session {
        let connection = try requireConnection()
        guard access != nil else { throw AgnetaError(.needsPairing, "Pair with Agneta first.") }
        if options.results != nil || options.meta[resultExtension] != nil, !extensions.contains(resultExtension) {
            throw AgnetaError(.unsupportedByAgneta, "This Agneta does not offer structured results.")
        }
        let isLoad = method == "session/load"
        if isLoad, let source, loading.contains(source) {
            throw AgnetaError(.turnBusy, "This session is already being loaded.")
        }
        var params = options.params
        if let source { params["sessionId"] = .string(source) }
        if let cwd = options.cwd ?? (method == "agneta/fork" ? nil : workspace) { params["cwd"] = .string(cwd) }
        if method != "agneta/fork", params["cwd"]?.string == nil {
            throw AgnetaError(.invalidParams, "A session needs an absolute cwd.")
        }
        params["mcpServers"] = try JSONValue(encoding: options.mcpServers)
        let meta = try options.metadata()
        if !meta.isEmpty { params["_meta"] = .object(meta) }
        let stale = isLoad ? source.flatMap { registered.removeValue(forKey: $0) } : nil
        if isLoad, let source {
            loading.insert(source); heldBytes -= cost(early.removeValue(forKey: source) ?? []); early[source] = []
        }
        defer {
            if isLoad, let source { loading.remove(source); heldBytes -= cost(early.removeValue(forKey: source) ?? []) }
        }
        let start = ContinuousClock.now
        do {
            let raw: JSONValue
            while true {
                do {
                    do {
                        raw = try await connection.request(
                            method, params: .object(params),
                            options: .init(timeout: options.timeout ?? self.options.timeouts.session))
                    } catch {
                        // The host may already have created a session whose id we will never receive. Disconnecting
                        // ends its engines and all other sessions, rather than leaving invisible work behind.
                        if error is CancellationError || (error as? AgnetaError)?.kind == .timeout {
                            connection.close()
                        }
                        throw error
                    }
                    break
                } catch let error as AgnetaError where error.kind == .engineDownloading && options.waitForDownload {
                    let elapsed = start.duration(to: .now)
                    if self.options.timeouts.download > 0, elapsed >= .seconds(self.options.timeouts.download) {
                        throw error
                    }
                    if let progress = error.download {
                        options.onDownloadProgress?(progress); events.emit(.engineDownloading(progress))
                    }
                    try await Task.sleep(for: .seconds(self.options.timeouts.downloadPoll))
                }
            }
            if Task.isCancelled { connection.close(); throw CancellationError() }
            guard self.connection === connection, connection.isOpen else {
                throw AgnetaError(.connectionClosed, "Closed while the session opened.")
            }
            guard let id = isLoad ? source : raw["sessionId"]?.string, !id.isEmpty else {
                connection.close()
                throw AgnetaError(.protocolViolation, "Agneta returned no session id for \(method).")
            }
            let buffered = early.removeValue(forKey: id) ?? []
            heldBytes -= cost(buffered)
            let session: Session
            do { session = try Session(client: self, connection: connection, id: id, raw: raw, options: options) } catch
            { connection.close(); throw error }
            let previous = registered.updateValue(session, forKey: id) ?? stale
            previous?.end(.closed)
            for (method, params) in buffered {
                guard self.connection === connection, connection.isOpen else {
                    throw AgnetaError(.connectionClosed, "Closed while replaying the session.")
                }
                session.receive(method, params: params, replay: true)
            }
            guard self.connection === connection, connection.isOpen else {
                throw AgnetaError(.connectionClosed, "Closed while the session opened.")
            }
            return session
        } catch {
            if let stale, let source {
                if self.connection === connection, connection.isOpen, registered[source] == nil {
                    registered[source] = stale
                    let buffered = early.removeValue(forKey: source) ?? []
                    heldBytes -= cost(buffered)
                    for (method, params) in buffered { stale.receive(method, params: params) }
                } else if !connection.isOpen {
                    stale.end(
                        .disconnected(
                            connection.closeError ?? AgnetaError(.connectionClosed, "Closed while loading the session.")
                        ))
                }
            }
            throw error
        }
    }
    public func readTrace(_ id: String, after: Int64 = 0, types: [String]? = nil, limit: Int = 500) async throws
        -> TracePage
    {
        var params: [String: JSONValue] = [
            "sessionId": .string(id), "after": .integer(after), "limit": .integer(Int64(limit))
        ]
        if let types { params["types"] = .array(types.map(JSONValue.string)) }
        return try decodeResult(
            try await requireConnection().request("agneta/trace/read", params: .object(params)),
            method: "agneta/trace/read")
    }
    /// A lazy paged sequence. Cancelling iteration cancels only its current trace request.
    public func traceRecords(_ id: String, after: Int64 = 0, types: [String]? = nil, limit: Int = 500) -> TraceRecords {
        TraceRecords(client: self, id: id, after: after, types: types, limit: limit)
    }
    public func request(_ method: String, params: JSONValue = [:], options: RequestOptions = .init()) async throws
        -> JSONValue
    {
        try await requireConnection().request(method, params: params, options: options)
    }
    public func notify(_ method: String, params: JSONValue = [:]) async throws {
        try await requireConnection().notify(method, params: params)
    }

    func forget(_ session: Session) {
        if registered[session.id] === session { registered.removeValue(forKey: session.id) }
    }
    private func requireConnection() throws -> Connection {
        guard let connection, connection.isOpen else {
            throw AgnetaError(.connectionClosed, "Connect to Agneta first.")
        }
        return connection
    }
    private func ensure(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
    }
    private func setState(_ state: ClientState) {
        if self.state != state { self.state = state; events.emit(.state(state)) }
    }
    private func attach(_ connection: Connection) {
        self.connection = connection; access = nil; initializeResult = nil
        connection.onEvent { [weak self, weak connection] event in
            guard let self, let connection, self.connection === connection else { return }
            switch event {
            case .notification(let method, let params): notification(method, params)
            case .closed(let error): dropped(connection, error: error)
            case .message: break
            }
        }
        connection.handle("session/request_permission") { [weak self] params in
            guard let self else { return ["outcome": ["outcome": "cancelled"]] }
            let request: PermissionRequest = try decodeResult(params, method: "session/request_permission")
            let handler = registered[request.sessionId]?.permissions ?? options.permissions
            do {
                let answer = try await handler?(request) ?? .reject
                return answer.response(options: request.options)
            } catch {
                events.emit(
                    .error(error as? AgnetaError ?? AgnetaError(.internalError, "A permission handler failed.")))
                return PermissionAnswer.reject.response(options: request.options)
            }
        }
    }
    private func notification(_ method: String, _ params: JSONValue) {
        switch method {
        case "agneta/pairingCode":
            if let code = params["code"]?.string { pairingCode = code; events.emit(.pairingCode(code)) }
        case "agneta/accessChanged":
            if let value = params["access"], let report = try? value.decode(Access.self) {
                access = report; events.emit(.accessChanged(report))
            }
        case "agneta/catalogChanged":
            if let value = params["catalog"], let catalog = try? value.decode(Catalog.self) {
                events.emit(.catalogChanged(catalog))
            }
        default: break
        }
        if let id = params["sessionId"]?.string {
            if let session = registered[id] {
                session.receive(method, params: params)
            } else if ["session/update", "agneta/trace", "agneta/sessionStopped", "agneta/queued", "agneta/rateLimited"]
                .contains(method)
            {
                let bytes = method.utf8.count + params.payloadSize
                let buffers = options.buffers
                guard early[id] != nil || early.count < buffers.earlySessions,
                    (early[id]?.count ?? 0) < buffers.earlyEventsPerSession, bytes <= buffers.earlyBytes - heldBytes
                else {
                    connection?.invalidate(
                        AgnetaError(.bufferOverflow, "Session replay exceeded the opening-session buffer."))
                    return
                }
                early[id, default: []].append((method, params)); heldBytes += bytes
            }
        }
        events.emit(.notification(method: method, params: params))
    }
    private func cost(_ notifications: [(String, JSONValue)]) -> Int {
        notifications.reduce(0) { $0 + $1.0.utf8.count + $1.1.payloadSize }
    }
    private func dropped(_ connection: Connection, error: AgnetaError) {
        let retry = remembered && options.reconnect != nil && !intentionalClose
        self.connection = nil; access = nil; initializeResult = nil; pairingCode = nil
        early.removeAll(); heldBytes = 0
        let sessions = Array(registered.values); registered.removeAll()
        for session in sessions { session.end(.disconnected(error)) }
        setState(.disconnected); events.emit(.disconnected(error)); remembered = false
        if retry { scheduleReconnect() }
    }
    private func scheduleReconnect() {
        guard let settings = options.reconnect else { return }
        reconnecting?.cancel()
        reconnecting = Task { @MainActor [weak self] in
            var attempt = 1, delay = settings.delay
            while !Task.isCancelled {
                guard self?.intentionalClose == false else { return }
                self?.setState(.reconnecting); self?.events.emit(.reconnecting(attempt: attempt, delay: delay))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                do {
                    // Call the underlying connect flow, so it cannot cancel this reconnect task itself.
                    guard let self else { return }
                    let access = try await performConnect(ConnectOptions(pair: .never), epoch: generation)
                    events.emit(.reconnected(access)); return
                } catch is CancellationError { return } catch let error as AgnetaError where error.kind == .needsPairing
                { self?.setState(.disconnected); return } catch {
                    attempt += 1; delay = min(delay * 2, settings.maxDelay)
                }
            }
        }
    }

    private func report(_ step: ConnectProgress.Step, _ title: String, _ connect: ConnectOptions, code: String? = nil) {
        let progress = ConnectProgress(step: step, title: title, code: code)
        connect.onProgress?(progress); events.emit(.progress(progress))
    }
    private func ask(
        _ kind: GuideQuestion.Kind, title: String, detail: String, confirm: String, connect: ConnectOptions
    ) async throws {
        guard let guide = connect.guide else { throw AgnetaError(.declined, "No guide was supplied.") }
        let question = GuideQuestion(kind: kind, title: title, detail: detail, confirm: confirm, cancel: "Cancel")
        let yes = try await withDeadline(0, method: "guide") { await guide(question) }
        try Task.checkCancellation()
        guard yes else { throw AgnetaError(.declined, "The user declined \(title).") }
    }
    public func presence() async -> AgnetaPresence {
        if connection?.isOpen == true { return .running }
        do {
            let probe = try await Connection.open(url: url, connectTimeout: options.timeouts.connect); probe.close();
            return .running
        } catch let error as AgnetaError where error.kind == .networkBlocked { return .blocked } catch {
            return options.url == nil ? await options.environment.lookup(options.build) : .unknown
        }
    }
    @discardableResult public func openAgneta() async -> Bool { await options.environment.open(options.build) }
    @discardableResult public func openInstallPage() async -> Bool {
        await options.environment.openInstallPage(options.build)
    }
    public func waitForAgneta(timeout: TimeInterval? = nil) async throws -> Connection {
        let start = ContinuousClock.now, epoch = generation
        while true {
            try ensure(epoch)
            do { return try await open() } catch let error as AgnetaError where error.kind == .notRunning {
                let limit = timeout ?? options.timeouts.open
                if limit > 0, start.duration(to: .now) >= .seconds(limit) { throw error }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
    private func reach(_ connect: ConnectOptions, epoch: UUID) async throws -> Connection {
        do { return try await open() } catch let error as AgnetaError where error.kind == .notRunning {
            guard options.url == nil else { throw error }
            let presence = await options.environment.lookup(options.build)
            try ensure(epoch)
            switch presence {
            case .notInstalled, .onDiskImage:
                guard connect.guide != nil, connect.pair != .never else {
                    throw AgnetaError(.notInstalled, "Install \(options.build.name) to continue.")
                }
                try await ask(
                    .install, title: "Get \(options.build.name)",
                    detail: "Install Agneta in Applications. This app opens it once it is installed.",
                    confirm: "Continue", connect: connect)
                try ensure(epoch)
                if presence == .notInstalled { _ = await openInstallPage() }
                report(.installing, "Install \(options.build.name) in Applications", connect)
                while true {
                    try ensure(epoch)
                    if case .notRunning = await options.environment.lookup(options.build) {
                        try ensure(epoch)
                        if await openAgneta() { break }
                    }
                    try await Task.sleep(for: .seconds(1))
                }
            case .notRunning(let version, _):
                let outdated = compareVersions(version, options.minimumVersion) == .orderedAscending
                if outdated && (connect.guide == nil || connect.pair == .never) {
                    throw AgnetaError(.outdated, "This app needs Agneta \(options.minimumVersion ?? "") or later.")
                }
                if connect.pair == .never {
                    let kept = try await withDeadline(0, method: "load token") { [tokens = options.tokens] in
                        try await tokens.load()
                    }
                    guard kept != nil else { throw error }
                    try ensure(epoch)
                }
                guard connect.guide != nil else { throw error }
                try await ask(
                    outdated ? .update : .open, title: "Open \(options.build.name)",
                    detail: outdated
                        ? "This app needs Agneta \(options.minimumVersion ?? "") or later. Update it from its menu."
                        : "This app uses Agneta for its AI tasks. Open it now?",
                    confirm: "Open", connect: connect)
                try ensure(epoch)
                guard await openAgneta() else { throw error }
            default: throw error
            }
            try ensure(epoch)
            report(.opening, "Opening \(options.build.name)…", connect)
            return try await waitForAgneta()
        }
    }
    private func checkVersion(_ connect: ConnectOptions, epoch: UUID) async throws {
        guard let needed = options.minimumVersion else { return }
        var asked = false
        while true {
            let version: String?
            do { version = try await catalog().version } catch let error as AgnetaError
                where error.kind == .methodNotFound
            { version = "0.4.0" }
            guard compareVersions(version, needed) == .orderedAscending else { return }
            guard connect.guide != nil, connect.pair != .never else {
                throw AgnetaError(.outdated, "This app needs Agneta \(needed) or later.")
            }
            if !asked {
                report(.outdated, "Update Agneta to \(needed) or later", connect)
                try await ask(
                    .update, title: "Update Agneta",
                    detail: "Choose Check for Updates in Agneta's menu. This app continues after the update.",
                    confirm: "Continue", connect: connect)
                asked = true
            }
            let current = connection
            while current?.isOpen == true { try ensure(epoch); try await Task.sleep(for: .milliseconds(250)) }
            _ = try await waitForAgneta()
            try ensure(epoch)
        }
    }
    public func waitForProvider(kind: String? = nil, timeout: TimeInterval = 0) async throws -> Catalog {
        let epoch = generation
        return try await withDeadline(timeout, method: "waitForProvider") { [self] in
            while true {
                try ensure(epoch)
                let catalog = try await catalog()
                if let kind {
                    if catalog.providers.contains(where: { $0.kind == kind && $0.connected }) { return catalog }
                } else if catalog.connected {
                    return catalog
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }
    private func setupIfNeeded(_ connect: ConnectOptions, epoch: UUID) async throws {
        let catalog: Catalog
        do { catalog = try await self.catalog() } catch let error as AgnetaError where error.kind == .methodNotFound {
            return
        }
        let connected =
            connect.providerKind.map { kind in catalog.providers.contains { $0.kind == kind && $0.connected } }
            ?? catalog.connected
        guard !connected else { return }
        report(.needsProvider, "Connect a provider in Agneta", connect)
        if connect.guide != nil {
            try await ask(
                .setup, title: "Connect your AI in Agneta", detail: "Agneta will show its provider window.",
                confirm: "Connect", connect: connect)
        }
        _ = try await setup(kind: connect.providerKind)
        while true {
            try ensure(epoch)
            do { _ = try await waitForProvider(kind: connect.providerKind); return } catch let error as AgnetaError
                where error.kind == .connectionClosed
            { _ = try await open() }
        }
    }
}

@MainActor private func awaitShared<T: Sendable>(_ task: Task<T, any Error>) async throws -> T {
    try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}
