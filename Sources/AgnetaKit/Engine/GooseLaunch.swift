// How Agneta starts goose-acp for one account: a private home, an explicit
// environment and nothing inherited from the user's own Goose setup.
import Foundation

public struct GooseLaunch: Sendable {
    public var executable: URL
    /// The account's private engine home. Goose's config, data, sessions and
    /// any subscription tokens live here and nowhere else.
    public var home: URL
    /// Provider selection and credentials, e.g. GOOSE_PROVIDER, GOOSE_MODEL, OPENAI_API_KEY.
    public var provider: [String: String]
    /// Extra folders prepended to PATH, e.g. a downloaded runtime's bin.
    public var paths: [URL]

    public init(executable: URL, home: URL, provider: [String: String], paths: [URL] = []) {
        self.executable = executable
        self.home = home
        self.provider = provider
        self.paths = paths
    }

    public var gooseRoot: URL { home.appending(path: "goose", directoryHint: .isDirectory) }
    public var temporary: URL { home.appending(path: "tmp", directoryHint: .isDirectory) }

    /// The complete environment. Keys outside this list never reach the engine.
    public func environment() -> [String: String] {
        var env: [String: String] = [
            "HOME": home.path(percentEncoded: false),
            "GOOSE_PATH_ROOT": gooseRoot.path(percentEncoded: false),
            "TMPDIR": temporary.path(percentEncoded: false),
            "PATH": (paths.map { $0.path(percentEncoded: false) } + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(
                separator: ":"),
            "LANG": "en_US.UTF-8",
            // The real user name: tools such as Claude Code key their keychain entries by it.
            "USER": NSUserName(), "LOGNAME": NSUserName(),
            "GOOSE_TELEMETRY_OFF": "1",
            "GOOSE_DISABLE_KEYRING": "1",
            // Goose otherwise spends an extra model call per session to name it, on the user's account.
            "GOOSE_DISABLE_SESSION_NAMING": "true",
            // Every tool call asks; Agneta answers from the session policy or forwards to the app.
            "GOOSE_MODE": "approve"
        ]
        for (key, value) in provider { env[key] = value }
        return env
    }

    /// Creates the home layout with owner-only permissions.
    public func prepare() throws {
        let files = FileManager.default
        for folder in [home, gooseRoot, temporary] {
            try files.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    public func start(directory: URL? = nil, wrapper: [String] = []) throws -> ChildProcess {
        try prepare()
        return try ChildProcess(
            executable: executable.path(percentEncoded: false),
            arguments: [],
            environment: environment(),
            directory: (directory ?? home).path(percentEncoded: false),
            wrapper: wrapper
        )
    }
}
