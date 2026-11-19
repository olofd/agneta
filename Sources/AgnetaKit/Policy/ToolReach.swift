// What a contained task's shell commands may connect to on this Mac. A policy's `toolSockets` and `toolPorts` open
// the tool profile to a Unix socket or a loopback port, and a connection is a network rule, which no folder check
// sees: Docker's socket, or any local service's port, would take a contained task out of its folders with nothing
// shown to the user. So under Contained a socket is allowed only inside a folder the app was granted (which the
// approval window showed), or when the app serves it itself; a port only when the app serves it itself.
//
// Who serves an endpoint is the kernel's answer, never a process's own account: Agneta connects to it as a command
// would and asks who it reached. A socket's listener comes with its audit token (LOCAL_PEERTOKEN); a port's is the
// process holding the other end of that very connection. The path a process bound with is a string it chose and can
// make point elsewhere afterwards (by changing folder, or swapping a folder for a link: measured), and a server run by
// root or another user can't be seen in any process list, so the process scan only ever narrows: everything it finds
// bound there must be the app too. Nothing answering, or an answer that can't be identified, is not the app.
//
// "The app itself": for a verified grant, any process with an Apple-anchored signature from the grant's team (its
// helpers, its XPC services, and the team's other apps); for an unverified one, the process holding the app's
// connection to Agneta, or one it started. Processes are compared as instances (a pid and its start time, or the
// audit token), so a reused pid is never taken for the app.
//
// Checked when a session opens, is loaded or forked, and again before each command the broker runs: a server that
// went away and was replaced by another program's stops the session. Between two commands, a command already running
// keeps what it connected to (docs/APP_PROTOCOL.md, Tool ports and sockets). Developer access reaches every local
// server, as a terminal does, and isn't checked.
import Darwin
import Foundation
import Security

public enum ToolReach {
    /// Something a shell command connects to: a loopback TCP port, or a Unix socket by its real path.
    public enum Endpoint: Hashable, Sendable, CustomStringConvertible {
        case port(Int)
        case socket(String)

        public var description: String {
            switch self {
            case .port(let port): "loopback port \(port)"
            case .socket(let path): path
            }
        }
    }

    /// One running process: a pid is reused, a pid with its start time isn't.
    public struct Instance: Hashable, Sendable {
        public var pid: pid_t
        /// Microseconds since 1970.
        public var started: UInt64
        public init(pid: pid_t, started: UInt64) { (self.pid, self.started) = (pid, started) }
    }

    /// A process a connection reached, with the kernel's audit token for it when there is one (a Unix socket's
    /// listener): the token names that process, never a later one given its pid.
    public struct Peer: Hashable, Sendable {
        public var pid: pid_t
        public var token: [UInt32]?
        public init(pid: pid_t, token: [UInt32]? = nil) { (self.pid, self.token) = (pid, token) }
    }

    /// Who a connection to an endpoint reached.
    public enum Answer: Hashable, Sendable {
        /// Nothing accepted it: nothing listens there.
        case nothing
        /// Something did, but who couldn't be read (a process of root's or another user's, one that didn't accept in
        /// time, or a kind of socket that names no peer).
        case unidentified
        case peers(Set<Peer>)
    }

    /// Who counts as the app: its verified team, or (unverified) the processes holding its connection to Agneta.
    public struct App: Sendable, Equatable {
        public var team: String?
        public var processes: [Instance]
        public init(team: String?, processes: [Instance]) { (self.team, self.processes) = (team, processes) }
    }

    /// What a contained session reaches beyond its folders, held to its app again before each command: the
    /// endpoints the app served when the session opened.
    public struct Check: Sendable, Equatable {
        public var app: App
        /// The app's name, for the refusal.
        public var name: String
        public var endpoints: [Endpoint]
    }

    /// How endpoints and processes are found and identified: the system's, or a test's.
    public struct Lookup: Sendable {
        /// The processes holding the app's connection to Agneta: its client port, and Agneta's port.
        public var connection: @Sendable (_ client: Int, _ server: Int) -> [pid_t]
        /// Connects to the endpoint as a command would, and says whom the kernel connected it to.
        public var answer: @Sendable (Endpoint) -> Answer
        /// Every process the scan finds bound to each endpoint: never evidence for the app, only against it.
        public var listeners: @Sendable (Set<Endpoint>) -> [Endpoint: [pid_t]]
        /// A peer's code signature, read through its audit token when it has one.
        public var identity: @Sendable (Peer) -> PeerIdentity
        /// Whether a peer's audit token still names the process with its pid (true without a token).
        public var current: @Sendable (Peer) -> Bool
        public var instance: @Sendable (pid_t) -> Instance?
        /// A process's parent, or nil when it can't be read.
        public var parent: @Sendable (pid_t) -> pid_t?

        public init(
            connection: @escaping @Sendable (Int, Int) -> [pid_t], answer: @escaping @Sendable (Endpoint) -> Answer,
            listeners: @escaping @Sendable (Set<Endpoint>) -> [Endpoint: [pid_t]],
            identity: @escaping @Sendable (Peer) -> PeerIdentity, current: @escaping @Sendable (Peer) -> Bool,
            instance: @escaping @Sendable (pid_t) -> Instance?, parent: @escaping @Sendable (pid_t) -> pid_t?
        ) {
            self.connection = connection
            self.answer = answer
            self.listeners = listeners
            self.identity = identity
            self.current = current
            self.instance = instance
            self.parent = parent
        }

        public static let system = Lookup(
            connection: { PeerIdentity.owners(ofLoopbackPort: $0, serverPort: $1) }, answer: PeerIdentity.answer(_:),
            listeners: PeerIdentity.listeners(on:), identity: PeerIdentity.of(peer:), current: PeerIdentity.current(_:),
            instance: PeerIdentity.instance(of:), parent: PeerIdentity.parent(of:))
    }

    /// How far up the parents a process is followed to find the app: deep enough for any launcher chain, and bounded.
    static let ancestry = 64

    /// The endpoints of a contained policy that its granted folders don't cover, which only the app serving them can
    /// allow: every port, and each socket outside the grant's folders.
    public static func unresolved(_ policy: SessionPolicy, grant: Router.Grant) -> [Endpoint] {
        policy.toolPorts.map(Endpoint.port)
            + policy.toolSockets.filter { !GrantScope.inGrantedFolder($0, grant) }.map {
                .socket($0.path(percentEncoded: false))
            }
    }

    /// Of `endpoints`, those the app serves itself: a connection there reached the app, as the kernel says, and every
    /// process the scan finds bound there is the app too.
    public static func served(_ endpoints: [Endpoint], by app: App, lookup: Lookup) -> Set<Endpoint> {
        guard !endpoints.isEmpty else { return [] }
        let holders = lookup.listeners(Set(endpoints))
        var known: [Peer: Bool] = [:]
        func isApp(_ peer: Peer) -> Bool {
            if let answer = known[peer] { return answer }
            let answer = Self.isApp(peer, app, lookup)
            known[peer] = answer
            return answer
        }
        return Set(
            endpoints.filter { endpoint in
                guard case .peers(let peers) = lookup.answer(endpoint), !peers.isEmpty else { return false }
                return peers.allSatisfy(isApp) && (holders[endpoint] ?? []).allSatisfy { isApp(Peer(pid: $0)) }
            })
    }

    /// The first of a check's endpoints its app no longer serves, or nil while it serves them all.
    public static func lost(_ check: Check, lookup: Lookup) -> Endpoint? {
        let served = served(check.endpoints, by: check.app, lookup: lookup)
        return check.endpoints.first { !served.contains($0) }
    }

    /// Whether `peer` is the app, as one process instance throughout: its pid read the same before and after, and its
    /// audit token, when it has one, naming that process.
    static func isApp(_ peer: Peer, _ app: App, _ lookup: Lookup) -> Bool {
        guard let before = lookup.instance(peer.pid), lookup.current(peer) else { return false }
        let answer: Bool
        if let team = app.team {
            let identity = lookup.identity(peer)
            answer = identity.trusted && identity.team == team
        } else {
            answer = descends(peer.pid, from: Set(app.processes), lookup: lookup)
        }
        return answer && lookup.instance(peer.pid) == before
    }

    /// Whether `pid` is one of `roots` or was started by one of them, following parents at most `ancestry` steps.
    /// A parent that exits hands its children to launchd, so a pid reached this way was really the parent.
    static func descends(_ pid: pid_t, from roots: Set<Instance>, lookup: Lookup) -> Bool {
        guard !roots.isEmpty else { return false }
        var current = pid
        for _ in 0..<ancestry {
            guard let instance = lookup.instance(current) else { return false }
            if roots.contains(instance) { return true }
            // launchd (1) and the kernel (0) start everything: reaching them means it wasn't the app's.
            guard let up = lookup.parent(current), up > 1, up != current else { return false }
            current = up
        }
        return false
    }
}

extension PeerIdentity {
    /// Whom a connection to `endpoint` reaches. A socket: its listener, by the kernel's audit token for the connection.
    /// A port: the processes holding the far end of a connection to 127.0.0.1 and to ::1 (each address may have a
    /// listener of its own), found by the connection's own ports once one accepts it.
    public static func answer(_ endpoint: ToolReach.Endpoint) -> ToolReach.Answer {
        switch endpoint {
        case .socket(let path): return unixPeer(path)
        case .port(let port):
            let answers = [AF_INET, AF_INET6].map { tcpPeers(port: port, family: $0) }
            if answers.contains(.unidentified) { return .unidentified }
            let peers = answers.reduce(into: Set<ToolReach.Peer>()) {
                if case .peers(let found) = $1 { $0.formUnion(found) }
            }
            return peers.isEmpty ? .nothing : .peers(peers)
        }
    }

    /// How long a port's server has to accept Agneta's connection, and the wait between looks.
    static let acceptWithin: Duration = .seconds(1)

    static func unixPeer(_ path: String) -> ToolReach.Answer {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return .unidentified }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in path.utf8.enumerated() { raw[index] = byte }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unidentified }
        defer { close(fd) }
        prepare(fd)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return [ECONNREFUSED, ENOENT].contains(errno) ? .nothing : .unidentified }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return .unidentified }
        let values = withUnsafeBytes(of: token) { Array($0.bindMemory(to: UInt32.self)) }
        // The token's fields are documented by libbsm: audit_token_to_pid reads the sixth.
        return .peers([ToolReach.Peer(pid: pid_t(bitPattern: token.val.5), token: values)])
    }

    static func tcpPeers(port: Int, family: Int32) -> ToolReach.Answer {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unidentified }
        defer { close(fd) }
        prepare(fd)
        var status: Int32
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = in_addr_t(UInt32(0x7f00_0001).bigEndian)
            status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        } else {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(port).bigEndian)
            address.sin6_addr = in6addr_loopback
            status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        let unreachable = [ECONNREFUSED, EADDRNOTAVAIL, ENETUNREACH, EAFNOSUPPORT]
        if status != 0 {
            guard errno == EINPROGRESS else { return unreachable.contains(errno) ? .nothing : .unidentified }
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&poller, 1, Int32(acceptWithin.components.seconds * 1000)) == 1 else { return .unidentified }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else { return .unidentified }
            if error != 0 { return unreachable.contains(error) ? .nothing : .unidentified }
        }
        var local = sockaddr_storage()
        var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard named == 0 else { return .unidentified }
        let client = withUnsafeBytes(of: local) { raw -> Int in
            // sin_port and sin6_port sit at the same offset, in network order.
            Int(UInt16(bigEndian: raw.load(fromByteOffset: 2, as: UInt16.self)))
        }
        // Until the server accepts, the connection is in its listening socket's queue, held by no process.
        let deadline = ContinuousClock.now + acceptWithin
        repeat {
            let pids = allPids().filter { owns(pid: $0, port: port, serverPort: client) }
            if !pids.isEmpty { return .peers(Set(pids.map { ToolReach.Peer(pid: $0) })) }
            usleep(10_000)
        } while ContinuousClock.now < deadline
        return .unidentified
    }

    /// A probe connection: never blocking Agneta, never a SIGPIPE.
    private static func prepare(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    static func allPids() -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(count, 0))).filter { $0 > 0 }
    }

    /// Every process (of those Agneta may inspect: the user's own) with a socket bound to one of `endpoints`: a TCP
    /// socket listening on the port, whatever its local address, or a Unix socket whose recorded path, resolved now,
    /// is the socket's, or is relative with the same name. Only ever a further condition (each one must be the app
    /// too): the recorded path is the binder's own string.
    public static func listeners(on endpoints: Set<ToolReach.Endpoint>) -> [ToolReach.Endpoint: [pid_t]] {
        var ports = Set<Int>(), sockets = Set<String>()
        for endpoint in endpoints {
            switch endpoint {
            case .port(let port): ports.insert(port)
            case .socket(let path): sockets.insert(path)
            }
        }
        guard !endpoints.isEmpty else { return [:] }
        let names = Set(sockets.map { ($0 as NSString).lastPathComponent })
        var found: [ToolReach.Endpoint: [pid_t]] = [:]
        for pid in allPids() {
            for endpoint in bound(pid: pid, ports: ports, sockets: sockets, names: names) {
                found[endpoint, default: []].append(pid)
            }
        }
        return found
    }

    /// The endpoints among `ports` and `sockets` that `pid` has a socket bound to.
    static func bound(pid: pid_t, ports: Set<Int>, sockets: Set<String>, names: Set<String>) -> Set<ToolReach.Endpoint>
    {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard used > 0 else { return [] }
        var hits = Set<ToolReach.Endpoint>()
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let got = proc_pidfdinfo(
                pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard got == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }
            if info.psi.soi_kind == Int32(SOCKINFO_TCP), !ports.isEmpty {
                let tcp = info.psi.soi_proto.pri_tcp
                let local = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
                if tcp.tcpsi_state == TSI_S_LISTEN, ports.contains(local) { hits.insert(.port(local)) }
            } else if info.psi.soi_kind == Int32(SOCKINFO_UN), !sockets.isEmpty {
                // The socket's own address: what it was bound to (an accepted connection carries its listener's).
                var address = info.psi.soi_proto.pri_un.unsi_addr.ua_sun
                let path = withUnsafeBytes(of: &address.sun_path) { raw in
                    String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                let name = (path as NSString).lastPathComponent
                guard !path.isEmpty, names.contains(name) else { continue }
                if path.hasPrefix("/") {
                    let real = URL(filePath: path).realFileURL.path(percentEncoded: false)
                    if sockets.contains(real) { hits.insert(.socket(real)) }
                } else {
                    // Relative to a folder it may have left since: counted against every socket of that name.
                    for socket in sockets where (socket as NSString).lastPathComponent == name {
                        hits.insert(.socket(socket))
                    }
                }
            }
        }
        return hits
    }

    /// The identity of a peer: through its audit token when it has one, which can't name a later process.
    public static func of(peer: ToolReach.Peer) -> PeerIdentity {
        guard let token = peer.token else { return of(pid: peer.pid) }
        return of(pid: peer.pid, attributes: [kSecGuestAttributeAudit: auditData(token)])
    }

    /// Whether a peer's audit token still names a running process (always, without a token). Security refuses a
    /// token whose pid version is stale (measured: errSecCSNoSuchCode).
    public static func current(_ peer: ToolReach.Peer) -> Bool {
        guard let token = peer.token else { return true }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: auditData(token)] as CFDictionary
        return SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess
    }

    static func auditData(_ token: [UInt32]) -> Data { token.withUnsafeBytes { Data($0) } }

    /// A running process as one instance, or nil when it can't be read.
    public static func instance(of pid: pid_t) -> ToolReach.Instance? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ToolReach.Instance(pid: pid, started: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }

    /// A process's parent, or nil when it can't be read.
    public static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
