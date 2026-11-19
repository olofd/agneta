// What a contained task's shell commands may connect to on this Mac. A policy's `toolSockets` and `toolPorts` open
// the tool profile to a Unix socket or a loopback port, and a connection is a network rule, which no folder check
// sees: Docker's socket, or any local service's port, would take a contained task out of its folders with nothing
// shown to the user. So under Contained a socket is allowed only inside a folder the app was granted (which the
// approval window showed), or when the app serves it itself; a port only when the app serves it itself.
//
// "The app itself" is decided from who is bound to the endpoint when the session opens: every process listening on
// the port, or bound to the socket's path, must be the app. For a verified grant that is any process with an
// Apple-anchored signature from the grant's team (its helpers and XPC services); for an unverified one, the process
// holding the app's connection to Agneta, or one it started. A service that stops, and another program that takes
// its port during the session, isn't seen (a known limit, docs/APP_PROTOCOL.md). Developer access reaches every local
// server, as a terminal does, and isn't checked.
import Darwin
import Foundation

public enum ToolReach {
    /// Something a shell command connects to: a loopback TCP port, or a Unix socket by its real path.
    public enum Endpoint: Hashable, Sendable, CustomStringConvertible {
        case port(Int)
        case socket(String)

        public var description: String {
            switch self {
            case .port(let port): "port \(port)"
            case .socket(let path): path
            }
        }
    }

    /// Who counts as the app: its verified team, or (unverified) the processes holding its connection to Agneta.
    public struct App: Sendable, Equatable {
        public var team: String?
        public var pids: [pid_t]
        public init(team: String?, pids: [pid_t]) { (self.team, self.pids) = (team, pids) }
    }

    /// How processes are found and identified: the system's, or a test's. Each runs once per session open, and only
    /// when a contained policy names an endpoint its folders don't cover.
    public struct Lookup: Sendable {
        /// The processes holding the app's connection to Agneta: its client port, and Agneta's port.
        public var connection: @Sendable (_ client: Int, _ server: Int) -> [pid_t]
        /// Every process bound to each endpoint, in one pass over the processes.
        public var listeners: @Sendable (Set<Endpoint>) -> [Endpoint: [pid_t]]
        public var identity: @Sendable (pid_t) -> PeerIdentity
        /// A process's parent, or nil when it can't be read.
        public var parent: @Sendable (pid_t) -> pid_t?

        public init(
            connection: @escaping @Sendable (Int, Int) -> [pid_t],
            listeners: @escaping @Sendable (Set<Endpoint>) -> [Endpoint: [pid_t]],
            identity: @escaping @Sendable (pid_t) -> PeerIdentity, parent: @escaping @Sendable (pid_t) -> pid_t?
        ) {
            (self.connection, self.listeners, self.identity, self.parent) = (connection, listeners, identity, parent)
        }

        public static let system = Lookup(
            connection: { PeerIdentity.owners(ofLoopbackPort: $0, serverPort: $1) },
            listeners: PeerIdentity.listeners(on:), identity: PeerIdentity.of(pid:), parent: PeerIdentity.parent(of:))
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

    /// Of `endpoints`, those the app serves itself: something is bound there, and every process bound there is the app.
    public static func served(_ endpoints: [Endpoint], by app: App, lookup: Lookup) -> Set<Endpoint> {
        guard !endpoints.isEmpty else { return [] }
        let holders = lookup.listeners(Set(endpoints))
        var known: [pid_t: Bool] = [:]
        func isApp(_ pid: pid_t) -> Bool {
            if let answer = known[pid] { return answer }
            let answer: Bool
            if let team = app.team {
                let identity = lookup.identity(pid)
                answer = identity.trusted && identity.team == team
            } else {
                answer = descends(pid, from: Set(app.pids), parent: lookup.parent)
            }
            known[pid] = answer
            return answer
        }
        return Set(
            endpoints.filter { endpoint in
                let pids = holders[endpoint] ?? []
                return !pids.isEmpty && pids.allSatisfy(isApp)
            })
    }

    /// Whether `pid` is one of `roots` or was started by one of them, following parents at most `ancestry` steps.
    static func descends(_ pid: pid_t, from roots: Set<pid_t>, parent: (pid_t) -> pid_t?) -> Bool {
        guard !roots.isEmpty else { return false }
        var current = pid
        for _ in 0..<ancestry {
            if roots.contains(current) { return true }
            // launchd (1) and the kernel (0) start everything: reaching them means it wasn't the app's.
            guard let up = parent(current), up > 1, up != current else { return false }
            current = up
        }
        return false
    }
}

extension PeerIdentity {
    /// Every process (of those Agneta may inspect: the user's own) with a socket bound to one of `endpoints`: a TCP
    /// socket listening on the port, whatever its local address, or a Unix socket bound to the path, compared as real
    /// paths (a relative one against the process's working folder, or by its name when that can't be read, so an
    /// unreadable one counts against the app rather than for it). One pass over the processes; no process can hide a
    /// listener from it but one Agneta can't inspect, which then counts as nothing listening.
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
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var found: [ToolReach.Endpoint: [pid_t]] = [:]
        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
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
        var cwd: String??
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
                guard !path.isEmpty, names.contains((path as NSString).lastPathComponent) else { continue }
                if path.hasPrefix("/") {
                    let real = URL(filePath: path).realFileURL.path(percentEncoded: false)
                    if sockets.contains(real) { hits.insert(.socket(real)) }
                    continue
                }
                if cwd == nil { cwd = workingFolder(of: pid) }
                if let folder = cwd ?? nil {
                    let real = URL(filePath: folder, directoryHint: .isDirectory).appending(path: path).realFileURL
                        .path(percentEncoded: false)
                    if sockets.contains(real) { hits.insert(.socket(real)) }
                } else {
                    for socket in sockets where (socket as NSString).lastPathComponent == path {
                        hits.insert(.socket(socket))
                    }
                }
            }
        }
        return hits
    }

    /// A process's current working folder, or nil when it can't be read.
    static func workingFolder(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// A process's parent, or nil when it can't be read.
    public static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
