// Claude subscription through Claude Code. Anthropic requires that sign-in
// completes through its own flow in the unmodified Claude Code, and that
// third parties never handle the tokens (code.claude.com legal and
// compliance). So Agneta runs the user's own installed Claude Code's login
// (`claude auth login --claudeai`) on a hidden terminal with the account's
// private CLAUDE_CONFIG_DIR, and only shows the steps. Claude Code stores its
// credential itself (the login Keychain, keyed by that folder). Every engine
// on the account then runs that same Claude Code: the Claude Code engine and
// Goose's `claude-acp` provider, both through the pinned claude-agent-acp
// adapter (downloaded on first use, below) with CLAUDE_CODE_EXECUTABLE.
import CryptoKit
import Foundation

public struct RuntimeInstaller: Sendable {
    /// `size`: the archive's size in bytes, when the lock records it (to say how big a download is before it starts).
    public struct Asset: Sendable { public var url: URL; public var sha256: String; public var version: String; public var size: Int? }

    public let lockFile: URL
    public let runtimes: URL

    public init(lockFile: URL, runtimes: URL) {
        self.lockFile = lockFile
        self.runtimes = runtimes
    }

    public static var architecture: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return machine == "arm64" ? "arm64" : "x86_64"
    }

    /// The pin for `name`: an entry of a runtimes lock (`runtimes.lock`), or a whole engine lock whose `engine` is
    /// `name` (`opencode.lock`).
    public func asset(_ name: String) throws -> Asset {
        let lock = try JSONCoding.decode(Data(contentsOf: lockFile))
        guard let entry = lock["engine"]?.stringValue == name ? lock : lock[name], let version = entry["version"]?.stringValue,
              let asset = entry["assets"]?[Self.architecture], let url = asset["url"]?.stringValue.flatMap(URL.init(string:)),
              let sha = asset["sha256"]?.stringValue else { throw SignInError.provider("\(name) isn't pinned for \(Self.architecture)") }
        return Asset(url: url, sha256: sha, version: version, size: asset["size"]?.intValue.map(Int.init))
    }

    /// The installed executable, downloading and verifying it first if needed. One install per version runs at a
    /// time in this process (a second caller gets the first's result); a cached copy is used only while its content
    /// still hashes to what was installed; a new copy is moved into place in one step, so a running engine never
    /// sees a half-installed or replaced folder.
    /// - Parameter executable: the program in the archive, when it isn't named `name` (the Codex runtime: `node`,
    ///   beside the codex-acp folder). Everything beside it in the archive is installed with it.
    /// - Parameter received: bytes downloaded so far and the total when known, as the download goes.
    public func install(_ name: String, executable: String? = nil, progress: SignInProgress? = nil,
                        received: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> URL {
        let asset = try asset(name)
        let folder = runtimes.appending(path: "\(name)/\(asset.version)", directoryHint: .isDirectory)
        return try await InstallGate.shared.run(folder.path(percentEncoded: false)) {
            try await self.installNow(name, executable: executable ?? name, asset: asset, folder: folder, progress: progress, received: received)
        }
    }

    /// Where `name`'s program is (or will be) installed, for checking before a download.
    public func installed(_ name: String, executable: String? = nil) -> URL? {
        guard let asset = try? asset(name) else { return nil }
        let folder = runtimes.appending(path: "\(name)/\(asset.version)", directoryHint: .isDirectory)
        let program = folder.appending(path: executable ?? name)
        return FileManager.default.isExecutableFile(atPath: program.path(percentEncoded: false)) ? program : nil
    }

    /// The installed program, only while it's still what its pin says (the archive's hash, and the program's own
    /// content as installed): for checking an install found on disk before running it.
    public func verified(_ name: String, executable: String? = nil) -> URL? {
        guard let asset = try? asset(name) else { return nil }
        let folder = runtimes.appending(path: "\(name)/\(asset.version)", directoryHint: .isDirectory)
        let program = folder.appending(path: executable ?? name)
        return Self.isInstalled(executable: program, folder: folder, asset: asset) ? program : nil
    }

    private func installNow(_ name: String, executable program: String, asset: Asset, folder: URL, progress: SignInProgress?,
                            received: (@Sendable (Int64, Int64?) -> Void)?) async throws -> URL {
        let executable = folder.appending(path: program)
        if Self.isInstalled(executable: executable, folder: folder, asset: asset) { return executable }
        progress?(.waiting("Downloading \(name) \(asset.version)…"))
        let download = try await Download.fetch(asset.url, expected: asset.size.map(Int64.init), received: received)
        defer { try? FileManager.default.removeItem(at: download) }
        let data = try Data(contentsOf: download, options: .mappedIfSafe)
        guard Self.sha256(data) == asset.sha256 else { throw SignInError.provider("\(name) download didn't match its pinned checksum") }
        let staging = runtimes.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let unzip = try ChildProcess(executable: "/usr/bin/ditto", arguments: ["-x", "-k", download.path(percentEncoded: false), staging.path(percentEncoded: false)], environment: [:])
        guard await unzip.waitForExit() == 0 else { throw SignInError.provider("couldn't unpack \(name)") }
        // The program is the executable file of that name nearest the archive's top: a folder of the same name deeper
        // down (codex-acp's dependencies have one called "node") isn't it.
        guard let found = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap({ $0 as? URL })
            .filter({ $0.lastPathComponent == program && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                      && FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) })
            .min(by: { $0.pathComponents.count < $1.pathComponents.count }) else {
            throw SignInError.provider("\(name) wasn't in its archive")
        }
        // The markers go in before the folder is published: the archive's hash and the whole installed tree's, checked
        // on every later use.
        let prepared = found.deletingLastPathComponent()
        guard let contents = Self.treeHash(prepared) else { throw SignInError.provider("couldn't read \(name) after unpacking it") }
        try asset.sha256.write(to: prepared.appending(path: ".sha256"), atomically: true, encoding: .utf8)
        try contents.write(to: prepared.appending(path: ".content-sha256"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A bad copy already in place is moved aside first (removed once the new one is in), then the new folder
        // takes its name in one rename. If another process published meanwhile, its copy is used.
        let aside = folder.deletingLastPathComponent().appending(path: ".\(asset.version)-old-\(UUID().uuidString)", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) { try? FileManager.default.moveItem(at: folder, to: aside) }
        defer { try? FileManager.default.removeItem(at: aside) }
        do {
            try FileManager.default.moveItem(at: prepared, to: folder)
        } catch {
            guard Self.isInstalled(executable: executable, folder: folder, asset: asset) else { throw error }
        }
        return executable
    }

    /// Installed, and still what was installed: the archive pin matches and everything installed with the program
    /// (codex-acp's JavaScript beside Node, say) hashes as recorded, not only the program.
    static func isInstalled(executable: URL, folder: URL, asset: Asset) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)),
              (try? String(contentsOf: folder.appending(path: ".sha256"), encoding: .utf8)) == asset.sha256,
              let recorded = try? String(contentsOf: folder.appending(path: ".content-sha256"), encoding: .utf8) else { return false }
        return treeHash(folder) == recorded
    }

    /// One hash of a folder's whole tree, in path order: each file's path, permissions and content, and each symbolic
    /// link's target (never followed). The markers at its top aren't part of it. Nil when something can't be read.
    static func treeHash(_ folder: URL) -> String? {
        let root = folder.standardizedFileURL.path(percentEncoded: false)
        guard let walker = FileManager.default.enumerator(atPath: root) else { return nil }
        var lines: [String] = []
        while let relative = walker.nextObject() as? String {
            guard relative != ".sha256", relative != ".content-sha256" else { continue }
            let path = root + (root.hasSuffix("/") ? "" : "/") + relative
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), let type = attributes[.type] as? FileAttributeType else { return nil }
            let mode = String((attributes[.posixPermissions] as? Int) ?? 0, radix: 8)
            switch type {
            case .typeSymbolicLink:
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
                lines.append("\(relative)\u{0}link\u{0}\(target)")
            case .typeRegular:
                guard let data = try? Data(contentsOf: URL(filePath: path), options: .mappedIfSafe) else { return nil }
                lines.append("\(relative)\u{0}\(mode)\u{0}\(sha256(data))")
            case .typeDirectory:
                lines.append("\(relative)\u{0}dir")
            default:
                return nil
            }
        }
        return sha256(Data(lines.sorted().joined(separator: "\n").utf8))
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// A download that reports its bytes as they arrive. The async `URLSession.download(from:delegate:)` never calls a
/// download delegate's `didWriteData`, so a download through it showed no progress at all (the sign-in window sat at
/// "Zero KB" while bytes arrived); a session of its own, with the delegate as the session's, does. The total is the
/// server's, else the size the lock records. Cancelling the calling task cancels the download.
final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expected: Int64?
    private let report: (@Sendable (Int64, Int64?) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var file: URL?

    private init(expected: Int64?, report: (@Sendable (Int64, Int64?) -> Void)?) {
        self.expected = expected
        self.report = report
    }

    /// Downloads `url` to a temporary file the caller owns (and removes).
    static func fetch(_ url: URL, expected: Int64? = nil, received: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> URL {
        let download = Download(expected: expected, report: received)
        let session = URLSession(configuration: .ephemeral, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.lock.withLock { download.continuation = continuation }
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        report?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected)
    }

    /// The system removes `location` when this returns, so it's moved somewhere of ours first.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) { return }
        let kept = FileManager.default.temporaryDirectory.appending(path: "agneta-download-\(UUID().uuidString)")
        if (try? FileManager.default.moveItem(at: location, to: kept)) != nil { lock.withLock { file = kept } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, file) = lock.withLock { () -> (CheckedContinuation<URL, Error>?, URL?) in
            defer { self.continuation = nil }
            return (self.continuation, self.file)
        }
        if let error {
            continuation?.resume(throwing: error)
        } else if let file {
            continuation?.resume(returning: file)
        } else {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            continuation?.resume(throwing: SignInError.provider("the download failed (HTTP \(status))"))
        }
    }
}

/// Runs one install per key at a time; callers asking meanwhile wait for the same result.
actor InstallGate {
    static let shared = InstallGate()
    private var running: [String: Task<URL, Error>] = [:]

    func run(_ key: String, _ work: @escaping @Sendable () async throws -> URL) async throws -> URL {
        if let task = running[key] { return try await task.value }
        let task = Task { try await work() }
        running[key] = task
        defer { running[key] = nil }
        return try await task.value
    }
}

public struct ClaudeCodeSignIn: Sendable {
    /// The user's installed Claude Code (CLILocator).
    public let cli: URL
    /// The account's private Claude Code folder; the Keychain entry is keyed by it.
    public let configDirectory: URL

    public init(cli: URL, configDirectory: URL) {
        self.cli = cli
        self.configDirectory = configDirectory
    }

    /// CLAUDE_CONFIG_DIR exactly as every Claude Code process must see it. Claude Code keys its
    /// keychain entry by this text, so ".../claude" and ".../claude/" are different logins
    /// (measured). No trailing slash, ever.
    public static func configPath(_ folder: URL) -> String {
        let path = folder.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// The environment Claude Code runs with, for sign-in and for the engine alike.
    public var environment: [String: String] {
        [
            "CLAUDE_CONFIG_DIR": Self.configPath(configDirectory),
            "HOME": configDirectory.deletingLastPathComponent().path(percentEncoded: false),
            "PATH": "\(cli.deletingLastPathComponent().path(percentEncoded: false)):/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
            // Claude Code names its keychain entry's account after the user; without USER it
            // saves under "unknown" and later lookups miss it (measured).
            "USER": NSUserName(), "LOGNAME": NSUserName(),
        ]
    }

    /// Claude Code keeps its credential in the user's login keychain, which macOS finds through
    /// $HOME/Library/Keychains (measured: with any other HOME, "A default keychain could not be
    /// found" and the login fails to save). A private home therefore links that one folder back.
    /// Settings files in the account's config folder that Claude Code would act on outside any sandbox (an API key
    /// helper, environment, hooks): Agneta never writes them, its engines may not, and they're cleared before Agneta
    /// runs Claude Code itself.
    public static let trustedSettings = ["settings.json", "settings.local.json", "managed-settings.json", "CLAUDE.md", "commands", "agents", "skills", "hooks"]

    public static func linkKeychains(into home: URL) throws {
        // A real folder first: an engine may have replaced its home's Library with a link, and removing the old
        // Keychains link through it would delete wherever that points.
        let library = try OwnFolder.ensure(home.appending(path: "Library", directoryHint: .isDirectory), under: home.deletingLastPathComponent())
        let link = library.appending(path: "Keychains")
        let real = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Keychains", directoryHint: .isDirectory)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false))) == real.path(percentEncoded: false) { return }
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    }

    /// Whether Claude Code is signed in for this account (`auth status`, JSON with `loggedIn`).
    /// The account's config folder made Agneta's own again before Claude Code runs on it outside any sandbox: never a
    /// link an engine planted in its place.
    func prepareFolders() throws {
        try OwnFolder.ensure(configDirectory, under: configDirectory.deletingLastPathComponent().deletingLastPathComponent())
        for name in Self.trustedSettings { try? FileManager.default.removeItem(at: configDirectory.appending(path: name)) }
        try Self.linkKeychains(into: configDirectory.deletingLastPathComponent())
    }

    public func isSignedIn() async throws -> Bool {
        try prepareFolders()
        let child = try ChildProcess(executable: cli.path(percentEncoded: false), arguments: ["auth", "status", "--json"], environment: environment,
                                     directory: configDirectory.deletingLastPathComponent().path(percentEncoded: false))
        try? child.stdin.close()
        var data = Data()
        for try await line in LineStream.lines(from: child.stdout) { data.append(line) }
        _ = await child.waitForExit()
        return (try? JSONCoding.decode(data))?["loggedIn"]?.boolValue == true
    }

    /// Claude Code's own logout for this account: removes its login-Keychain entry, which is keyed by
    /// the account's config folder, so Sign Out and Reset leave nothing behind. Returns whether it
    /// exited cleanly; at most `timeout`.
    @discardableResult
    public func signOut(timeout: Duration = .seconds(20)) async -> Bool {
        guard (try? prepareFolders()) != nil,
              let child = try? ChildProcess(executable: cli.path(percentEncoded: false), arguments: ["auth", "logout"], environment: environment,
                                            directory: configDirectory.deletingLastPathComponent().path(percentEncoded: false)) else { return false }
        try? child.stdin.close()
        let drain = Task { for try await _ in LineStream.lines(from: child.stdout) {} }
        let watchdog = Task { try await Task.sleep(for: timeout); await child.stop() }
        let status = await child.waitForExit()
        watchdog.cancel()
        drain.cancel()
        return status == 0
    }

    /// Runs Claude Code's own login for a Claude subscription and reports its steps.
    /// - Parameter code: supplies the code Claude's page shows after sign-in, which its login asks to have pasted.
    public func run(progress: @escaping SignInProgress, code: @escaping SignInCodeSource, timeout: Duration = .seconds(600),
                    output: (@Sendable (String) -> Void)? = nil) async throws {
        try prepareFolders()
        let terminal = try PTYProcess(executable: cli.path(percentEncoded: false), arguments: ["auth", "login", "--claudeai"],
                                      environment: environment, directory: configDirectory.path(percentEncoded: false))
        progress(.waiting("Starting Claude's sign-in…"))
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            terminal.stop()
        }
        defer { watchdog.cancel() }
        var transcript = ""
        var announced: Set<URL> = []
        var askedForCode = false
        let declined = OnceFlag()
        // Cancelling the sign-in (Cancel in the sheet, Agneta quitting) ends Claude's login too.
        await withTaskCancellationHandler {
            for await chunk in terminal.output {
                output?(chunk)
                // A terminal ends lines with CRLF, which Swift treats as one Character; normalize to LF.
                transcript += chunk.withoutANSI.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                // Only complete lines: a URL still being printed must not be announced half-way.
                let complete = transcript.split(separator: "\n", omittingEmptySubsequences: false).dropLast().joined(separator: "\n")
                for match in complete.matches(of: /https:\/\/[^\s"'<>]+/) {
                    guard let url = URL(string: String(match.output)), SignInPage.belongs(url, to: SignInPage.anthropic),
                          announced.insert(url).inserted else { continue }
                    // Claude Code opens the page itself (it ignores BROWSER and PATH; measured).
                    progress(.browserOpened(url))
                    progress(.waiting("Claude opened its sign-in page in your browser. Finish signing in there."))
                }
                if !askedForCode, transcript.contains("Paste code here") {
                    askedForCode = true
                    progress(.pasteCode("When Claude shows you a code, paste it here."))
                    let terminal = terminal
                    Task {
                        if let pasted = await code()?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
                            terminal.send(pasted + "\r")
                        } else {
                            _ = declined.take()
                            terminal.stop()
                        }
                    }
                }
            }
        } onCancel: {
            terminal.stop()
        }
        if Task.isCancelled || !declined.take() { throw SignInError.cancelled }
        let status = terminal.status ?? -1
        if watchdog.isCancelled == false, status != 0 && (status & 0x7f) == SIGTERM { throw SignInError.timedOut }
        guard status == 0 else {
            let last = transcript.split(separator: "\n").last.map(String.init) ?? "unknown error"
            throw SignInError.provider("Claude's sign-in ended: \(last.trimmingCharacters(in: .whitespaces))")
        }
        progress(.signedIn("Claude"))
    }
}
