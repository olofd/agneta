// Reset Agneta. A marker file beside the data root says a reset is
// under way, so an interrupted reset resumes at the next launch before anything
// else starts. The marker is removed last; a step that fails leaves it in place
// and is named, so the app can offer Try Again instead of showing a healthy
// state over leftovers. Stopping engines and clearing preferences and the login
// item are the app's part, done before `wipe()`.
import Foundation

public struct Reset: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case keychain(Int32)
        case folder(String)

        public var description: String {
            switch self {
            case .keychain(let status): "Agneta couldn't remove its Keychain items (error \(status))."
            case .folder(let path): "Agneta couldn't delete \(path)."
            }
        }
    }

    /// Agneta's Application Support root.
    public let root: URL
    /// Every folder the reset deletes, the root included (caches, logs).
    public let folders: [URL]
    public let keychain: Keychain

    public init(root: URL, folders: [URL], keychain: Keychain) {
        self.root = root
        self.folders = folders
        self.keychain = keychain
    }

    /// Beside the root, not inside it, so deleting the root doesn't remove it.
    public var marker: URL { root.deletingLastPathComponent().appending(path: "\(root.lastPathComponent).resetting") }

    public var isInterrupted: Bool { FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) }

    public func begin() throws {
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("reset\n".utf8).write(to: marker)
    }

    /// Deletes Agneta's Keychain items and folders. Safe to repeat.
    public func wipe() throws(Failure) {
        let status = keychain.deleteAll()
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .keychain(status) }
        for folder in folders where FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            do { try FileManager.default.removeItem(at: folder) } catch {
                throw .folder(folder.path(percentEncoded: false))
            }
        }
    }

    public func finish() { try? FileManager.default.removeItem(at: marker) }
}
