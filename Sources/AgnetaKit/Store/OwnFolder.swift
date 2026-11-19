// The folders Agneta makes for sessions (engine homes, scratch, build caches, an app's workspace) are writable to
// the sessions inside them, and a sandboxed process can replace a folder it may write with a symlink (measured:
// `rm -rf D && ln -s ~ D` works under a profile that allows writing D). Resolved when the next profile is written,
// that link would make wherever it points writable. So Agneta never resolves them: it makes each one a real folder
// at exactly its path (removing whatever was planted there, without following it) and writes that path into the
// profile verbatim. A link planted after that grants nothing, since the sandbox matches the real paths it reaches.
import Darwin
import Foundation

public enum OwnFolder {
    /// Makes `folder` a real directory at exactly its path: each component below `root` (the first one Agneta
    /// trusts, which no session can write) that is a symlink or a file is removed, never followed, and made again.
    /// Returns the path with `root` resolved and nothing below it resolved, for a profile's `verbatim`.
    @discardableResult
    public static func ensure(_ folder: URL, under root: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let base = root.path(percentEncoded: false).trimmingSuffix("/")
        let real = root.realFileURL.path(percentEncoded: false).trimmingSuffix("/")
        var path = folder.path(percentEncoded: false).trimmingSuffix("/")
        if path.hasPrefix(base + "/") { path = real + path.dropFirst(base.count) }
        guard path.hasPrefix(real + "/") else { throw ChildProcessError.spawnFailed(path: path, errno: EINVAL) }
        var current = real
        for component in path.dropFirst(real.count + 1).split(separator: "/") {
            current += "/" + component
            var info = stat()
            if lstat(current, &info) == 0 {
                if info.st_mode & S_IFMT == S_IFDIR { continue }
                // A link or a file where a folder belongs: removed itself, whatever it points to.
                guard unlink(current) == 0 else { throw ChildProcessError.spawnFailed(path: current, errno: errno) }
            } else if errno != ENOENT {
                throw ChildProcessError.spawnFailed(path: current, errno: errno)
            }
            guard mkdir(current, 0o700) == 0 || errno == EEXIST else {
                throw ChildProcessError.spawnFailed(path: current, errno: errno)
            }
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// `folder` with its parent resolved and its last component not: for comparing a folder that a session may
    /// have replaced with a link (a granted folder, an app's workspace) without following that link.
    public static func unfollowed(_ folder: URL) -> URL {
        let name = folder.lastPathComponent
        return folder.deletingLastPathComponent().realFileURL.appending(path: name, directoryHint: .isDirectory)
    }
}
