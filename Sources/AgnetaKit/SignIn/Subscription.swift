// A subscription account: where its sign-in lives and what an engine needs to
// reach it. Agneta never handles a plan's tokens: the user's own Codex (ChatGPT
// plans) and Claude Code (Claude plans) sign in, keep and refresh their own
// credentials in the account's folder, each in its own way.
import Foundation

public enum SubscriptionRoute: String, Sendable, CaseIterable {
    /// A ChatGPT plan, on the user's own Codex, signed in with `codex login` (in <home>/codex).
    case chatGPT = "chatgpt"
    /// A Claude plan, on the user's own Claude Code, signed in with its own login (in <home>/claude).
    case claudeCode = "claude"
}

public struct SubscriptionAccount: Sendable, Equatable {
    public var route: SubscriptionRoute
    /// The account's home: codex/ for Codex, claude/ for Claude Code.
    public var home: URL
    /// For Claude Code, the installed adapter (claude-agent-acp).
    public var adapter: URL?
    /// For Claude Code, the user's own installed Claude Code, which every engine on the account runs.
    public var claudeCode: URL?

    public init(route: SubscriptionRoute, home: URL, adapter: URL? = nil, claudeCode: URL? = nil) {
        self.route = route
        self.home = home
        self.adapter = adapter
        self.claudeCode = claudeCode
    }

    public var claudeConfig: URL { home.appending(path: "claude", directoryHint: .isDirectory) }

    /// Claude Code's own temp root (CLAUDE_CODE_TMPDIR). It otherwise insists on /tmp/claude-<uid>,
    /// shared with the user's own Claude Code, and it puts Unix sockets inside, so the path is kept
    /// short (sockaddr_un allows 104 bytes): the system temp folder plus a short account hash.
    public var claudeTemp: URL {
        let digest = home.path(percentEncoded: false).utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        // The temp folder resolved, never this folder: an engine may have replaced it with a link (OwnFolder).
        return FileManager.default.temporaryDirectory.realFileURL.appending(path: "agneta-c\(String(digest, radix: 36).prefix(8))", directoryHint: .isDirectory)
    }

    /// Makes the account's folders its engines write real folders again, whatever an engine planted in their place.
    public func prepareFolders() throws {
        try OwnFolder.ensure(claudeConfig, under: home.deletingLastPathComponent())
        try OwnFolder.ensure(claudeTemp, under: FileManager.default.temporaryDirectory)
    }

    /// Folders the account's engines must be able to write (Claude Code rotates its credential there).
    public var credentialFolders: [URL] { route == .claudeCode ? [claudeConfig, claudeTemp] : [] }

    /// Folders the account's engines must be able to read beyond their own home.
    public var runtimeFolders: [URL] {
        (adapter.map { [$0.deletingLastPathComponent()] } ?? []) + (claudeCode.map { [ClaudeCodeAdapter.bundle(of: $0)] } ?? [])
    }

    /// Goose's environment for a Claude plan: its `claude-acp` provider, run with the user's own Claude Code.
    public func gooseEnvironment(model: String? = nil) -> [String: String] {
        var env = ["GOOSE_PROVIDER": "claude-acp", "GOOSE_MODEL": model ?? "current",
                   "CLAUDE_CONFIG_DIR": ClaudeCodeSignIn.configPath(claudeConfig), "CLAUDE_CODE_TMPDIR": claudeTemp.path(percentEncoded: false)]
        try? prepareFolders()
        if let adapter { env["AGNETA_EXTRA_PATH"] = adapter.deletingLastPathComponent().path(percentEncoded: false) }
        // The adapter runs the user's own Claude Code, not the copy its binary embeds.
        if let claudeCode { env["CLAUDE_CODE_EXECUTABLE"] = claudeCode.path(percentEncoded: false) }
        return env
    }
}
