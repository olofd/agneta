import Darwin
import Foundation
import Testing
@testable import AgnetaKit

@Suite struct PeerIdentityTests {
    @Test func findsTheProcessBehindALoopbackPort() throws {
        // A child process listens; this process connects, then asks who owns the client end.
        let server = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(server) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                                  sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard bind(server, $0, size) == 0, listen(server, 1) == 0, getsockname(server, $0, &size) == 0 else { throw POSIXError(.EADDRINUSE) }
            }
        }
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, size) } }
        #expect(connected == 0)
        var local = sockaddr_in()
        var localSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(client, $0, &localSize) } }
        let clientPort = Int(UInt16(bigEndian: local.sin_port))

        let serverPort = Int(UInt16(bigEndian: address.sin_port))
        #expect(PeerIdentity.owners(ofLoopbackPort: clientPort, serverPort: serverPort) == [getpid()])
        // Both ends must match: the same client port towards another server isn't this connection.
        #expect(PeerIdentity.owners(ofLoopbackPort: clientPort, serverPort: serverPort == 1 ? 2 : 1).isEmpty)
        let identity = PeerIdentity.of(pid: getpid())
        #expect(identity.path?.isEmpty == false)
        // The test runner is signed ad hoc: valid, but nothing proves who made it.
        #expect(!identity.trusted)
    }

    @Test func readsASystemBinarysSignature() throws {
        let child = try ChildProcess(executable: "/bin/sleep", arguments: ["5"], environment: [:])
        let identity = PeerIdentity.of(pid: child.pid)
        #expect(identity.identifier == "com.apple.sleep")
        #expect(identity.valid)
        Task { await child.stop(grace: .milliseconds(10)) }
    }
}
