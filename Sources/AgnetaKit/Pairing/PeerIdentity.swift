// Who is on the other end of a loopback connection? At pairing time Agneta
// finds the process that owns the client's TCP port and reads its code
// signature, so the approval window can say "Verified: Example App, signed by its
// developer" instead of trusting a name the app sent. This identifies the
// peer at that moment; afterwards the pairing token is the credential.
import Darwin
import Foundation
import Security

public struct PeerIdentity: Sendable, Equatable {
    public var pid: pid_t
    public var path: String?
    /// The signing identifier, e.g. com.example.app.
    public var identifier: String?
    /// The Apple team ID, nil for ad hoc or unsigned code.
    public var team: String?
    /// True when the running code's signature is valid.
    public var valid: Bool
    /// Signed with an Apple-issued certificate (Developer ID, App Store) and a team: who it claims to be is
    /// checkable. Ad hoc and self-signed code is valid but not trusted (anyone can sign ad hoc
    /// with any app's identifier).
    public var trusted: Bool = false

    /// Finds the local process holding the established TCP connection from `port` to Agneta's `serverPort`
    /// (both ends must match: the local port alone could pick an unrelated socket).
    public static func owner(ofLoopbackPort port: Int, serverPort: Int, excluding: pid_t = getpid()) -> pid_t? {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 && pid != excluding {
            if owns(pid: pid, port: port, serverPort: serverPort) { return pid }
        }
        // The test process connects to itself; accept it when nothing else matches.
        return owns(pid: excluding, port: port, serverPort: serverPort) ? excluding : nil
    }

    static func owns(pid: pid_t, port: Int, serverPort: Int) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard used > 0 else { return false }
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let got = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard got == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let local = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            let foreign = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_fport)))
            if local == port, foreign == serverPort, tcp.tcpsi_state == TSI_S_ESTABLISHED { return true }
        }
        return false
    }

    /// Reads the code signature of a running process.
    public static func of(pid: pid_t) -> PeerIdentity {
        var identity = PeerIdentity(pid: pid, path: nil, identifier: nil, team: nil, valid: false)
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        if length > 0 { identity.path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return identity }
        identity.valid = SecCodeCheckValidity(code, [], nil) == errSecSuccess
        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess, let requirement {
            identity.trusted = SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return identity }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let fields = info as? [String: Any] else { return identity }
        identity.identifier = fields[kSecCodeInfoIdentifier as String] as? String
        identity.team = fields[kSecCodeInfoTeamIdentifier as String] as? String
        identity.trusted = identity.trusted && identity.team != nil
        return identity
    }

    /// The identity of whoever owns `port`, if it can be found.
    public static func forLoopbackPort(_ port: Int, serverPort: Int) -> PeerIdentity? {
        owner(ofLoopbackPort: port, serverPort: serverPort).map(of(pid:))
    }
}
