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
    ///   - engine: the engine the task runs on (Router.taskEngine), with the account's provider.
    func open(account: String, engine: any EngineAdapter, policy: SessionPolicy, mcpPorts: [Int], key: String?, session: EngineSessionSpec?) async throws -> EngineLease
    /// Called when a session ends; a dedicated engine stops, a shared one stays.
    func release(_ lease: EngineLease) async
}

public actor EngineSupervisor: EngineSource {
    public struct Configuration: Sendable {
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
        /// How long a new engine has to answer `initialize`: one that hangs while starting is stopped, rather than
        /// holding the task (and its app) open for good.
        public var startDeadline: Duration
        /// The user's home, which developer access reads (its secrets excepted).
        public var userHome: URL
        /// Agneta's own data roots, which developer access keeps out even though they're in the home folder.
        public var agnetaRoots: [URL]

        public init(shellTool: URL, root: URL, engineLoopbackPorts: [Int] = [], confine: Bool = true,
                    ledger: (any EngineLedger)? = nil, traces: Traces? = nil, startDeadline: Duration = .seconds(60),
                    userHome: URL = FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [URL]? = nil) {
            self.userHome = userHome
            self.agnetaRoots = agnetaRoots ?? [root]
            self.startDeadline = startDeadline
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
        var temporary: [URL] = []
        /// Its account, and the account's setup generation when it started (`renew`).
        var account = ""
        var generation = 0
    }

    private let configuration: Configuration
    /// Each account's provider: how its engines sign in and which model they use.
    private var accounts: [String: ProviderSetup] = [:]
    private var running: [String: Running] = [:]
    private var starting: [String: Task<EngineLease, Error>] = [:]
    private var holders: [String: Int] = [:]
    /// Each account's setup generation, bumped by `renew`: a shared engine from an earlier one stops once nothing holds it.
    private var generations: [String: Int] = [:]
    private var broker: ToolBroker?
    private let grants = GrantTable()

    public init(_ configuration: Configuration, accounts: [String: ProviderSetup] = [:]) {
        self.configuration = configuration
        self.accounts = accounts
    }

    /// Serves `account` with this provider. When the setup differs from before (its model, key, endpoint or sign-in),
    /// the account's shared engines are renewed: a running engine keeps the setup it started with.
    public func add(account: String, provider: ProviderSetup) async {
        let previous = accounts[account]
        accounts[account] = provider
        if let previous, previous != provider { await renew(account: account) }
    }

    /// The account's settings changed (its setup, or the defaults a session starts with): its shared engines stop, at
    /// once when nothing holds them, else when the last session on them ends, so the next session starts one afresh.
    /// An engine left running would keep what it started with (Goose its GOOSE_MODEL) even after a setting is cleared.
    public func renew(account: String) async {
        generations[account, default: 0] += 1
        let idle = running.filter { $0.value.account == account && EngineKeys.isShared($0.key) && holders[$0.key, default: 0] <= 0 }
        for (key, engine) in idle where running[key]?.process.pid == engine.process.pid {
            running.removeValue(forKey: key)
            await retire(engine, "the provider's settings changed")
        }
    }

    /// A shared engine started before its account's settings last changed.
    private func isStale(_ engine: Running) -> Bool { engine.generation != generations[engine.account, default: 0] }

    /// Stops every engine serving `account` and forgets it.
    public func remove(account: String) async {
        accounts.removeValue(forKey: account)
        for (key, engine) in running where key.hasPrefix(account + "/") {
            running.removeValue(forKey: key)
            await retire(engine, "account removed")
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
        let service = ToolBroker(socketPath: socketPath, holder: configuration.shellTool.path(percentEncoded: false),
                                 resolve: { token, cwd in grants.grant(token: token, cwd: cwd) },
                                 report: { token, fields in
                                     if let traces, let lease = grants.lease(token: token) { traces.shell(lease: lease, fields) }
                                 })
        try service.start()
        broker = service
        return service
    }

    public func open(account: String, engine adapter: any EngineAdapter, policy: SessionPolicy, mcpPorts: [Int], key resume: String?,
                     session: EngineSessionSpec?) async throws -> EngineLease {
        guard let provider = accounts[account] else { throw RPCError(code: RPCError.invalidParams, message: "Unknown account \(account)") }
        // A session gets its own engine when the engine is configured per process, when it may use built-in
        // tools (the sandbox profile is per process), and on the Claude Code route (it reads its working folder).
        // A resumed session returns to its earlier engine home, where the engine keeps its sessions.
        let resumable = resume.flatMap { $0.hasPrefix(account + "/") && !$0.contains("..") ? $0 : nil }
        let dedicated = resumable.map { !EngineKeys.isShared($0) }
            ?? (adapter.capabilities.processPerSession || policy.tools != .appOnly || provider.kind == .claudeCode)
        // A shared engine's key names its engine: two engines on one account never share a process.
        let key = dedicated ? (resumable ?? "\(account)/\(UUID().uuidString.lowercased())") : EngineKeys.shared(account: account, engine: adapter.id)
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
        // An idle shared engine from before a settings change (one still starting then) is replaced now.
        if !dedicated, let existing = running[key], isStale(existing), holders[key, default: 0] <= 0 {
            running.removeValue(forKey: key)
            await retire(existing, "the provider's settings changed")
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
        let generation = generations[account, default: 0]
        let start = Task { try await self.spawn(key: key, account: account, adapter: adapter, provider: provider, dedicated: dedicated,
                                                policy: policy, mcpPorts: mcpPorts, session: session, generation: generation) }
        starting[key] = start
        defer { starting[key] = nil }
        let lease = try await start.value
        holders[key, default: 0] += 1
        return lease
    }

    private func spawn(key: String, account: String, adapter: any EngineAdapter, provider: ProviderSetup, dedicated: Bool,
                       policy: SessionPolicy, mcpPorts: [Int], session: EngineSessionSpec?, generation: Int) async throws -> EngineLease {
        let accountHome = configuration.root.appending(path: "Accounts/\(account)", directoryHint: .isDirectory)
        // Each engine process gets its own state so concurrent processes don't share a session database.
        // Agneta's own folders for this engine, each made a real folder at exactly its path and written into the
        // profiles verbatim (OwnFolder): a session that replaced one with a symlink gets nothing from it.
        var owned: Set<String> = []
        // Agneta's roots, which no session writes: its data, the app workspaces, its temp folder, and the folder holding
        // the account's own (an account reused from another Agneta's data, as agnetad does, lives there).
        let trusted = [configuration.root] + configuration.agnetaRoots + [FileManager.default.temporaryDirectory]
            + (provider.subscription.map { [$0.home.deletingLastPathComponent()] } ?? [])
        func own(_ url: URL) throws -> URL {
            let path = url.path(percentEncoded: false)
            guard let root = trusted.filter({ path.hasPrefix($0.path(percentEncoded: false).trimmingSuffix("/") + "/")
                                              || path.hasPrefix($0.realFileURL.path(percentEncoded: false).trimmingSuffix("/") + "/") })
                .max(by: { $0.path(percentEncoded: false).count < $1.path(percentEncoded: false).count }) else {
                // Every folder an engine writes is Agneta's; one elsewhere would be resolved through whatever it is now.
                throw RPCError(code: RPCError.internalError, message: "An engine asked to write outside Agneta's folders: \(path)")
            }
            let made = try OwnFolder.ensure(url, under: root)
            owned.insert(made.path(percentEncoded: false).trimmingSuffix("/"))
            return made
        }
        let engineHome = try own(dedicated ? EngineHomes.home(root: configuration.root, key: key) : accountHome)
        let scratch = try own(engineHome.appending(path: "scratch", directoryHint: .isDirectory))
        var policy = policy
        if policy.sandbox == .developer {
            let caches = try own(policy.caches(scratch: scratch))
            DeveloperAccess.clearTrustedCacheFiles(caches)
            policy.buildCaches = caches
        }

        let token = Self.newToken()
        let userHome = configuration.userHome, agnetaRoots = configuration.agnetaRoots
        let ports = configuration.engineLoopbackPorts + mcpPorts
        var session = session
        session?.policy = policy
        var launch = try adapter.launch(EngineLaunchContext(home: engineHome, provider: provider, shell: dedicated ? configuration.shellTool : nil,
                                                            session: session, loopbackPorts: ports))
        launch.writable = try launch.writable.map(own)
        launch.toolWritable = try launch.toolWritable.map(own)
        // An engine's own part of a folder it's denied (Claude Code's transcript folder for this workspace) exists before
        // the profile pins it, so the engine never has to create it.
        launch.exceptions = try launch.exceptions.map(own)
        var grant: ToolBroker.Grant?
        var tokenFile: URL?
        var brokerEnvironment: [String: String] = [:]
        if dedicated {
            let broker = try startBroker()
            let developer = policy.sandbox == .developer
            let caches = policy.caches(scratch: scratch)
            var tools = policy.toolProfile(scratch: scratch, home: userHome, agnetaRoots: agnetaRoots)
            tools.writable += launch.toolWritable
            tools.verbatim.formUnion(owned)
            tools.literalRoots = trusted
            let toolProfile = tools.render()
            var environment = [
                "PATH": (SandboxProfile.xcodeTools + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":"),
                "HOME": scratch.path(percentEncoded: false), "TMPDIR": scratch.path(percentEncoded: false), "LANG": "en_US.UTF-8",
            ]
            if let sdk = SandboxProfile.sdkRoot { environment["SDKROOT"] = sdk }
            // Developer access: commands see the user's home and toolchains, as in a terminal (writes stay confined).
            if developer {
                environment.merge(DeveloperAccess.environment(home: userHome, caches: caches)) { _, user in user }
                environment["HOME"] = userHome.path(percentEncoded: false)
                environment["USER"] = NSUserName()
            }
            // The app's own toolchain and settings win over both, its PATH ahead of everything else.
            for (key, value) in policy.toolEnvironment {
                environment[key] = key == "PATH" ? value + ":" + (environment["PATH"] ?? "") : value
            }
            grant = ToolBroker.Grant(profile: toolProfile, environment: environment)
            grants.set(token: token, grant: grant!, workspace: policy.workspace, lease: key)
            // The token in a file only this engine's profile reads, never in its environment: any process of the user's,
            // sandboxed or not, can read another non-Apple process's environment (measured: no Seatbelt rule stops
            // it), and the token runs commands as this session. A fresh file outside the engine's home, so nothing an
            // earlier engine on this home left running can read it.
            let tokens = try own(configuration.root.appending(path: "Tokens", directoryHint: .isDirectory))
            tokenFile = tokens.appending(path: UUID().uuidString)
            guard FileManager.default.createFile(atPath: tokenFile!.path(percentEncoded: false), contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw RPCError(code: RPCError.internalError, message: "Agneta couldn't write the engine's token")
            }
            launch.readable.append(tokenFile!)
            brokerEnvironment = ["AGNETA_BROKER_SOCKET": broker.socketPath, "AGNETA_BROKER_TOKEN_FILE": tokenFile!.path(percentEncoded: false)]
        }

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
            profile.readOnly = policy.readOnly + launch.readOnly
            profile.verbatim = policy.checkedPaths.union(owned)
            profile.literalRoots = trusted
            profile.ownLoopbackServer = launch.ownLoopbackServer
            profile.exceptions = launch.exceptions
            if dedicated, let broker { profile.unixSockets = [URL(filePath: broker.socketPath)] }
            if !dedicated { profile.loopbackPorts = [] ; profile.allLoopback = true }
            // Developer access: engines that run their own tools run them in this profile, so it gets the same reach.
            if dedicated, policy.sandbox == .developer {
                DeveloperAccess.widen(&profile, home: userHome, agnetaRoots: agnetaRoots, caches: policy.caches(scratch: scratch))
            }
            // Passed inline, never as a file in a folder the engine (or something it left running) could rewrite
            // between Agneta writing it and the next engine starting under it.
            wrapper = ["/usr/bin/sandbox-exec", "-p", profile.render()]
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
            initialized = try await Self.within(configuration.startDeadline) {
                try await peer.request("initialize", ["protocolVersion": 1, "clientCapabilities": [:], "clientInfo": ["name": "agneta", "version": "0"]])
            }
        } catch {
            await stop(process)
            grants.remove(token: token)
            for folder in launch.temporary + (tokenFile.map { [$0] } ?? []) { try? FileManager.default.removeItem(at: folder) }
            throw RPCError(code: RPCError.internalError, message: "The engine didn't start: \(error)")
        }
        running[key] = Running(process: process, peer: peer, token: token, grant: grant, workspace: dedicated ? policy.workspace : nil,
                               stateRoot: launch.stateRoot, engineInfo: initialized["agentInfo"], engine: adapter, temporary: launch.temporary + (tokenFile.map { [$0] } ?? []),
                               account: account, generation: generation)
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
        await retire(engine, "the engine exited")
    }

    /// A dedicated engine stops when its last holder releases it (a fork's brief hold on a task's engine
    /// mustn't stop it under a resumed session); a shared one stays.
    /// Dedicated engines whose process is being stopped, by key: nothing new starts on their home until it's gone.
    private var stopping: Set<String> = []

    public func release(_ lease: EngineLease) async {
        holders[lease.key, default: 1] -= 1
        guard holders[lease.key, default: 0] <= 0 else { return }
        holders[lease.key] = nil
        // A shared engine stays, unless its account's settings changed while sessions held it.
        if !lease.dedicated, let engine = running[lease.key], engine.process.pid == lease.pid, isStale(engine) {
            running.removeValue(forKey: lease.key)
            await retire(engine, "the provider's settings changed")
            return
        }
        guard lease.dedicated, let engine = running.removeValue(forKey: lease.key) else { return }
        stopping.insert(lease.key)
        defer { stopping.remove(lease.key) }
        await retire(engine, "session ended")
    }

    /// Ends an engine that's no longer listed: its commands can't run or start again, then it stops, then the
    /// folders made for it go.
    private func retire(_ engine: Running, _ reason: String) async {
        grants.remove(token: engine.token)
        broker?.stopCommands(token: engine.token)
        await engine.peer.close(reason)
        await stop(engine.process)
        for folder in engine.temporary { try? FileManager.default.removeItem(at: folder) }
    }

    private func stop(_ process: ChildProcess) async {
        await process.stop()
        configuration.ledger?.engineStopped(pid: process.pid)
    }

    public func stopAll() async {
        let engines = running.values
        running.removeAll()
        for engine in engines { await retire(engine, "Agneta is stopping") }
        broker?.stop()
    }

    public var processCount: Int { running.count }
    /// Lease keys of the engines running now.
    public var runningKeys: Set<String> { Set(running.keys) }

    /// Engine stderr must be read, or a full pipe blocks the engine. It goes to an owner-only log in
    /// the engine's home, kept under 1 MB (the older half is dropped).
    static func drain(_ handle: FileHandle, into file: URL, lines: (@Sendable (String) -> Void)? = nil) {
        // Opened once, never through a link an engine planted in its home (it would append to wherever that points).
        let fd = Darwin.open(file.path(percentEncoded: false), O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        Thread {
            guard fd >= 0 else { while !handle.availableData.isEmpty {}; return }
            let log = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
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
                    try? log.seek(toOffset: size - (1 << 19))
                    let kept = (try? log.readToEnd()) ?? Data()
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
            guard let entry = entries[token], cwd.isInside(entry.workspace) else { return nil }
            return entry.grant
        }
    }
}

extension EngineSupervisor {
    /// No answer within the deadline.
    struct TimedOut: Error, CustomStringConvertible {
        let after: Duration
        var description: String { "no answer within \(after.components.seconds) seconds" }
    }

    /// `work`'s result, or TimedOut once `limit` has passed (`work` is cancelled then).
    static func within<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(for: limit); return nil }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else { throw TimedOut(after: limit) }
            return value
        }
    }
}
