// A development build started with AGNETA_HOME runs as an isolated instance (tests, design review): its own data
// folder, Keychain service and ports, so nothing touches the user's own Agneta or another instance. Two instances
// must never share a Keychain service (Reset in one deletes every item under it) or a port.
import CryptoKit
import Foundation

public enum IsolatedInstance {
    /// The ports of the user's own Agneta (release and development builds, apps and diagnostics), never taken.
    public static let reservedPorts: Set<Int> = [47321, 47323, 47331, 47333]

    /// The instance's Keychain service: the build's, plus a digest of the instance's data folder.
    public static func keychainService(bundleID: String, home: URL) -> String {
        let path = home.standardizedFileURL.path(percentEncoded: false)
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(bundleID).isolated.\(digest)"
    }

    /// The apps' port from AGNETA_PORT. Required, since a default would put every instance on one port; the
    /// diagnostics port two above it must fit too, and neither may be one of the user's own Agneta's.
    public static func port(_ raw: String?) throws -> UInt16 {
        guard let raw, !raw.isEmpty else {
            throw Problem("Set AGNETA_PORT for an isolated instance (AGNETA_HOME is set)")
        }
        guard let port = Int(raw), (1024...65533).contains(port) else {
            throw Problem(
                "AGNETA_PORT must be a number from 1024 to 65533 (diagnostics listen two above it), not \(raw)")
        }
        if let taken = [port, port + 2].first(where: reservedPorts.contains) {
            throw Problem("AGNETA_PORT \(port) would use port \(taken), which your own Agneta uses")
        }
        return UInt16(port)
    }

    public struct Problem: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }
}
