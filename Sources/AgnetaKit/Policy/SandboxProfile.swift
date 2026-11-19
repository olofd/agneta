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
    /// Developer access's outer layer (DeveloperAccess.widen): what it keeps out of the home folder it opens, and the
    /// process's own folders allowed back inside that. Rendered before `denied` and `exceptions`, so a folder the policy
    /// or the engine denies stays denied even inside a folder allowed back here (the last matching rule wins).
    public var outerDenied: [URL] = []
    public var outerExceptions: [URL] = []
    /// Paths denied like `outerDenied`, by regular expression (sandbox syntax): a family of folders, such as every build's
    /// copy of Agneta's data, including ones made after the profile was written.
    public var deniedPatterns: [String] = []
    /// Folders allowed back after `denied` (the last matching rule wins), e.g. a session's own part of a denied folder.
    public var exceptions: [URL] = []
    /// Folders allowed back for reading only, in the outer layer: a program or sign-in inside a folder developer access keeps out.
    public var readExceptions: [URL] = []
    /// Any TCP host and port (developer access), beyond `remotePorts`.
    public var anyRemote = false
    /// Developer access: commands may use the Security service too, which TLS certificate checks need.
    public var developer = false

    /// System locations every process needs: binaries, libraries, the toolchain, settings.
    public static let systemReadable = ["/bin", "/sbin", "/usr", "/System", "/Library/Apple", "/Library/Developer",
                                        "/Library/Frameworks", "/Library/Preferences", "/Applications/Xcode.app",
                                        "/private/etc", "/private/var/db", "/private/var/run", "/dev"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        + selectedXcode

    /// The selected Xcode's own tools (`git`, `python3`, `make`; `clang`, `cc`, `ld`, `swift`), ahead of `/usr/bin`'s
    /// shims, which go through xcrun and its cache outside the sandbox's folders, and the SDK they build against:
    /// commands get these on PATH and as SDKROOT, so `cc` and `git` run without xcrun (as apps that run Codex do).
    public static let xcodeTools: [String] = {
        guard let developer = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") else { return [] }
        return [developer + "/usr/bin", developer + "/Toolchains/XcodeDefault.xctoolchain/usr/bin"]
            .filter { FileManager.default.fileExists(atPath: $0) }
    }()
    public static let sdkRoot: String? = {
        guard let developer = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") else { return nil }
        let sdk = developer + "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
        return FileManager.default.fileExists(atPath: sdk) ? sdk : nil
    }()

    /// The Xcode `xcode-select` points to, wherever it's installed (`/Applications/Xcode-26.6.0.app`): the system's
    /// `python3`, `cc` and `git` are shims that load it (measured: python3 failed when only Xcode.app was readable).
    static let selectedXcode: [URL] = {
        guard let developer = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") else { return [] }
        var url = URL(filePath: developer, directoryHint: .isDirectory)
        while url.path(percentEncoded: false) != "/", url.pathExtension != "app" { url = url.deletingLastPathComponent() }
        return url.pathExtension == "app" ? [url] : []
    }()

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
    /// Agneta's own roots (its data, the app workspaces, its temp folder), which no session can write: a path under one
    /// is written with the root resolved and the rest literally, never through a link a session planted below it.
    public var literalRoots: [URL] = []

    /// A path for a rule: verbatim when it was checked, else resolved (Agneta's own folders, system locations).
    func quote(_ url: URL) -> String {
        let given = url.path(percentEncoded: false).trimmingSuffix("/")
        var literal = verbatim.contains(given) ? given : nil
        if literal == nil {
            for root in literalRoots {
                let real = root.realFileURL.path(percentEncoded: false).trimmingSuffix("/")
                for base in [root.path(percentEncoded: false).trimmingSuffix("/"), real] where given.hasPrefix(base + "/") {
                    literal = real + given.dropFirst(base.count)
                    break
                }
                if literal != nil { break }
            }
        }
        let path = literal ?? url.realFileURL.path(percentEncoded: false).trimmingSuffix("/")
        return Self.quoted(path)
    }

    static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A denial's paths: as written, and resolved too when that differs, so it holds whichever way the path is reached.
    func denialPaths(_ url: URL) -> [String] {
        let written = quote(url), resolved = Self.quoted(url.realFileURL.path(percentEncoded: false).trimmingSuffix("/"))
        return written == resolved ? [written] : [written, resolved]
    }

    /// Folders a session may write inside but not rename, remove or replace: each writable folder, and each folder
    /// between one and a denied or read-only path inside it. Measured: without this, `mv W elsewhere` carries a denied
    /// file out of its rule (and back), and a folder can be swapped for a link; creating, removing and renaming what's
    /// inside still works with it, and so do the folder's own times and attributes (only its unlink and create are
    /// refused). A folder that doesn't exist yet isn't pinned: it holds nothing yet, a session may make it, and a link
    /// made in its place grants nothing, since the profile names it as it is.
    func pinnedFolders() -> [String] {
        func unquoted(_ text: String) -> String { String(text.dropFirst().dropLast()) }
        let roots = (writable + outerExceptions + exceptions).map { unquoted(quote($0)) }
        var pinned = Set(roots)
        for protected in (denied + readOnly).map({ unquoted(quote($0)) }) {
            for root in roots where protected.hasPrefix(root + "/") {
                var folder = (protected as NSString).deletingLastPathComponent
                while folder.count > root.count {
                    pinned.insert(folder)
                    folder = (folder as NSString).deletingLastPathComponent
                }
            }
        }
        return pinned.filter { FileManager.default.fileExists(atPath: $0) }.sorted().map(Self.quoted)
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
        // Developer access's outer layer first, then the policy's and the engine's own denials and exceptions.
        for folder in outerDenied {
            rules.append("(deny file-read* file-write* (subpath \(quote(folder))))")
        }
        for pattern in deniedPatterns {
            rules.append("(deny file-read* file-write* (regex #\"\(pattern)\"))")
        }
        for folder in outerExceptions {
            rules.append("(allow file-read* file-write* (subpath \(quote(folder))))")
        }
        for folder in readExceptions {
            rules.append("(allow file-read* (subpath \(quote(folder))))")
        }
        for folder in denied {
            for path in denialPaths(folder) { rules.append("(deny file-read* file-write* (subpath \(path)))") }
        }
        for folder in exceptions {
            rules.append("(allow file-read* file-write* (subpath \(quote(folder))))")
        }
        // Last, so no exception (a session's folder allowed back inside a denied one) makes these writable again.
        for folder in readOnly {
            for path in denialPaths(folder) { rules.append("(deny file-write* (subpath \(path)))") }
        }
        for folder in pinnedFolders() { rules.append("(deny file-write-unlink file-write-create (literal \(folder)))") }
        rules.append("(allow file-read-metadata)")
        // Network: deny, then allow only what the session needs.
        // Name lookups go through mDNSResponder. Engines need them for their provider, and developer access for the
        // internet; a contained command doesn't, and a lookup of `<data>.example.com` would carry data out, so its
        // commands reach no resolver (loopback addresses are literals).
        if kind == .tool && !developer {
            rules.append("(deny network-outbound)")
        } else {
            rules.append("(deny network-outbound (require-not (remote unix-socket (path-literal \"/private/var/run/mDNSResponder\"))))")
        }
        if allLoopback { rules.append("(allow network-outbound (remote tcp \"localhost:*\"))") }
        for port in loopbackPorts { rules.append("(allow network-outbound (remote tcp \"localhost:\(port)\"))") }
        for port in remotePorts { rules.append("(allow network-outbound (remote tcp \"*:\(port)\"))") }
        if anyRemote { rules.append("(allow network-outbound (remote tcp \"*:*\"))") }
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
        // Developer access reads other processes' information, as a terminal does: `nohup` needs it to detach from the
        // console (measured: without it, "can't detach from console"). Signalling them stays out. (`ps` is setuid,
        // which no sandbox runs.)
        if !developer { rules.append("(deny process-info* (require-not (target same-sandbox)))") }
        rules += [
            "(deny signal (require-not (target same-sandbox)))",
            "(deny appleevent-send)",
            "(deny lsopen)",
            "(deny mach-lookup (global-name \"com.apple.coreservices.appleevents\") (global-name \"com.apple.coreservices.launchservicesd\"))",
        ]
        if kind == .tool, !developer {
            rules.append("(deny mach-lookup (global-name \"com.apple.securityd\") (global-name \"com.apple.SecurityServer\"))")
        }
        return rules.joined(separator: "\n") + "\n"
    }
}
