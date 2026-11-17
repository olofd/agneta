// Starts, shares and stops engine processes. Sessions with only the app's
// tools share one engine per account; a session with built-in file or shell
// tools gets its own engine, because the engine's sandbox profile is per
// process. Every engine runs under the engine profile, and its
// shell commands go through the tool broker with that session's strict profile.
import Foundation

/// An initialized engine a session can use.
public struct EngineLease: Sendable {
    public let key: String
    public let peer: RPCPeer
    public let pid: pid_t
    public let dedicated: Bool
    /// The engine behind this lease: what it can do beyond plain ACP, and how.
    public var engine: any EngineAdapter
    /// The engine's state folder: its sessions and per-call usage live under it.
    public var stateRoot: URL? = nil
    /// Milliseconds from spawn to a successful `initialize`; nil when an engine was reused.
    public var startMs: Double? = nil
    /// The engine's `agentInfo` from `initialize` (name, version).
    public var engineInfo: JSONValue? = nil
}

public protocol EngineSource: Sendable {
    /// - Parameters:
    ///   - key: an earlier lease's key, to resume in the same engine home (its sessions live there).
    ///   - session: the session, for engines configured per process.
    func open(account: String, policy: SessionPolicy, mcpPorts: [Int], key: String?, session: EngineSessionSpec?) async throws -> EngineLease
    /// Called when a session ends; a dedicated engine stops, a shared one stays.
    func release(_ lease: EngineLease) async
}

extension EngineSource {
    public func open(account: String, policy: SessionPolicy, mcpPorts: [Int], key: String? = nil) async throws -> EngineLease {
        try await open(account: account, policy: policy, mcpPorts: mcpPorts, key: key, session: nil)
    }
}

public actor EngineSupervisor: EngineSource {
    public struct Configuration: Sendable {
        /// The engines Agneta can run, by id ("goose", "opencode").
        public var engines: [String: any EngineAdapter]
        public var shellTool: URL
        /// Agneta's data root: account homes and per-session scratch live under it.
        public var root: URL
        /// Loopback ports the engine itself may reach in addition to the app's MCP ports, e.g. a local model.
        public var engineLoopbackPorts: [Int]
        public var confine: Bool
        /// Records every engine started and stopped, so a crash can't orphan one.
        public var ledger: (any EngineLedger)?
        /// Task traces: shell commands, engine stderr and exits are reported here.
        public var traces: Traces?

        public init(engines: [any EngineAdapter], shellTool: URL, root: URL, engineLoopbackPorts: [Int] = [], confine: Bool = true,
                    ledger: (any EngineLedger)? = nil, traces: Traces? = nil) {
            self.engines = Dictionary(engines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.shellTool = shellTool
            self.root = root
            self.engineLoopbackPorts = engineLoopbackPorts
            self.confine = confine
            self.ledger = ledger
            self.traces = traces
        }
    }

    struct Running {
        var process: ChildProcess
        var peer: RPCPeer
        var token: String
        var grant: ToolBroker.Grant?
        var workspace: URL?
        var stateRoot: URL
        var engineInfo: JSONValue?
        var engine: any EngineAdapter
    }

    private let configuration: Configuration
    private var engines: [String: any EngineAdapter]
    private var accounts: [String: AccountSetup] = [:]
    private var running: [String: Running] = [:]
    private var starting: [String: Task<EngineLease, Error>] = [:]
    private var holders: [String: Int] = [:]
    private var broker: ToolBroker?
    private let grants = GrantTable()

    public init(_ configuration: Configuration, accounts: [String: AccountSetup] = [:]) {
        self.configuration = configuration
        self.engines = configuration.engines
        self.accounts = accounts
    }

    /// Adds or replaces an engine while running (e.g. Claude Code once its adapter is installed).
    public func register(_ engine: any EngineAdapter) { engines[engine.id] = engine }

    /// Serves `account` with this engine and provider. Engines already running keep their setup.
    public func add(account: String, setup: AccountSetup) {
        accounts[account] = setup
    }

    /// The engine an account uses, for what its sessions can do.
    public func engine(for account: String) -> (any EngineAdapter)? {
        accounts[account].flatMap { engines[$0.engine] }
    }

    /// Stops every engine serving `account` and forgets it.
    public func remove(account: String) async {
        accounts.removeValue(forKey: account)
        for (key, engine) in running where key.hasPrefix(account + "/") {
            running.removeValue(forKey: key)
            grants.remove(token: engine.token)
            await engine.peer.close("account removed")
            await stop(engine.process)
        }
    }

    /// One socket per supervisor: two in one process (tests, a restart after Reset) must not take
    /// over each other's broker. sockaddr_un paths are limited to 104 bytes, hence the short temp path.
    public nonisolated let socketPath = FileManager.default.temporaryDirectory
        .appending(path: "agneta-\(getpid())-\(UUID().uuidString.prefix(8).lowercased()).sock").path(percentEncoded: false)

    private func startBroker() throws -> ToolBroker {
        if let broker { return broker }
        let grants = self.grants
        let traces = configuration.traces
        let service = ToolBroker(socketPath: socketPath, resolve: { token, cwd in grants.grant(token: token, cwd: cwd) },
                                 report: { token, fields in
                                     if let traces, let lease = grants.lease(token: token) { traces.shell(lease: lease, fields) }
                                 })
        try service.start()
        broker = service
        return service
    }

    public func open(account: String, policy: SessionPolicy, mcpPorts: [Int], key resume: String?, session: EngineSessionSpec?) async throws -> EngineLease {
        guard let setup = accounts[account] else { throw RPCError(code: RPCError.invalidParams, message: "Unknown account \(account)") }
        guard let adapter = engines[setup.engine] else {
            throw RPCError(code: RPCError.internalError, message: "This Agneta doesn't include the \(setup.engine) engine")
        }
        // A session gets its own engine when the engine is configured per process, when it may use built-in
        // tools (the sandbox profile is per process), and on the Claude Code route (it reads its working folder).
        // A resumed session returns to its earlier engine home, where the engine keeps its sessions.
        let resumable = resume.flatMap { $0.hasPrefix(account + "/") && !$0.contains("..") ? $0 : nil }
        let dedicated = resumable.map { !$0.hasSuffix("/shared") }
            ?? (adapter.capabilities.processPerSession || policy.tools != .appOnly || setup.provider.kind == .claudeCode)
        let key = resumable ?? (dedicated ? "\(account)/\(UUID().uuidString.lowercased())" : "\(account)/shared")
        if dedicated, resumable != nil {
            // A task's own engine is never shared. A load (or a fork copying a closed task) waits until no other process
            // is on that engine home, whether still stopping or held by another lease (a fork's helper), so one home
            // never has two processes and no session runs in an engine started with another's sandbox and setup.
            let deadline = ContinuousClock.now + .seconds(20)
            while stopping.contains(key) || starting[key] != nil || running[key].map({ !$0.process.hasExited }) == true {
                guard ContinuousClock.now < deadline else {
                    throw RPCError(code: RPCError.internalError, message: "This task's engine is still busy; try again shortly")
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        if let existing = running[key], !existing.process.hasExited {
            holders[key, default: 0] += 1
            return EngineLease(key: key, peer: existing.peer, pid: existing.process.pid, dedicated: dedicated, engine: existing.engine,
                               stateRoot: existing.stateRoot, engineInfo: existing.engineInfo)
        }
        // One start per key: a second session asking while the engine starts waits for it, so two sessions at
        // once never start two shared engines on one account's state.
        if let pending = starting[key] {
            let lease = try await pending.value
            holders[key, default: 0] += 1
            return lease
        }
        let start = Task { try await self.spawn(key: key, account: account, adapter: adapter, setup: setup, dedicated: dedicated,
                                                policy: policy, mcpPorts: mcpPorts, session: session) }
        starting[key] = start
        defer { starting[key] = nil }
        let lease = try await start.value
        holders[key, default: 0] += 1
        return lease
    }

    private func spawn(key: String, account: String, adapter: any EngineAdapter, setup: AccountSetup, dedicated: Bool,
                       policy: SessionPolicy, mcpPorts: [Int], session: EngineSessionSpec?) async throws -> EngineLease {
        let accountHome = configuration.root.appending(path: "Accounts/\(account)", directoryHint: .isDirectory)
        // Each engine process gets its own state so concurrent processes don't share a session database.
        let engineHome = dedicated ? EngineHomes.home(root: configuration.root, key: key) : accountHome
        let scratch = engineHome.appending(path: "scratch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let token = Self.newToken()
        var grant: ToolBroker.Grant?
        var brokerEnvironment: [String: String] = [:]
        if dedicated {
            let broker = try startBroker()
            let toolProfile = policy.toolProfile(scratch: scratch).render()
            grant = ToolBroker.Grant(profile: toolProfile, environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": scratch.path(percentEncoded: false),
                "TMPDIR": scratch.path(percentEncoded: false), "LANG": "en_US.UTF-8",
            ])
            grants.set(token: token, grant: grant!, workspace: policy.workspace, lease: key)
            brokerEnvironment = ["AGNETA_BROKER_SOCKET": broker.socketPath, "AGNETA_BROKER_TOKEN": token]
        }

        let ports = configuration.engineLoopbackPorts + mcpPorts
        var launch = try adapter.launch(EngineLaunchContext(home: engineHome, provider: setup.provider, shell: dedicated ? configuration.shellTool : nil,
                                                            session: session, loopbackPorts: ports))
        launch.environment.merge(brokerEnvironment) { _, broker in broker }
        var wrapper: [String] = []
        if configuration.confine {
            var profile = SandboxProfile(kind: .engine,
                                         writable: [engineHome] + launch.writable
                                            + (dedicated && policy.tools == .workspace ? [policy.workspace] + policy.writable : []),
                                         denied: (dedicated ? policy.denied : []) + launch.denied,
                                         readable: (dedicated ? [policy.workspace] + policy.readable + policy.readOnly : [])
                                            + [configuration.shellTool.deletingLastPathComponent()] + launch.readable,
                                         loopbackPorts: ports, remotePorts: [443])
            profile.readOnly = policy.readOnly
            profile.ownLoopbackServer = launch.ownLoopbackServer
            profile.exceptions = launch.exceptions
            if dedicated, let broker { profile.unixSockets = [URL(filePath: broker.socketPath)] }
            if !dedicated { profile.loopbackPorts = [] ; profile.allLoopback = true }
            let file = engineHome.appending(path: "engine.sb")
            try profile.render().write(to: file, atomically: true, encoding: .utf8)
            wrapper = ["/usr/bin/sandbox-exec", "-f", file.path(percentEncoded: false)]
        }
        let spawned = ContinuousClock.now
        let process = try ChildProcess(executable: launch.executable.path(percentEncoded: false), arguments: launch.arguments,
                                       environment: launch.environment, directory: (dedicated ? policy.workspace : engineHome).path(percentEncoded: false),
                                       wrapper: wrapper)
        configuration.ledger?.engineStarted(pid: process.pid, account: account)
        let traces = configuration.traces
        Self.drain(process.stderr, into: engineHome.appending(path: "engine.log")) { line in traces?.stderr(lease: key, line: line) }
        Task {
            let status = await process.waitForExit()
            traces?.engineExited(lease: key, status: status)
            await self.exited(key: key, pid: process.pid)
        }
        let (peer, lines) = RPCPeer.stdio(process)
        Task { await peer.run(lines) }
        let initialized: JSONValue
        do {
            initialized = try await peer.request("initialize", ["protocolVersion": 1, "clientCapabilities": [:], "clientInfo": ["name": "agneta", "version": "0"]])
        } catch {
            await stop(process)
            throw RPCError(code: RPCError.internalError, message: "The engine didn't start: \(error)")
        }
        running[key] = Running(process: process, peer: peer, token: token, grant: grant, workspace: dedicated ? policy.workspace : nil,
                               stateRoot: launch.stateRoot, engineInfo: initialized["agentInfo"], engine: adapter)
        let elapsed = ContinuousClock.now - spawned
        return EngineLease(key: key, peer: peer, pid: process.pid, dedicated: dedicated, engine: adapter, stateRoot: launch.stateRoot,
                           startMs: Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15,
                           engineInfo: initialized["agentInfo"])
    }

    /// An engine process exited by itself: it's retired at once (connection closed, broker grant revoked, recorded as
    /// stopped), so the next session on its key starts a fresh one instead of finding a dead entry.
    private func exited(key: String, pid: pid_t) async {
        guard let engine = running[key], engine.process.pid == pid else { return }
        running.removeValue(forKey: key)
        grants.remove(token: engine.token)
        await engine.peer.close("the engine exited")
        await stop(engine.process)
    }

    /// A dedicated engine stops when its last holder releases it (a fork's brief hold on a task's engine
    /// mustn't stop it under a resumed session); a shared one stays.
    /// Dedicated engines whose process is being stopped, by key: nothing new starts on their home until it's gone.
    private var stopping: Set<String> = []

    public func release(_ lease: EngineLease) async {
        holders[lease.key, default: 1] -= 1
        guard holders[lease.key, default: 0] <= 0 else { return }
        holders[lease.key] = nil
        guard lease.dedicated, let engine = running.removeValue(forKey: lease.key) else { return }
        grants.remove(token: engine.token)
        stopping.insert(lease.key)
        defer { stopping.remove(lease.key) }
        await engine.peer.close("session ended")
        await stop(engine.process)
    }

    private func stop(_ process: ChildProcess) async {
        await process.stop()
        configuration.ledger?.engineStopped(pid: process.pid)
    }

    public func stopAll() async {
        for (_, engine) in running {
            await engine.peer.close("Agneta is stopping")
            await stop(engine.process)
        }
        running.removeAll()
        broker?.stop()
    }

    public var processCount: Int { running.count }
    /// Lease keys of the engines running now.
    public var runningKeys: Set<String> { Set(running.keys) }

    /// Engine stderr must be read, or a full pipe blocks the engine. It goes to an owner-only log in
    /// the engine's home, kept under 1 MB (the older half is dropped).
    static func drain(_ handle: FileHandle, into file: URL, lines: (@Sendable (String) -> Void)? = nil) {
        FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600])
        Thread {
            guard let log = try? FileHandle(forWritingTo: file) else { return }
            _ = try? log.seekToEnd()
            var splitter = LineSplitter(limit: 1 << 16)
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                try? log.write(contentsOf: data)
                if let lines {
                    // An overlong line is dropped and the splitter starts afresh, rather than failing every later
                    // push (progress output without newlines wedged it).
                    if let complete = try? splitter.push(data) {
                        for line in complete { lines(String(decoding: line, as: UTF8.self)) }
                    } else {
                        splitter = LineSplitter(limit: 1 << 16)
                    }
                }
                if let size = try? log.offset(), size > 1 << 20 {
                    let kept = (try? Data(contentsOf: file))?.suffix(1 << 19) ?? Data()
                    try? log.truncate(atOffset: 0)
                    try? log.write(contentsOf: kept)
                }
            }
            try? log.close()
        }.start()
    }

    static func newToken() -> String { UUID().uuidString + UUID().uuidString }
}

/// Token → grant for the broker, readable from its threads.
final class GrantTable: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (grant: ToolBroker.Grant, workspace: URL, lease: String)] = [:]

    func set(token: String, grant: ToolBroker.Grant, workspace: URL, lease: String) { lock.withLock { entries[token] = (grant, workspace, lease) } }
    func lease(token: String) -> String? { lock.withLock { entries[token]?.lease } }
    func remove(token: String) { lock.withLock { _ = entries.removeValue(forKey: token) } }

    /// The grant when the token is known and the command runs inside that session's workspace.
    func grant(token: String, cwd: URL) -> ToolBroker.Grant? {
        lock.withLock {
            guard let entry = entries[token], cwd.isInside(entry.workspace.realFileURL) else { return nil }
            return entry.grant
        }
    }
}
