// A contained task's sockets and ports, through the router with real listeners: one outside the app's folders that
// another program serves is refused up front, naming it and why; one in a granted folder, or that the app (this test
// process, or a child of it) serves, is allowed; developer access is unchanged. Who serves an endpoint is what the
// kernel says when Agneta connects to it, never the path a process bound with: an app that binds in its own folder and
// then changes folder, or swaps the folder for a link, claims nothing. The unrelated program is a real one: `nc`, left
// to launchd by a shell that exits, ending itself after a minute whatever happens to the test. A verified app's team,
// a server the scan can't see (root's) and a reused pid can't be made here, so they're tested through the lookup.
import Darwin
import Foundation
import Testing

@testable import AgnetaKit

/// A test server: in this process (accepting on a thread of its own), or a process it started. Stopped by its pid,
/// never by name.
final class ReachListener: @unchecked Sendable {
    let endpoint: ToolReach.Endpoint
    let pid: pid_t
    private let acceptor: Acceptor?
    private let child: Process?

    private init(endpoint: ToolReach.Endpoint, pid: pid_t, acceptor: Acceptor? = nil, child: Process? = nil) {
        (self.endpoint, self.pid, self.acceptor, self.child) = (endpoint, pid, acceptor, child)
    }

    var path: String {
        guard case .socket(let path) = endpoint else { return "" }
        return path
    }
    var port: Int {
        guard case .port(let port) = endpoint else { return 0 }
        return port
    }

    func stop() {
        if let acceptor {
            acceptor.stop()
        } else {
            kill(pid, SIGTERM)
        }
        child?.waitUntilExit()
        if case .socket(let path) = endpoint { unlink(path) }
    }

    /// Stops listening but leaves the socket's file, as a server that died would (Docker Desktop's, once it's quit).
    func closeKeepingFile() { acceptor?.stop() }

    /// How a server in this process takes connections: drained until the client closes (the default), accepted only
    /// after a delay (a busy server), closed as soon as accepted, or never accepted at all.
    enum Accepting: Sendable { case drain, late(Double), closeAtOnce, never }

    /// Accepts connections as `accepting` says until stopped, then closes the listening socket itself (from its own
    /// thread, so the descriptor can't be reused under it).
    final class Acceptor: @unchecked Sendable {
        private let lock = NSLock()
        private var stopping = false
        private let done = DispatchSemaphore(value: 0)

        init(_ fd: Int32, accepting: Accepting = .drain) {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            Thread { [self] in
                while !lock.withLock({ stopping }) {
                    var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    guard poll(&poller, 1, 50) == 1 else { continue }
                    switch accepting {
                    case .never: continue
                    case .late(let seconds): Thread.sleep(forTimeInterval: seconds)
                    default: break
                    }
                    let client = accept(fd, nil, nil)
                    guard client >= 0 else { continue }
                    if case .closeAtOnce = accepting {
                        close(client)
                        continue
                    }
                    _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                    Thread {
                        var buffer = [UInt8](repeating: 0, count: 256)
                        while read(client, &buffer, buffer.count) > 0 {}
                        close(client)
                    }.start()
                }
                close(fd)
                done.signal()
            }.start()
        }

        func stop() {
            let first = lock.withLock { () -> Bool in
                defer { stopping = true }
                return !stopping
            }
            if first { _ = done.wait(timeout: .now() + 2) }
        }
    }

    /// A loopback port nothing listens on now (another program may take it before it's used: callers retry).
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
                bind(fd, $0, length) == 0 && Darwin.listen(fd, 16) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard fd >= 0, bound else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }

    /// This process listening on a loopback port the kernel picks: no other program can take it first.
    static func port(accepting: Accepting = .drain) throws -> ReachListener {
        let (fd, port) = try listen(port: 0)
        return ReachListener(endpoint: .port(port), pid: getpid(), acceptor: Acceptor(fd, accepting: accepting))
    }

    /// The most a socket's path may hold (sun_path, less its terminating NUL): longer is refused, never cut short.
    static let socketPathLimit = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// This process listening on a Unix socket at `path`.
    static func socket(at path: String) throws -> ReachListener {
        guard path.utf8.count <= socketPathLimit else { throw POSIXError(.ENAMETOOLONG) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in path.utf8.enumerated() { raw[index] = byte }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 && Darwin.listen(fd, 16) == 0
            }
        }
        guard fd >= 0, bound else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        return ReachListener(
            endpoint: .socket(URL(filePath: path).realFileURL.path(percentEncoded: false)), pid: getpid(),
            acceptor: Acceptor(fd))
    }

    /// `nc` serving a Unix socket at `path`: a child of this process, or (`unrelated`) one a shell left to launchd.
    static func nc(socket path: String, unrelated: Bool) async throws -> ReachListener {
        guard path.utf8.count <= socketPathLimit else { throw POSIXError(.ENAMETOOLONG) }
        let real = URL(filePath: path).realFileURL.path(percentEncoded: false)
        return try await start(["-dlkU", path], endpoint: .socket(real), unrelated: unrelated)
    }

    /// `nc` serving a loopback port (`port`, or a free one): another program can take a port between finding it free
    /// and `nc` binding it, so a try that doesn't bind is tried again on another.
    static func nc(port: Int? = nil, unrelated: Bool) async throws -> ReachListener {
        for _ in 0..<5 {
            let chosen = try port ?? freePort()
            if let listener = try? await start(
                ["-dlk", "127.0.0.1", String(chosen)], endpoint: .port(chosen), unrelated: unrelated)
            {
                return listener
            }
            if port != nil { break }
        }
        throw POSIXError(.EADDRINUSE)
    }

    /// Each ends itself after a minute (the alarm survives its exec), so a test that dies leaves nothing listening.
    private static func start(_ arguments: [String], endpoint: ToolReach.Endpoint, unrelated: Bool) async throws
        -> ReachListener
    {
        let quoted = arguments.map { "'\($0)'" }.joined(separator: " ")
        let command = "/usr/bin/perl -e 'alarm 60; exec @ARGV' /usr/bin/nc \(quoted) </dev/null >/dev/null 2>&1"
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
        // Until it really listens there (and, unrelated, has been left to launchd), or has gone (it couldn't bind).
        for _ in 0..<500 {
            if PeerIdentity.listeners(on: [endpoint])[endpoint]?.contains(listener.pid) == true,
                !unrelated || PeerIdentity.parent(of: listener.pid) == 1
            {
                return listener
            }
            if unrelated ? kill(listener.pid, 0) != 0 : !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        listener.stop()
        throw POSIXError(.ETIMEDOUT)
    }

    /// A child of this process (so, for an unverified app, the app's) that binds a socket where it may write and then
    /// makes the path it bound with name another folder, as an app claiming a socket it doesn't serve would: `chdir`
    /// binds `target.sock` relative in `own`, then changes to `other`; `link` binds `own/d/target.sock`, then renames
    /// `d` away and puts a link to `other` in its place. Ends itself after a minute.
    static func claim(_ how: String, own: URL, other: URL) throws -> (pid: pid_t, stop: () -> Void) {
        let script = """
            use Socket; alarm 60;
            my ($how, $own, $other) = @ARGV;
            socket(my $s, PF_UNIX, SOCK_STREAM, 0) or die;
            if ($how eq "chdir") {
                chdir $own or die; bind($s, pack_sockaddr_un("target.sock")) or die; listen($s, 5) or die;
                chdir $other or die;
            } else {
                mkdir "$own/d"; bind($s, pack_sockaddr_un("$own/d/target.sock")) or die; listen($s, 5) or die;
                rename("$own/d", "$own/d.old") or die; symlink($other, "$own/d") or die;
            }
            $| = 1; print "ready\\n"; sleep 60;
            """
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/perl")
        process.arguments = ["-e", script, how, own.path(percentEncoded: false), other.path(percentEncoded: false)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let stop = {
            kill(process.processIdentifier, SIGTERM)
            process.waitUntilExit()
        }
        let line = output.fileHandleForReading.availableData
        guard String(decoding: line, as: UTF8.self).hasPrefix("ready") else {
            stop()
            throw POSIXError(.EPERM)
        }
        return (process.processIdentifier, stop)
    }
}

extension RouterContractTests {
    /// A short folder of its own for sockets (a socket's path is at most 103 bytes), outside every grant.
    static func socketFolder() throws -> URL {
        let folder = URL(
            filePath: "/private/tmp/agneta-reach-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
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
            socket: folder.appending(path: "other.sock").path(percentEncoded: false), unrelated: true)
        defer { outside.stop() }
        let refused = await Self.reaching(stack, app, sockets: [outside.path])
        #expect(refused.level == nil && refused.field == "toolSockets", "\(refused)")
        #expect(refused.reason?.contains(outside.path) == true, "\(refused)")
        #expect(refused.reason?.contains("isn't served by Reach") == true, "\(refused)")
        #expect(refused.reason?.contains("developer access allows it") == true, "\(refused)")
        // Nothing listening at all is no better.
        let missing = await Self.reaching(
            stack, app, sockets: [folder.appending(path: "none.sock").path(percentEncoded: false)])
        #expect(missing.field == "toolSockets", "\(missing)")

        // In the granted folder, whoever serves it.
        let inside = try await ReachListener.nc(
            socket: stack.root.appending(path: "work/in.sock").path(percentEncoded: false), unrelated: true)
        defer { inside.stop() }
        let allowed = await Self.reaching(stack, app, sockets: [inside.path])
        #expect(allowed.level == "contained", "\(allowed)")

        // Outside the folders but served by the app itself (this process, the app's end of the connection).
        let own = try ReachListener.socket(at: folder.appending(path: "own.sock").path(percentEncoded: false))
        defer { own.stop() }
        let served = await Self.reaching(stack, app, sockets: [own.path])
        #expect(served.level == "contained", "\(served)")
    }

    /// The path a process bound with is its own string: bound in the app's folder, then made to name another folder
    /// by changing folder or by swapping its folder for a link (the process scan then credits the app with the
    /// other folder's socket). The kernel's answer, when Agneta connects there, is what counts: nothing, or another
    /// program, is refused, so a server started there later (Docker, launched once the session opened) isn't reached.
    @Test func anAppCantClaimASocketByThePathItBoundWith() async throws {
        let stack = try await Stack.start(port: 47724, approve: Self.contained)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Reach")
        for how in ["chdir", "link"] {
            let root = try Self.socketFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let own = root.appending(path: "own", directoryHint: .isDirectory)
            let other = root.appending(path: "other", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let target = other.appending(path: "target.sock").realFileURL.path(percentEncoded: false)
            let claim = try ReachListener.claim(how, own: own, other: other)
            defer { claim.stop() }
            // The claim works on the scan: it credits the app's child with the other folder's socket.
            #expect(
                PeerIdentity.listeners(on: [.socket(target)])[.socket(target)]?.contains(claim.pid) == true, "\(how)")

            let nothing = await Self.reaching(stack, app, sockets: [target])
            #expect(nothing.field == "toolSockets" && nothing.reason?.contains(target) == true, "\(how): \(nothing)")
            let server = try await ReachListener.nc(socket: target, unrelated: true)
            defer { server.stop() }
            let another = await Self.reaching(stack, app, sockets: [target])
            #expect(another.field == "toolSockets", "\(how): \(another)")
        }
    }

    /// A port is allowed only when the app serves it: refused when another program listens there, or nothing does;
    /// allowed when the app's own process or one it started accepts the connection.
    @Test func aContainedTaskReachesOnlyItsAppsPorts() async throws {
        let stack = try await Stack.start(port: 47721, approve: Self.contained)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Reach")

        let other = try await ReachListener.nc(unrelated: true)
        defer { other.stop() }
        let refused = await Self.reaching(stack, app, ports: [other.port])
        #expect(refused.level == nil && refused.field == "toolPorts", "\(refused)")
        #expect(refused.reason?.contains("port \(other.port)") == true, "\(refused)")
        #expect(refused.reason?.contains("developer access allows it") == true, "\(refused)")
        let unused = try ReachListener.freePort()
        #expect(await Self.reaching(stack, app, ports: [unused]).field == "toolPorts")

        let own = try ReachListener.port()
        defer { own.stop() }
        let served = await Self.reaching(stack, app, ports: [own.port])
        #expect(served.level == "contained", "\(served)")

        let child = try await ReachListener.nc(unrelated: false)
        defer { child.stop() }
        let started = await Self.reaching(stack, app, ports: [child.port])
        #expect(started.level == "contained", "\(started)")
        // One refused endpoint refuses the session, whatever else it names.
        let mixed = await Self.reaching(stack, app, ports: [own.port, other.port])
        #expect(mixed.field == "toolPorts" && mixed.reason?.contains("port \(other.port)") == true, "\(mixed)")
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
        defer { own.stop() }
        let port = own.port
        let session = try await app.request(
            "session/new",
            [
                "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                "_meta": [
                    SessionPolicy.key: [
                        "tools": "workspace", "approval": "never-ask", "toolPorts": [.int(Int64(port))]
                    ],
                    "agneta": ["account": "brokered"]
                ]
            ])["sessionId"]?.stringValue
        let id = try #require(session)
        _ = try await app.request("session/close", ["sessionId": .string(id)])
        own.stop()
        let other = try await ReachListener.nc(port: port, unrelated: true)
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

    /// The probes wait on servers, so they never run on the router: an app naming its most ports, each listening and
    /// never accepting, has its session checked (and allowed: the app's own listeners say so) while another app's
    /// session opens at once. Beyond the most, the policy is refused before anything is probed.
    @Test func oneAppsSilentServersDontHoldUpAnother() async throws {
        let stack = try await Stack.start(port: 47725, approve: Self.contained)
        defer { stack.stop() }
        let slow = AppClient(port: stack.port)
        defer { slow.close() }
        try await slow.pairAndInitialize("Slow")
        let other = AppClient(port: stack.port)
        defer { other.close() }
        try await other.pairAndInitialize("Other")
        let silent = try (0..<ToolReach.most).map { _ in try ReachListener.port(accepting: .never) }
        defer { for listener in silent { listener.stop() } }

        let started = ContinuousClock.now
        async let checked = Self.reaching(stack, slow, ports: silent.map(\.port))
        try await Task.sleep(for: .milliseconds(30))
        let quick = ContinuousClock.now
        let opened = await Self.reaching(stack, other)
        let otherTook = ContinuousClock.now - quick
        #expect(opened.level == "contained" && otherTook < .seconds(1), "\(opened) after \(otherTook)")
        let result = await checked
        #expect(result.level == "contained" && ContinuousClock.now - started < .seconds(4), "\(result)")

        let one = try ReachListener.port()
        defer { one.stop() }
        let tooMany = await Self.reaching(stack, slow, ports: Array(repeating: one.port, count: ToolReach.most + 1))
        #expect(
            tooMany.field == "toolPorts" && tooMany.reason?.contains("at most \(ToolReach.most)") == true, "\(tooMany)")
    }

    /// The same with servers that take a second each to answer (through the lookup): the probes run together, under
    /// one deadline, and off the router, so another app's session opens at once.
    @Test func slowProbesRunTogetherAndOffTheRouter() async throws {
        var slowLookup = ToolReach.Lookup.system
        slowLookup.answer = { endpoint in
            Thread.sleep(forTimeInterval: 1)
            return ToolReach.Lookup.system.answer(endpoint)
        }
        let stack = try await Stack.start(port: 47726, reach: slowLookup, approve: Self.contained)
        defer { stack.stop() }
        let slow = AppClient(port: stack.port)
        defer { slow.close() }
        try await slow.pairAndInitialize("Slow")
        let other = AppClient(port: stack.port)
        defer { other.close() }
        try await other.pairAndInitialize("Other")
        let servers = try (0..<ToolReach.most).map { _ in try ReachListener.port() }
        defer { for server in servers { server.stop() } }

        let started = ContinuousClock.now
        async let checked = Self.reaching(stack, slow, ports: servers.map(\.port))
        try await Task.sleep(for: .milliseconds(100))
        let quick = ContinuousClock.now
        let opened = await Self.reaching(stack, other)
        let otherTook = ContinuousClock.now - quick
        #expect(opened.level == "contained" && otherTook < .milliseconds(500), "\(opened) after \(otherTook)")
        let result = await checked
        let took = ContinuousClock.now - started
        #expect(result.level == "contained" && took < .seconds(3), "\(result) after \(took)")
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
            socket: folder.appending(path: "other.sock").path(percentEncoded: false), unrelated: true)
        defer { socket.stop() }
        let port = try await ReachListener.nc(unrelated: true)
        defer { port.stop() }

        let developer = await Self.reaching(stack, app, sockets: [socket.path], ports: [port.port])
        #expect(developer.level == "developer", "\(developer)")
        let contained = await Self.reaching(stack, app, sockets: [socket.path], ports: [port.port], ask: "contained")
        #expect(contained.field == "toolSockets", "\(contained)")
    }
}

/// The decision itself, through an injected lookup: a verified app's helpers count by their team, an unverified app
/// by its connection's process and what it started; the kernel's answer decides, and every process the scan finds
/// bound there must be the app too.
@Suite struct ToolReachTests {
    static func identity(_ pid: pid_t, team: String?, trusted: Bool) -> PeerIdentity {
        var identity = PeerIdentity(pid: pid, path: nil, identifier: "com.example.\(pid)", team: team, valid: true)
        identity.trusted = trusted
        return identity
    }

    /// pid 10 is the app's connection; 11 its child, 12 its grandchild; 20 another program; 30 a helper signed by the
    /// app's team but not started by it; 31 ad hoc code claiming that team; 99 root's, which no scan can see.
    static let parents: [pid_t: pid_t] = [10: 1, 11: 10, 12: 11, 20: 1, 30: 1, 31: 1, 99: 1]
    static func started(_ pid: pid_t) -> ToolReach.Instance { ToolReach.Instance(pid: pid, started: UInt64(pid) * 7) }
    static let app = ToolReach.App(team: nil, processes: [started(10)])
    static let verified = ToolReach.App(team: "TEAM", processes: [])

    /// `answers`: whom a connection to each endpoint reaches (by default, the scan's holders); `holders`: the scan.
    static func lookup(
        answers: [ToolReach.Endpoint: ToolReach.Answer] = [:], holders: [ToolReach.Endpoint: [pid_t]] = [:],
        current: @escaping @Sendable (ToolReach.Peer) -> Bool = { _ in true },
        instance: @escaping @Sendable (pid_t) -> ToolReach.Instance? = { started($0) }
    ) -> ToolReach.Lookup {
        ToolReach.Lookup(
            connection: { _, _ in [10] },
            answer: { endpoint in
                answers[endpoint]
                    ?? holders[endpoint].map { .peers(Set($0.map { ToolReach.Peer(pid: $0) })) } ?? .nothing
            },
            listeners: { wanted in holders.filter { wanted.contains($0.key) } },
            identity: { peer in
                switch peer.pid {
                case 10, 11, 30: identity(peer.pid, team: "TEAM", trusted: true)
                case 31: identity(peer.pid, team: "TEAM", trusted: false)
                default: identity(peer.pid, team: "OTHER", trusted: true)
                }
            },
            current: current, instance: instance, parent: { parents[$0] })
    }

    static func peers(_ pids: pid_t...) -> ToolReach.Answer { .peers(Set(pids.map { ToolReach.Peer(pid: $0) })) }

    @Test func aVerifiedAppServesWhatItsTeamsSignedProcessesListenOn() {
        let holders: [ToolReach.Endpoint: [pid_t]] = [
            .port(1): [10], .port(2): [30], .port(3): [31], .port(4): [20], .port(5): [10, 20], .port(6): [12],
            .socket("/x/app.sock"): [11, 30]
        ]
        let served = ToolReach.served(
            Array(holders.keys) + [.port(7)], by: Self.verified, lookup: Self.lookup(holders: holders))
        // Its own process and a helper of its team; never ad hoc code claiming the team, another team, a port shared
        // with another program, a child signed by another team (12), or nothing listening.
        #expect(served == [.port(1), .port(2), .socket("/x/app.sock")])
    }

    @Test func anUnverifiedAppServesWhatItsProcessAndItsChildrenListenOn() {
        let holders: [ToolReach.Endpoint: [pid_t]] = [
            .port(1): [10], .port(2): [11], .port(3): [12], .port(4): [20], .port(5): [30], .port(6): [11, 20]
        ]
        let served = ToolReach.served(Array(holders.keys), by: Self.app, lookup: Self.lookup(holders: holders))
        #expect(served == [.port(1), .port(2), .port(3)])
        // No connection found: nothing is the app's.
        #expect(
            ToolReach.served(
                Array(holders.keys), by: ToolReach.App(team: nil, processes: []), lookup: Self.lookup(holders: holders)
            ).isEmpty)
        // A loop in the parents ends, unmatched.
        let looping = ToolReach.Lookup(
            connection: { _, _ in [] }, answer: { _ in .nothing }, listeners: { _ in [:] },
            identity: { Self.identity($0.pid, team: nil, trusted: false) }, current: { _ in true },
            instance: { Self.started($0) }, parent: { $0 == 40 ? 41 : 40 })
        #expect(!ToolReach.descends(40, from: [Self.started(10)], lookup: looping))
    }

    /// The scan only ever narrows. The app claims an endpoint in the scan (a path it bound with, or a listener of
    /// its own beside another's), while a connection there reaches a process the scan can't see (root's: usbmuxd,
    /// a VPN's, Docker's helper), nothing at all, or something that can't be identified: none is the app's.
    @Test func whatTheKernelSaysDecidesNotWhatTheScanClaims() {
        let socket = ToolReach.Endpoint.socket("/var/run/root.sock"), port = ToolReach.Endpoint.port(8125)
        let claims: [ToolReach.Endpoint: [pid_t]] = [socket: [10], port: [10]]
        for answer in [Self.peers(99), .nothing, .unidentified, Self.peers(10, 99)] {
            for app in [Self.app, Self.verified] {
                let lookup = Self.lookup(answers: [socket: answer, port: answer], holders: claims)
                #expect(ToolReach.served([socket, port], by: app, lookup: lookup).isEmpty, "\(answer)")
            }
        }
        // The same answer naming the app is the app's, and a scan finding another holder too still refuses.
        #expect(
            ToolReach.served(
                [socket, port], by: Self.app,
                lookup: Self.lookup(answers: [socket: Self.peers(11), port: Self.peers(10)], holders: claims))
                == [socket, port])
        #expect(
            ToolReach.served(
                [port], by: Self.app, lookup: Self.lookup(answers: [port: Self.peers(10)], holders: [port: [10, 20]])
            ).isEmpty)
    }

    /// Processes are instances: the app's connection process exited and its pid went to another program, a pid that
    /// changed instance while it was checked, or an audit token whose process is gone, is never the app.
    @Test func aReusedPidIsNeverTheApp() {
        let holders: [ToolReach.Endpoint: [pid_t]] = [.port(1): [10], .port(2): [11]]
        let later = Self.lookup(
            holders: holders,
            instance: {
                ToolReach.Instance(pid: $0, started: $0 == 10 ? 1 : UInt64($0) * 7)
            })
        #expect(ToolReach.served([.port(1), .port(2)], by: Self.app, lookup: later).isEmpty)
        let counter = Counter()
        let changing = Self.lookup(
            holders: holders,
            instance: { pid in
                ToolReach.Instance(pid: pid, started: pid == 11 ? counter.next() : UInt64(pid) * 7)
            })
        #expect(ToolReach.served([.port(2)], by: Self.app, lookup: changing).isEmpty)
        let token: ToolReach.Answer = .peers([ToolReach.Peer(pid: 10, token: [1, 2, 3, 4, 5, 10, 7, 8])])
        let gone = Self.lookup(answers: [.port(1): token], current: { _ in false })
        #expect(ToolReach.served([.port(1)], by: Self.verified, lookup: gone).isEmpty)
        #expect(
            ToolReach.served([.port(1)], by: Self.verified, lookup: Self.lookup(answers: [.port(1): token])) == [
                .port(1)
            ])
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        func next() -> UInt64 {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    /// Before each command the broker asks again; `lost` names the first endpoint the app no longer serves, and what
    /// serves it now, for the reason the app is given.
    @Test func aCheckNamesWhatItsAppNoLongerServes() throws {
        let check = ToolReach.Check(app: Self.app, name: "Example", endpoints: [.port(1), .socket("/s.sock")])
        #expect(
            ToolReach.lost(
                check, lookup: Self.lookup(holders: [.port(1): [10], .socket("/s.sock"): [11]]), retry: .zero)
                == nil)
        let lost = try #require(
            ToolReach.lost(
                check, lookup: Self.lookup(holders: [.port(1): [10], .socket("/s.sock"): [20]]), retry: .zero))
        #expect(lost.0 == .socket("/s.sock") && lost.1 == .other)
        #expect(ToolReach.reason(lost.0, lost.1, app: "Example").contains("/s.sock is served by another program now"))
        let gone = try #require(
            ToolReach.lost(check, lookup: Self.lookup(holders: [.socket("/s.sock"): [11]]), retry: .zero))
        #expect(gone.0 == .port(1) && gone.1 == .nothing)
    }

    /// A busy server can miss one look: a re-check tries again before stopping the session, and when it does stop,
    /// it says the server didn't answer in time rather than that another program took it.
    @Test func aReCheckTriesAgainBeforeStopping() throws {
        let check = ToolReach.Check(app: Self.app, name: "Example", endpoints: [.port(1)])
        let counter = Counter()
        let slow = Self.lookup(answers: [:], holders: [:]).with { _ in
            counter.next() == 1 ? .unidentified : Self.peers(10)
        }
        #expect(ToolReach.lost(check, lookup: slow, retry: .milliseconds(10)) == nil)
        let silent = Self.lookup(answers: [.port(1): .unidentified])
        let lost = try #require(ToolReach.lost(check, lookup: silent, retry: .milliseconds(10)))
        #expect(lost.1 == .unidentified)
        #expect(ToolReach.reason(lost.0, lost.1, app: "Example").contains("didn't answer in time"))
    }

    /// Servers of the app's that are slow to accept, that close a connection at once, or that never accept: the
    /// listening socket the kernel records still says they're the app's, so none is refused or stopped by mistake.
    @Test func aSlowOrQuickServerOfTheAppStaysServed() throws {
        let late = try ReachListener.port(accepting: .late(1.5))
        defer { late.stop() }
        let quick = try ReachListener.port(accepting: .closeAtOnce)
        defer { quick.stop() }
        let never = try ReachListener.port(accepting: .never)
        defer { never.stop() }
        let app = ToolReach.App(team: nil, processes: [try #require(PeerIdentity.instance(of: getpid()))])
        for _ in 0..<3 {
            let started = ContinuousClock.now
            let served = ToolReach.served([late.endpoint, quick.endpoint, never.endpoint], by: app, lookup: .system)
            #expect(served == [late.endpoint, quick.endpoint, never.endpoint])
            #expect(ContinuousClock.now - started < .seconds(2))
        }
        // Another app's check: not this process, so none of them is its.
        let other = ToolReach.App(team: nil, processes: [ToolReach.Instance(pid: 1, started: 0)])
        #expect(ToolReach.served([late.endpoint, quick.endpoint, never.endpoint], by: other, lookup: .system).isEmpty)
    }

    /// The grant's side, as rechecked when the grant changes: a socket in a granted folder needs no listener, one
    /// outside needs the app to serve it, a port always does; developer access isn't checked. The refusal names it.
    @Test func theGrantDecidesWhatAContainedSessionReaches() throws {
        let grant = Router.Grant(
            app: "Example", identifier: "com.example.app", team: "TEAM", verified: true, accounts: ["a"],
            tools: .workspace, folders: ["/private/tmp/granted/"])
        var policy = SessionPolicy.fallback(
            workspace: URL(filePath: "/private/tmp/granted", directoryHint: .isDirectory))
        policy.toolSockets = [URL(filePath: "/private/tmp/granted/in.sock"), URL(filePath: "/private/tmp/out.sock")]
        policy.toolPorts = [4100]
        #expect(ToolReach.unresolved(policy, grant: grant) == [.port(4100), .socket("/private/tmp/out.sock")])

        let socket = try #require(GrantScope.reach(policy, against: grant, sandbox: .contained))
        #expect(socket.field == "toolSockets" && socket.reason.contains("/private/tmp/out.sock"))
        #expect(
            socket.reason.contains("signed by its developer") && socket.reason.contains("developer access allows it"))
        policy.servedByApp = [.socket("/private/tmp/out.sock")]
        let port = try #require(GrantScope.reach(policy, against: grant, sandbox: .contained))
        #expect(port.field == "toolPorts" && port.reason.contains("port 4100"))
        policy.servedByApp.insert(.port(4100))
        #expect(GrantScope.reach(policy, against: grant, sandbox: .contained) == nil)
        #expect(
            GrantScope.reach(SessionPolicy.fallback(workspace: policy.workspace), against: grant, sandbox: .contained)
                == nil)

        // A grant whose folders no longer hold the socket no longer fits the running session.
        var narrowed = grant
        narrowed.folders = ["/private/tmp/elsewhere/"]
        #expect(GrantScope.reach(policy, against: narrowed, sandbox: .contained)?.field == "toolSockets")
        policy.servedByApp = []
        #expect(GrantScope.reach(policy, against: grant, sandbox: .developer) == nil)
    }

    /// The system lookup: a connection to this process's socket names it by audit token, one to its port finds it
    /// holding the far end; a missing socket, a stale socket file nobody listens on, and an unused port reach
    /// nothing. The scan finds both listeners (by real path: /tmp is /private/tmp), quickly enough for every command.
    @Test func theSystemLookupAsksTheKernel() throws {
        let port = try ReachListener.port()
        defer { port.stop() }
        let folder = URL(filePath: "/tmp/agneta-reach-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = try ReachListener.socket(at: folder.appending(path: "s.sock").path(percentEncoded: false))
        defer { socket.stop() }
        #expect(socket.path.hasPrefix("/private/tmp/"))

        guard case .peers(let unix) = PeerIdentity.answer(socket.endpoint), let peer = unix.first else {
            Issue.record("no peer for the socket")
            return
        }
        #expect(unix.map(\.pid) == [getpid()] && peer.token?.count == 8)
        #expect(PeerIdentity.current(peer) && PeerIdentity.of(peer: peer).path != nil)
        var stale = peer
        stale.token?[7] &+= 1
        #expect(!PeerIdentity.current(stale))
        #expect(PeerIdentity.answer(port.endpoint) == .peers([ToolReach.Peer(pid: getpid())]))
        #expect(
            PeerIdentity.answer(.socket(folder.appending(path: "none.sock").path(percentEncoded: false))) == .nothing)
        let left = try ReachListener.socket(at: folder.appending(path: "left.sock").path(percentEncoded: false))
        left.closeKeepingFile()
        defer { left.stop() }
        #expect(FileManager.default.fileExists(atPath: left.path) && PeerIdentity.answer(left.endpoint) == .nothing)
        let unused = try ReachListener.freePort()
        #expect(PeerIdentity.answer(.port(unused)) == .nothing)

        let started = ContinuousClock.now
        let found = PeerIdentity.listeners(on: [port.endpoint, socket.endpoint, .port(unused)])
        let took = ContinuousClock.now - started
        #expect(
            found[port.endpoint] == [getpid()] && found[socket.endpoint] == [getpid()] && found[.port(unused)] == nil)
        #expect(took < .seconds(2), "\(took)")
        #expect(PeerIdentity.parent(of: getpid()) == getppid())
        #expect(PeerIdentity.instance(of: getpid()) == PeerIdentity.instance(of: getpid()))
    }

    /// What the docs call measured: the sandbox matches the socket a path resolves to, and the profile names a socket
    /// as it was checked. A link put in a checked socket's place, after the check or before the profile is written,
    /// reaches nothing: neither the socket it points to nor the one it replaced.
    @Test func aLinkInASocketsPlaceReachesNothing() throws {
        let folder = URL(
            filePath: "/private/tmp/agneta-link-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let allowed = try ReachListener.socket(at: folder.appending(path: "app.sock").path(percentEncoded: false))
        defer { allowed.stop() }
        let other = try ReachListener.socket(at: folder.appending(path: "other.sock").path(percentEncoded: false))
        defer { other.stop() }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let policy = try SessionPolicy.parse(
            ["toolSockets": [.string(allowed.path)]], cwd: folder.path(percentEncoded: false),
            context: PolicyContext(
                userHome: home, agnetaRoots: [home.appending(path: "Library/Application Support/Agneta")]))
        let scratch = folder.appending(path: "scratch", directoryHint: .isDirectory)

        func connects(_ path: String, profile: String) throws -> Bool {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
            process.arguments = [
                "-p", profile, "/usr/bin/perl", "-MIO::Socket::UNIX", "-e",
                "exit(IO::Socket::UNIX->new(Peer => $ARGV[0]) ? 0 : 1)", path
            ]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        let before = policy.toolProfile(scratch: scratch).render()
        #expect(try connects(allowed.path, profile: before))
        #expect(try !connects(other.path, profile: before))

        allowed.closeKeepingFile()
        unlink(allowed.path)
        try FileManager.default.createSymbolicLink(atPath: allowed.path, withDestinationPath: other.path)
        let after = policy.toolProfile(scratch: scratch).render()
        #expect(after == before)
        #expect(try !connects(allowed.path, profile: before))
        #expect(try !connects(other.path, profile: after))
    }
}

extension ToolReach.Lookup {
    /// The same lookup, answering connections with `answer`.
    func with(answer: @escaping @Sendable (ToolReach.Endpoint) -> ToolReach.Answer) -> ToolReach.Lookup {
        var lookup = self
        lookup.answer = answer
        return lookup
    }
}
