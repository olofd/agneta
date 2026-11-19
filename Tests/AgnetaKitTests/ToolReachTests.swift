// A contained task's sockets and ports, through the router with real listeners: one outside the app's folders that
// another program serves is refused up front, naming it and why; one in a granted folder, or that the app (this test
// process, or a child of it) serves, is allowed; developer access is unchanged. The unrelated program is a real one:
// `nc`, left to launchd by a shell that exits, ending itself after a minute whatever happens to the test. A verified
// app's team can't be signed for here, so that decision is tested through an injected identity lookup.
import Darwin
import Foundation
import Testing

@testable import AgnetaKit

/// A test server: in this process (`fd`), or a process it started (`pid`). Stopped by its pid, never by name.
final class ReachListener: @unchecked Sendable {
    let endpoint: ToolReach.Endpoint
    let pid: pid_t
    private let fd: Int32?
    private let child: Process?

    private init(endpoint: ToolReach.Endpoint, pid: pid_t, fd: Int32? = nil, child: Process? = nil) {
        (self.endpoint, self.pid, self.fd, self.child) = (endpoint, pid, fd, child)
    }

    func stop() {
        if let fd { close(fd) }
        if fd == nil { kill(pid, SIGTERM) }
        child?.waitUntilExit()
        if case .socket(let path) = endpoint { unlink(path) }
    }

    /// A loopback port nothing listens on now.
    static func freePort() throws -> Int {
        let (fd, port) = try listen(port: 0)
        close(fd)
        return port
    }

    private static func listen(port: Int) throws -> (Int32, Int) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && Darwin.listen(fd, 4) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard fd >= 0, bound else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }

    /// This process listening on a free loopback port.
    static func port() throws -> ReachListener {
        let (fd, port) = try listen(port: 0)
        return ReachListener(endpoint: .port(port), pid: getpid(), fd: fd)
    }

    /// This process listening on a Unix socket at `path`.
    static func socket(at path: String) throws -> ReachListener {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in path.utf8.enumerated() where index < raw.count - 1 { raw[index] = byte }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 && Darwin.listen(fd, 4) == 0
            }
        }
        guard fd >= 0, bound else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        return ReachListener(endpoint: .socket(URL(filePath: path).realFileURL.path(percentEncoded: false)), pid: getpid(), fd: fd)
    }

    /// `nc` listening on `endpoint`: a child of this process, or (`unrelated`) one a shell left to launchd. Either
    /// ends itself after a minute (the alarm survives its exec), so a test that dies leaves nothing listening.
    static func nc(_ endpoint: ToolReach.Endpoint, unrelated: Bool) async throws -> ReachListener {
        let arguments: String
        switch endpoint {
        case .port(let port): arguments = "-l 127.0.0.1 \(port)"
        case .socket(let path): arguments = "-lU '\(path)'"
        }
        let command = "/usr/bin/perl -e 'alarm 60; exec @ARGV' /usr/bin/nc \(arguments) </dev/null >/dev/null 2>&1"
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        let output = Pipe()
        process.standardOutput = output
        process.arguments = ["-c", unrelated ? "\(command) & echo $!" : "exec \(command)"]
        try process.run()
        let listener: ReachListener
        if unrelated {
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            listener = ReachListener(endpoint: endpoint, pid: pid)
        } else {
            listener = ReachListener(endpoint: endpoint, pid: process.processIdentifier, child: process)
        }
        // Until it really listens there (and, unrelated, has been left to launchd).
        for _ in 0..<150 {
            if PeerIdentity.listeners(on: [endpoint])[endpoint]?.contains(listener.pid) == true,
                !unrelated || PeerIdentity.parent(of: listener.pid) == 1
            {
                return listener
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        listener.stop()
        throw POSIXError(.ETIMEDOUT)
    }
}

extension RouterContractTests {
    /// A short folder of its own for sockets (a socket's path is at most 103 bytes), outside every grant.
    static func socketFolder() throws -> URL {
        let folder = URL(filePath: "/private/tmp/agneta-reach-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Opens a workspace session reaching `sockets` and `ports`: the sandbox it got, or the refusal's field and reason.
    static func reaching(
        _ stack: Stack, _ app: AppClient, sockets: [String] = [], ports: [Int] = [], ask: String? = nil
    ) async -> (level: String?, field: String?, reason: String?) {
        var policy: JSONValue = [
            "tools": "workspace", "approval": "never-ask", "toolSockets": .array(sockets.map(JSONValue.string)),
            "toolPorts": .array(ports.map { .int(Int64($0)) })
        ]
        if let ask { policy = policy.setting("sandbox", to: .string(ask)) }
        do {
            let result = try await app.request(
                "session/new",
                [
                    "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                    "_meta": [SessionPolicy.key: policy, "agneta": ["account": "brokered"]]
                ])
            return (result["_meta"]?["agneta"]?["sandbox"]?.stringValue, nil, nil)
        } catch let error as RPCError {
            return (
                nil, error.data?["agneta"]?["unenforceable"]?.arrayValue?.first?.stringValue,
                error.data?["agneta"]?["reason"]?.stringValue
            )
        } catch {
            return (nil, nil, "\(error)")
        }
    }

    static let contained: Router.Approve = { _ in
        Router.PairingAnswer(accounts: ["brokered", "native"], remember: true, sandbox: .contained)
    }

    /// Docker's socket, for one: a socket outside the app's folders that another program serves would take a
    /// contained task out of its folders. It's refused when the session opens, naming it and saying why; the same
    /// program's socket inside a folder the user granted is allowed, as the approval window showed that folder.
    @Test func aContainedTaskReachesOnlySocketsInItsFoldersOrItsApps() async throws {
        let stack = try await Stack.start(port: 47720, approve: Self.contained)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Reach")
        let folder = try Self.socketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let outside = try await ReachListener.nc(
            .socket(folder.appending(path: "other.sock").path(percentEncoded: false)), unrelated: true)
        defer { outside.stop() }
        guard case .socket(let path) = outside.endpoint else { return }
        let refused = await Self.reaching(stack, app, sockets: [path])
        #expect(refused.level == nil && refused.field == "toolSockets", "\(refused)")
        #expect(refused.reason?.contains(path) == true, "\(refused)")
        #expect(refused.reason?.contains("isn't served by Reach") == true, "\(refused)")
        #expect(refused.reason?.contains("developer access allows it") == true, "\(refused)")
        // Nothing listening at all is no better.
        let missing = await Self.reaching(stack, app, sockets: [folder.appending(path: "none.sock").path(percentEncoded: false)])
        #expect(missing.field == "toolSockets", "\(missing)")

        // In the granted folder, whoever serves it.
        let inside = try await ReachListener.nc(
            .socket(stack.root.appending(path: "work/in.sock").path(percentEncoded: false)), unrelated: true)
        defer { inside.stop() }
        guard case .socket(let granted) = inside.endpoint else { return }
        let allowed = await Self.reaching(stack, app, sockets: [granted])
        #expect(allowed.level == "contained", "\(allowed)")

        // Outside the folders but served by the app itself (this process, the app's end of the connection).
        let own = try ReachListener.socket(at: folder.appending(path: "own.sock").path(percentEncoded: false))
        defer { own.stop() }
        guard case .socket(let ownPath) = own.endpoint else { return }
        let served = await Self.reaching(stack, app, sockets: [ownPath])
        #expect(served.level == "contained", "\(served)")
    }

    /// A port is allowed only when the app serves it: refused when another program listens there, or nothing does;
    /// allowed when the app's own process or one it started listens there.
    @Test func aContainedTaskReachesOnlyItsAppsPorts() async throws {
        let stack = try await Stack.start(port: 47721, approve: Self.contained)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Reach")

        let other = try await ReachListener.nc(.port(try ReachListener.freePort()), unrelated: true)
        defer { other.stop() }
        guard case .port(let otherPort) = other.endpoint else { return }
        let refused = await Self.reaching(stack, app, ports: [otherPort])
        #expect(refused.level == nil && refused.field == "toolPorts", "\(refused)")
        #expect(refused.reason?.contains("port \(otherPort)") == true, "\(refused)")
        #expect(refused.reason?.contains("developer access allows it") == true, "\(refused)")
        let unused = try ReachListener.freePort()
        #expect(await Self.reaching(stack, app, ports: [unused]).field == "toolPorts")

        let own = try ReachListener.port()
        defer { own.stop() }
        guard case .port(let ownPort) = own.endpoint else { return }
        let served = await Self.reaching(stack, app, ports: [ownPort])
        #expect(served.level == "contained", "\(served)")

        let child = try await ReachListener.nc(.port(try ReachListener.freePort()), unrelated: false)
        defer { child.stop() }
        guard case .port(let childPort) = child.endpoint else { return }
        let started = await Self.reaching(stack, app, ports: [childPort])
        #expect(started.level == "contained", "\(started)")
        // One refused endpoint refuses the session, whatever else it names.
        let mixed = await Self.reaching(stack, app, ports: [ownPort, otherPort])
        #expect(mixed.field == "toolPorts" && mixed.reason?.contains("port \(otherPort)") == true, "\(mixed)")
    }

    /// Loading or forking a task checks again: the app served its port when the task started, then stopped, and
    /// another program took the port. The saved policy still names it, and both are refused.
    @Test func aLoadedOrForkedTaskIsCheckedAgain() async throws {
        let stack = try await Stack.start(port: 47723, approve: Self.contained)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Reach")
        let own = try ReachListener.port()
        guard case .port(let port) = own.endpoint else { return }
        let session = try await app.request(
            "session/new",
            [
                "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                "_meta": [
                    SessionPolicy.key: ["tools": "workspace", "approval": "never-ask", "toolPorts": [.int(Int64(port))]],
                    "agneta": ["account": "brokered"]
                ]
            ])["sessionId"]?.stringValue
        let id = try #require(session)
        _ = try await app.request("session/close", ["sessionId": .string(id)])
        own.stop()
        let other = try await ReachListener.nc(.port(port), unrelated: true)
        defer { other.stop() }
        for method in ["session/load", "agneta/fork"] {
            do {
                _ = try await app.request(
                    method,
                    [
                        "sessionId": .string(id), "mcpServers": [],
                        "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false))
                    ])
                Issue.record("\(method) reached another program's port")
            } catch let error as RPCError {
                #expect(
                    error.code == RPCError.invalidParams
                        && error.data?["agneta"]?["unenforceable"]?.arrayValue?.first == "toolPorts"
                        && error.message.contains("port \(port)"),
                    "\(method): \(error.message)")
            }
        }
    }

    /// Developer access reaches every local server, as a terminal does: the socket and port a contained task of the
    /// same app is refused are allowed to its developer tasks, unchanged.
    @Test func developerAccessStillReachesAnyLocalServer() async throws {
        let stack = try await Stack.start(port: 47722)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Reach")
        let folder = try Self.socketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = try await ReachListener.nc(
            .socket(folder.appending(path: "other.sock").path(percentEncoded: false)), unrelated: true)
        defer { socket.stop() }
        let port = try await ReachListener.nc(.port(try ReachListener.freePort()), unrelated: true)
        defer { port.stop() }
        guard case .socket(let path) = socket.endpoint, case .port(let number) = port.endpoint else { return }

        let developer = await Self.reaching(stack, app, sockets: [path], ports: [number])
        #expect(developer.level == "developer", "\(developer)")
        let contained = await Self.reaching(stack, app, sockets: [path], ports: [number], ask: "contained")
        #expect(contained.field == "toolSockets", "\(contained)")
    }
}

/// The decision itself, through an injected lookup: a verified app's helpers count by their team, an unverified app
/// by its connection's process and what it started; every process bound there must be the app.
@Suite struct ToolReachTests {
    static func identity(_ pid: pid_t, team: String?, trusted: Bool) -> PeerIdentity {
        var identity = PeerIdentity(pid: pid, path: nil, identifier: "com.example.\(pid)", team: team, valid: true)
        identity.trusted = trusted
        return identity
    }

    /// pid 10 is the app's connection; 11 its child, 12 its grandchild; 20 another program; 30 a helper signed by the
    /// app's team but not started by it; 31 ad hoc code claiming that team.
    static let parents: [pid_t: pid_t] = [10: 1, 11: 10, 12: 11, 20: 1, 30: 1, 31: 1]
    static func lookup(_ holders: [ToolReach.Endpoint: [pid_t]]) -> ToolReach.Lookup {
        ToolReach.Lookup(
            connection: { _, _ in [10] }, listeners: { wanted in holders.filter { wanted.contains($0.key) } },
            identity: { pid in
                switch pid {
                case 10, 11, 30: identity(pid, team: "TEAM", trusted: true)
                case 31: identity(pid, team: "TEAM", trusted: false)
                default: identity(pid, team: "OTHER", trusted: true)
                }
            },
            parent: { parents[$0] })
    }

    @Test func aVerifiedAppServesWhatItsTeamsSignedProcessesListenOn() {
        let holders: [ToolReach.Endpoint: [pid_t]] = [
            .port(1): [10], .port(2): [30], .port(3): [31], .port(4): [20], .port(5): [10, 20], .port(6): [12],
            .socket("/x/app.sock"): [11, 30]
        ]
        let served = ToolReach.served(
            Array(holders.keys) + [.port(7)], by: ToolReach.App(team: "TEAM", pids: []), lookup: Self.lookup(holders))
        // Its own process and a helper of its team; never ad hoc code claiming the team, another team, a port shared
        // with another program, a child signed by another team (12), or nothing listening.
        #expect(served == [.port(1), .port(2), .socket("/x/app.sock")])
    }

    @Test func anUnverifiedAppServesWhatItsProcessAndItsChildrenListenOn() {
        let holders: [ToolReach.Endpoint: [pid_t]] = [
            .port(1): [10], .port(2): [11], .port(3): [12], .port(4): [20], .port(5): [30], .port(6): [11, 20]
        ]
        let served = ToolReach.served(
            Array(holders.keys), by: ToolReach.App(team: nil, pids: [10]), lookup: Self.lookup(holders))
        #expect(served == [.port(1), .port(2), .port(3)])
        // No connection found: nothing is the app's.
        #expect(
            ToolReach.served(Array(holders.keys), by: ToolReach.App(team: nil, pids: []), lookup: Self.lookup(holders))
                .isEmpty)
        // A loop in the parents (a pid reused mid-walk) ends, unmatched.
        #expect(!ToolReach.descends(40, from: [10], parent: { $0 == 40 ? 41 : 40 }))
    }

    /// The grant's side, as rechecked when the grant changes: a socket in a granted folder needs no listener, one
    /// outside needs the app to serve it, a port always does; developer access isn't checked. The refusal names it.
    @Test func theGrantDecidesWhatAContainedSessionReaches() throws {
        let grant = Router.Grant(
            app: "Example", identifier: "com.example.app", team: "TEAM", verified: true, accounts: ["a"],
            tools: .workspace, folders: ["/private/tmp/granted/"])
        var policy = SessionPolicy.fallback(workspace: URL(filePath: "/private/tmp/granted", directoryHint: .isDirectory))
        policy.toolSockets = [URL(filePath: "/private/tmp/granted/in.sock"), URL(filePath: "/private/tmp/out.sock")]
        policy.toolPorts = [4100]
        #expect(ToolReach.unresolved(policy, grant: grant) == [.port(4100), .socket("/private/tmp/out.sock")])

        let socket = try #require(GrantScope.reach(policy, against: grant, sandbox: .contained))
        #expect(socket.field == "toolSockets" && socket.reason.contains("/private/tmp/out.sock"))
        #expect(socket.reason.contains("signed by its developer") && socket.reason.contains("developer access allows it"))
        policy.servedByApp = [.socket("/private/tmp/out.sock")]
        let port = try #require(GrantScope.reach(policy, against: grant, sandbox: .contained))
        #expect(port.field == "toolPorts" && port.reason.contains("port 4100"))
        policy.servedByApp.insert(.port(4100))
        #expect(GrantScope.reach(policy, against: grant, sandbox: .contained) == nil)
        #expect(GrantScope.reach(SessionPolicy.fallback(workspace: policy.workspace), against: grant, sandbox: .contained) == nil)

        // A grant whose folders no longer hold the socket no longer fits the running session.
        var narrowed = grant
        narrowed.folders = ["/private/tmp/elsewhere/"]
        #expect(GrantScope.reach(policy, against: narrowed, sandbox: .contained)?.field == "toolSockets")
        policy.servedByApp = []
        #expect(GrantScope.reach(policy, against: grant, sandbox: .developer) == nil)
    }

    /// The system lookup finds what this process listens on, and only that: a port, and a socket by its real path
    /// (/tmp is /private/tmp), quickly enough to run at every session open.
    @Test func theSystemLookupFindsRealListeners() throws {
        let port = try ReachListener.port()
        defer { port.stop() }
        let folder = URL(filePath: "/tmp/agneta-reach-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = try ReachListener.socket(at: folder.appending(path: "s.sock").path(percentEncoded: false))
        defer { socket.stop() }
        guard case .socket(let real) = socket.endpoint else { return }
        #expect(real.hasPrefix("/private/tmp/"))
        let unused = try ReachListener.freePort()
        let started = ContinuousClock.now
        let found = PeerIdentity.listeners(on: [port.endpoint, socket.endpoint, .port(unused)])
        let took = ContinuousClock.now - started
        #expect(found[port.endpoint] == [getpid()] && found[socket.endpoint] == [getpid()] && found[.port(unused)] == nil)
        #expect(took < .seconds(2), "\(took)")
        #expect(PeerIdentity.parent(of: getpid()) == getppid())
    }
}
