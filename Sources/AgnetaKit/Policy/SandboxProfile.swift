// Seatbelt profiles for engines and their tool shells. macOS refuses to apply
// a second sandbox inside a restricted one (sandbox_apply: EPERM, measured),
// so the two profiles never nest: the engine runs under the engine profile,
// and shell commands are executed by Agneta under the stricter tool profile
// through the GOOSE_SHELL broker.
import Foundation

public struct SandboxProfile: Sendable {
    public enum Kind: Sendable { case engine, tool }

    public var kind: Kind
    /// Folders the process may write (workspace, writable extras, its own home and temp).
    public var writable: [URL]
    /// Folders whose contents may not be read, even when inside a readable folder.
    public var denied: [URL]
    /// Readable folders beyond `writable` and the system locations. Everything else is
    /// unreadable: other projects, other volumes, the user's home.
    public var readable: [URL]
    /// Loopback TCP ports the process may connect to (the app's MCP server, a local model).
    public var loopbackPorts: [Int]
    /// Remote TCP ports allowed (the engine needs 443 for providers; tools get none by default).
    public var remotePorts: [Int]
    /// Unix sockets the process may connect to (the engine reaches Agneta's tool broker).
    public var unixSockets: [URL] = []
    /// Readable but never writable, even inside a writable folder.
    public var readOnly: [URL] = []
    /// Any loopback TCP port: for shared engines whose sessions bring different app tool servers.
    public var allLoopback = false
    /// The engine runs a private server of its own on loopback (OpenCode's ACP bridge talks to one):
    /// it may listen on loopback and connect to itself there, and nothing else inbound.
    public var ownLoopbackServer = false
    /// Folders allowed back after `denied` (the last matching rule wins), e.g. a session's own part of a denied folder.
    public var exceptions: [URL] = []

    /// System locations every process needs: binaries, libraries, the toolchain, settings.
    public static let systemReadable = ["/bin", "/sbin", "/usr", "/System", "/Library/Apple", "/Library/Developer",
                                        "/Library/Frameworks", "/Library/Preferences", "/Applications/Xcode.app",
                                        "/private/etc", "/private/var/db", "/private/var/run", "/dev"].map { URL(filePath: $0, directoryHint: .isDirectory) }

    public init(kind: Kind, writable: [URL], denied: [URL], readable: [URL] = [], loopbackPorts: [Int] = [], remotePorts: [Int] = []) {
        self.kind = kind
        self.writable = writable
        self.denied = denied
        self.readable = readable
        self.loopbackPorts = loopbackPorts
        self.remotePorts = remotePorts
    }

    /// Paths checked when the session was authorized (already resolved, inside the grant, clear of protected places):
    /// written exactly as checked, never resolved again. Resolving here would let a folder swapped for a symlink
    /// since then widen the profile to wherever the link points, past every check. The sandbox matches real paths,
    /// so a path that has become a symlink grants nothing beyond its original folder.
    public var verbatim: Set<String> = []

    /// A path for a rule: verbatim when it was checked, else resolved (Agneta's own folders, system locations).
    func quote(_ url: URL) -> String {
        let given = url.path(percentEncoded: false).trimmingSuffix("/")
        let path = verbatim.contains(given) ? given : url.realFileURL.path(percentEncoded: false).trimmingSuffix("/")
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    public func render() -> String {
        let writableRules = writable.map { "(subpath \(quote($0)))" }
        // Reading a folder's contents needs it to be allowed; listing the way there needs its ancestors.
        let allowedReads = (writable + readable + readOnly + Self.systemReadable)
            .flatMap { ["(require-not (subpath \(quote($0))))", "(require-not (path-ancestors \(quote($0))))"] }
            .joined(separator: " ")
        // Programs run only from where reading is allowed: one in a folder it can't read (another project's tools,
        // the user's own scripts) stays out of reach too (measured: exec didn't need read access).
        let allowedExec = (writable + readable + readOnly + Self.systemReadable).map { "(require-not (subpath \(quote($0))))" }.joined(separator: " ")
        var rules = [
            "(version 1)",
            "(allow default)",
            // Writes only inside the allowed folders and the usual device files.
            "(deny file-write* (require-not (require-any \((writableRules + ["(literal \"/dev/null\")", "(literal \"/dev/tty\")", "(literal \"/dev/dtracehelper\")", "(regex #\"^/dev/fd/\")"]).joined(separator: " ")))))",
            // Reads are allow-listed: the session's folders and system locations only.
            "(deny file-read-data (require-all (require-not (literal \"/\")) \(allowedReads)))",
            "(deny process-exec* (require-all \(allowedExec)))",
            ]
        for folder in readOnly {
            rules.append("(deny file-write* (subpath \(quote(folder))))")
        }
        for folder in denied {
            rules.append("(deny file-read* file-write* (subpath \(quote(folder))))")
        }
        for folder in exceptions {
            rules.append("(allow file-read* file-write* (subpath \(quote(folder))))")
        }
        rules.append("(allow file-read-metadata)")
        // Network: deny, then allow only what the session needs.
        rules.append("(deny network-outbound (require-not (remote unix-socket (path-literal \"/private/var/run/mDNSResponder\"))))")
        if allLoopback { rules.append("(allow network-outbound (remote tcp \"localhost:*\"))") }
        for port in loopbackPorts { rules.append("(allow network-outbound (remote tcp \"localhost:\(port)\"))") }
        for port in remotePorts { rules.append("(allow network-outbound (remote tcp \"*:\(port)\"))") }
        for socket in unixSockets { rules.append("(allow network-outbound (remote unix-socket (path-literal \(quote(socket)))))") }
        if ownLoopbackServer {
            rules.append("(allow network-bind (local tcp \"localhost:*\"))")
            rules.append("(allow network-inbound (local tcp \"localhost:*\"))")
            if !allLoopback { rules.append("(allow network-outbound (remote tcp \"localhost:*\"))") }
            rules.append("(deny network-bind network-inbound (require-not (local tcp \"localhost:*\")))")
        } else {
            rules.append("(deny network-bind network-inbound)")
        }
        // Nothing inside can see or signal processes outside its sandbox, script other apps, or have
        // LaunchServices open something outside it (`open x.command` ran in Terminal). Tools never
        // reach the Keychain. Engines must: TLS certificate checks go through the Security service (measured:
        // Codex couldn't reach chatgpt.com without it).
        rules += [
            "(deny process-info* (require-not (target same-sandbox)))",
            "(deny signal (require-not (target same-sandbox)))",
            "(deny appleevent-send)",
            "(deny lsopen)",
            "(deny mach-lookup (global-name \"com.apple.coreservices.appleevents\") (global-name \"com.apple.coreservices.launchservicesd\"))",
        ]
        if kind == .tool {
            rules.append("(deny mach-lookup (global-name \"com.apple.securityd\") (global-name \"com.apple.SecurityServer\"))")
        }
        return rules.joined(separator: "\n") + "\n"
    }
}
