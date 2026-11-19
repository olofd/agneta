// Developer access on the real sandbox: a command reads the home folder and reaches any host, as in a terminal,
// while the secrets, Agneta's own data and other apps' storage stay out and writes stay in the session's folders
// and the build caches. A home of its own stands in for the user's, with the same layout.
import Foundation
import Testing
@testable import AgnetaKit

@Suite(.serialized) struct DeveloperAccessTests {
    @Test func aDeveloperCommandReachesWhatATerminalDoesButNoSecrets() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agneta-dev-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory).realFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let agneta = home.appending(path: "Library/Application Support/agneta-test", directoryHint: .isDirectory)
        // The app's workspace where Agneta keeps them, beside its data, whose every copy is out of reach.
        let workspace = home.appending(path: "Library/Application Support/com.objectivecoder.agneta Workspaces/g1", directoryHint: .isDirectory)
        let scratch = agneta.appending(path: "Engines/e1/scratch", directoryHint: .isDirectory)
        let files = ["project/notes.txt", ".ssh/config", ".aws/credentials", "Library/Keychains/login.keychain-db",
                     "Library/Containers/other.app/data.txt", "Library/Application Support/agneta-test/agneta.sqlite", ".cargo/registry/index.txt",
                     "Library/Application Support/com.objectivecoder.agneta.dev/agneta.sqlite",
                     "Library/Application Support/com.objectivecoder.agneta Workspaces/g2/notes.txt", "Library/Logs/Agneta Dev/agneta.log",
                     "Library/Caches/com.objectivecoder.agneta/cache.db", ".config/goose/config.yaml", ".local/share/opencode/auth.json",
                     "Library/Application Support/com.objectivecoder.agneta Workspaces/g1/heldout/answers.txt"]
        for file in files {
            let url = home.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        for folder in [workspace, scratch] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let context = PolicyContext(userHome: home, agnetaRoots: [agneta])
        // The app denies a folder inside its own workspace, which developer access allows back as a whole.
        let heldout = workspace.appending(path: "heldout", directoryHint: .isDirectory).path(percentEncoded: false)
        var policy = try SessionPolicy.parse(["tools": "workspace", "sandbox": "developer", "denied": [.string(heldout)]],
                                             cwd: workspace.path(percentEncoded: false), context: context)
        policy.sandbox = .developer
        let caches = home.appending(path: "Library/Application Support/com.objectivecoder.agneta Workspaces/.build-caches/g1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        policy.buildCaches = caches
        let profile = policy.toolProfile(scratch: scratch, home: home, agnetaRoots: [agneta]).render()

        func path(_ relative: String) -> String { home.appending(path: relative).path(percentEncoded: false) }
        let script = """
        check() { name=$1; shift; if "$@" >/dev/null 2>&1; then echo "$name=yes"; else echo "$name=no"; fi; }
        check read-project cat '\(path("project/notes.txt"))'
        check read-ssh cat '\(path(".ssh/config"))'
        check read-aws cat '\(path(".aws/credentials"))'
        check read-keychain cat '\(path("Library/Keychains/login.keychain-db"))'
        check read-container cat '\(path("Library/Containers/other.app/data.txt"))'
        check read-agneta cat '\(path("Library/Application Support/agneta-test/agneta.sqlite"))'
        check read-agneta-dev cat '\(path("Library/Application Support/com.objectivecoder.agneta.dev/agneta.sqlite"))'
        check read-other-workspace cat '\(path("Library/Application Support/com.objectivecoder.agneta Workspaces/g2/notes.txt"))'
        check read-logs cat '\(path("Library/Logs/Agneta Dev/agneta.log"))'
        check read-caches cat '\(path("Library/Caches/com.objectivecoder.agneta/cache.db"))'
        check read-goose cat '\(path(".config/goose/config.yaml"))'
        check read-opencode cat '\(path(".local/share/opencode/auth.json"))'
        check read-heldout cat '\(heldout)/answers.txt'
        check write-app-cache touch '\(caches.path(percentEncoded: false))/built.txt'
        check write-user-pycache mkdir -p '\(path("Library/Caches/com.apple.python/x"))'
        check write-workspace touch '\(workspace.path(percentEncoded: false))/built.txt'
        check write-cache touch '\(path(".cargo/registry/new.txt"))'
        check write-home touch '\(path("project/changed.txt"))'
        out=$(/usr/bin/nc -vz -G 5 example.com 443 2>&1); case "$out" in *"not permitted"*) echo "internet=denied";; *) echo "internet=allowed";; esac
        """
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, "/bin/sh", "-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let results = Dictionary(uniqueKeysWithValues: output.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        })
        #expect(results["read-project"] == "yes", "\(output)")
        for secret in ["read-ssh", "read-aws", "read-keychain", "read-container", "read-agneta", "read-agneta-dev", "read-other-workspace",
                       "read-logs", "read-caches", "read-goose", "read-opencode", "read-heldout"] { #expect(results[secret] == "no", "\(secret): \(output)") }
        #expect(results["write-workspace"] == "yes" && results["write-app-cache"] == "yes", "\(output)")
        // The user's own caches stay read-only: a planted entry there would run later as the user, outside any sandbox.
        #expect(results["write-cache"] == "no" && results["write-user-pycache"] == "no", "\(output)")
        #expect(results["write-home"] == "no", "writes stay in the session's folders: \(output)")
        #expect(results["internet"] == "allowed", "\(output)")
    }
}

/// The app's environment for brokered commands: its toolchain's PATH (inside the session's folders) and settings,
/// never what confines or names the command.
@Test func toolEnvironmentTakesTheAppsToolchainButNothingThatConfines() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "agneta-env-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory).realFileURL
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appending(path: "work", directoryHint: .isDirectory), kit = root.appending(path: "kit/bin", directoryHint: .isDirectory)
    for folder in [workspace, kit] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let context = PolicyContext(userHome: FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [root.appending(path: "agneta")])
    let cwd = workspace.path(percentEncoded: false)
    let policy = try SessionPolicy.parse(["readOnly": [.string(root.appending(path: "kit").path(percentEncoded: false))],
                                          "toolEnvironment": ["PATH": .string(kit.path(percentEncoded: false)), "CARGO_HOME": "/x/cargo", "PYTHONPATH": "/x/kit"]],
                                         cwd: cwd, context: context)
    #expect(policy.toolEnvironment["CARGO_HOME"] == "/x/cargo")
    for (key, value) in [("HOME", "/tmp"), ("DYLD_INSERT_LIBRARIES", "/x.dylib"), ("AGNETA_BROKER_TOKEN", "t"), ("CLAUDE_CODE_SHELL_PREFIX", "/bin/sh"),
                         ("BASH_ENV", "/tmp/x"), ("PATH", "/Users/somewhere/else/bin"), ("PATH", kit.path(percentEncoded: false) + "::/usr/bin"), ("bad-name", "x")] {
        #expect(throws: PolicyRejection.self, "\(key)") { try SessionPolicy.parse(["toolEnvironment": [key: .string(value)]], cwd: cwd, context: context) }
    }
}

/// A contained command can't look a name up (a lookup can carry data out) but still reaches its loopback ports; a
/// developer one resolves names, as in a terminal.
@Test func aContainedCommandResolvesNoNamesButReachesItsLoopbackPorts() throws {
    let listener = try Listener()
    let script = """
    /usr/bin/python3 -I -c 'import socket
    try:
        socket.getaddrinfo("github.com", 443); print("resolved=yes")
    except Exception: print("resolved=no")
    s = socket.socket(); s.settimeout(3)
    try:
        s.connect(("127.0.0.1", \(listener.port))); print("loopback=yes")
    except Exception as e: print("loopback=no", e)'
    """
    func run(_ profile: SandboxProfile) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile.render(), "/bin/sh", "-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    let root = FileManager.default.temporaryDirectory.realFileURL
    let contained = SandboxProfile(kind: .tool, writable: [root], denied: [], loopbackPorts: [listener.port])
    let out = try run(contained)
    #expect(out.contains("resolved=no") && out.contains("loopback=yes"), "\(out)")
    var developer = contained
    developer.developer = true
    developer.anyRemote = true
    #expect(try run(developer).contains("resolved=yes"))
}

/// Developer access runs `nohup` as a terminal does; a contained command can't read other processes. (`ps` is setuid,
/// which no macOS sandbox runs.)
@Test func developerAccessReadsProcessesAsATerminalDoes() throws {
    func run(_ profile: SandboxProfile, _ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile.render(), "/bin/sh", "-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    let root = FileManager.default.temporaryDirectory.realFileURL
    let contained = SandboxProfile(kind: .tool, writable: [root], denied: [])
    var developer = contained
    developer.developer = true
    #expect(try run(developer, "/usr/bin/nohup /usr/bin/true") == 0)
    #expect(try run(contained, "/usr/bin/nohup /usr/bin/true") != 0)
}

/// Sign-in rewrites Codex's settings without knowing the shell: the one the last launch wrote stays.
@Test func codexSettingsKeepTheShellAcrossASignIn() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "agneta-codex-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    try CodexAdapter.writeConfig(home, shell: URL(filePath: "/Applications/Agneta.app/Contents/MacOS/agneta-shell"))
    try CodexAdapter.writeConfig(home)
    let toml = try String(contentsOf: home.appending(path: "config.toml"), encoding: .utf8)
    #expect(toml.components(separatedBy: CodexAdapter.shellServerHeader).count == 2 && toml.contains("agneta-shell"), "\(toml)")
}

/// Developer access keeps Claude Code's own tools, apart from those reaching the user's claude.ai account or devices.
@Test func developerAccessKeepsClaudeCodesToolsButNotTheAccounts() throws {
    let context = PolicyContext(userHome: FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [])
    var policy = try SessionPolicy.parse(["tools": "workspace", "sandbox": "developer"], cwd: FileManager.default.temporaryDirectory.path(percentEncoded: false), context: context)
    policy.sandbox = .developer
    #expect(ClaudeCodeAdapter.tools(policy) == nil)
    let off = ClaudeCodeAdapter.disallowed(policy)
    for tool in ["RemoteTrigger", "Artifact", "Projects", "ClaudeDesign", "SendUserMessage", "SendUserFile", "PushNotification", "Monitor", "PowerShell"] {
        #expect(off.contains(tool), "\(tool)")
    }
    for tool in ["Bash", "WebFetch", "WebSearch", "Agent", "Skill"] { #expect(!off.contains(tool), "\(tool)") }
}

/// A folder an engine denies inside one developer access allows back stays denied, and its own part of it stays
/// open (Claude Code's other tasks' transcripts in the account's folder, its own task's folder).
@Test func whatAnEngineDeniesStaysDeniedUnderDeveloperAccess() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "agneta-order-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory).realFileURL
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appending(path: "config", directoryHint: .isDirectory), projects = config.appending(path: "projects", directoryHint: .isDirectory)
    for name in ["own", "other"] {
        try FileManager.default.createDirectory(at: projects.appending(path: name), withIntermediateDirectories: true)
        try "x".write(to: projects.appending(path: "\(name)/t.jsonl"), atomically: true, encoding: .utf8)
    }
    var profile = SandboxProfile(kind: .engine, writable: [config], denied: [projects])
    profile.exceptions = [projects.appending(path: "own", directoryHint: .isDirectory)]
    profile.outerDenied = [root]
    profile.outerExceptions = [config]
    func reads(_ name: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile.render(), "/bin/cat", projects.appending(path: "\(name)/t.jsonl").path(percentEncoded: false)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    #expect(try reads("own"))
    #expect(try !reads("other"))
}

/// A folder of Agneta's that a session replaced with a symlink grants nothing: Agneta puts a real folder back without
/// following the link, and the profile names the folder as it is, so writing through a link planted later is refused.
@Test func aPlantedSymlinkGrantsNothing() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "agneta-link-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory).realFileURL
    defer { try? FileManager.default.removeItem(at: root) }
    let victim = root.appending(path: "home", directoryHint: .isDirectory), agneta = root.appending(path: "agneta", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: agneta.appending(path: "Engines"), withIntermediateDirectories: true)
    try "keep".write(to: victim.appending(path: "config"), atomically: true, encoding: .utf8)
    // A session replaced its engine home with a link to the user's folder.
    let home = agneta.appending(path: "Engines/e1", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: home, withDestinationURL: victim)
    let made = try OwnFolder.ensure(home.appending(path: "scratch", directoryHint: .isDirectory), under: agneta)
    var info = stat()
    #expect(lstat(home.path(percentEncoded: false), &info) == 0 && info.st_mode & S_IFMT == S_IFDIR, "a real folder again")
    #expect(FileManager.default.fileExists(atPath: victim.appending(path: "config").path(percentEncoded: false)), "the link's target untouched")
    #expect(made.path(percentEncoded: false).hasPrefix(agneta.path(percentEncoded: false)))

    // Planted again after the check: the profile still names the folder, so the link reaches nothing.
    let scratch = made.path(percentEncoded: false).trimmingSuffix("/")
    try FileManager.default.removeItem(at: made)
    try FileManager.default.createSymbolicLink(at: made, withDestinationURL: victim)
    var profile = SandboxProfile(kind: .tool, writable: [made], denied: [])
    profile.verbatim = [scratch]
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
    process.arguments = ["-p", profile.render(), "/bin/sh", "-c", "echo x > '\(scratch)/config'"]
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus != 0)
    #expect(try String(contentsOf: victim.appending(path: "config"), encoding: .utf8) == "keep")
}

/// A granted folder a session replaced with a link to somewhere else no longer matches the grant.
@Test func aGrantedFolderSwappedForALinkIsRefused() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "agneta-grant-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory).realFileURL
    defer { try? FileManager.default.removeItem(at: root) }
    let granted = root.appending(path: "project", directoryHint: .isDirectory), elsewhere = root.appending(path: "documents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: granted, withDestinationURL: elsewhere)
    let grant = Router.Grant(app: "App", accounts: ["a"], tools: .workspace, folders: [granted.path(percentEncoded: false)])
    let context = PolicyContext(userHome: FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [])
    let policy = try SessionPolicy.parse(nil, cwd: granted.path(percentEncoded: false), context: context)
    #expect(GrantScope.check(policy, against: grant) != nil)
}

/// Every path under Agneta's own roots is written literally, so a link a session planted below them reaches nothing,
/// with no list of such paths to keep up to date; Agneta's own writes into those folders never follow one either.
@Test func agnetasFoldersAreNeverFollowed() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "agneta-literal-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory).realFileURL
    defer { try? FileManager.default.removeItem(at: root) }
    let victim = root.appending(path: "home", directoryHint: .isDirectory), agneta = root.appending(path: "agneta", directoryHint: .isDirectory)
    for folder in [victim.appending(path: "Library/Keychains"), agneta.appending(path: "Accounts/a1")] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try "keep".write(to: victim.appending(path: "Library/Keychains/login.keychain-db"), atomically: true, encoding: .utf8)
    try "keep".write(to: victim.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
    // A folder an engine writes, replaced with a link before its profile is written.
    let temp = agneta.appending(path: "Accounts/a1/temp", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: temp, withDestinationURL: victim)
    var profile = SandboxProfile(kind: .engine, writable: [temp], denied: [])
    profile.literalRoots = [agneta]
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
    process.arguments = ["-p", profile.render(), "/bin/sh", "-c", "echo x >> '\(victim.path(percentEncoded: false))/.zshrc'"]
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus != 0)

    // An engine home's Library swapped for a link: linking the Keychains doesn't delete through it.
    let home = agneta.appending(path: "Accounts/a1/home", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: home.appending(path: "Library"), withDestinationURL: victim.appending(path: "Library"))
    try ClaudeCodeSignIn.linkKeychains(into: home)
    #expect(FileManager.default.fileExists(atPath: victim.appending(path: "Library/Keychains/login.keychain-db").path(percentEncoded: false)))

    // The engine's log swapped for a link: its output isn't appended to wherever that points.
    let log = home.appending(path: "engine.log")
    try FileManager.default.createSymbolicLink(at: log, withDestinationURL: victim.appending(path: ".zshrc"))
    let pipe = Pipe()
    EngineSupervisor.drain(pipe.fileHandleForReading, into: log)
    try pipe.fileHandleForWriting.write(contentsOf: Data("planted\n".utf8))
    try pipe.fileHandleForWriting.close()
    Thread.sleep(forTimeInterval: 0.3)
    #expect(try String(contentsOf: victim.appending(path: ".zshrc"), encoding: .utf8) == "keep")
    #expect(try String(contentsOf: victim.appending(path: "Library/Keychains/login.keychain-db"), encoding: .utf8) == "keep")
}

/// A session can't rename or replace a folder it writes, nor one that holds a denied or read-only path inside it:
/// that would carry the protected path out of its rule, or put a link in the folder's place. Inside, work goes on.
@Test func writableFoldersAreWorkedInNotMoved() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "agneta-pin-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory).realFileURL
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appending(path: "work", directoryHint: .isDirectory), scratch = root.appending(path: "scratch", directoryHint: .isDirectory)
    for folder in [workspace.appending(path: "secret/inner"), scratch] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    try "s".write(to: workspace.appending(path: "secret/inner/key.txt"), atomically: true, encoding: .utf8)
    let profile = SandboxProfile(kind: .tool, writable: [workspace, scratch], denied: [workspace.appending(path: "secret/inner", directoryHint: .isDirectory)])
    func run(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile.render(), "/bin/sh", "-c", command]
        process.currentDirectoryURL = workspace
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    let w = workspace.path(percentEncoded: false), s = scratch.path(percentEncoded: false)
    #expect(try run("echo a > f && mkdir d && mv f d/g && mv d d2 && rm -rf d2 && mkdir -p e/f && ls >/dev/null") == 0, "work inside goes on")
    #expect(try run("touch '\(w)'") == 0, "its own times may change (tar, rsync)")
    #expect(try run("mkdir '\(s)/new' && rmdir '\(s)/new'") == 0)
    #expect(try run("mv '\(w)' '\(s)/w'") != 0, "the workspace can't be moved")
    #expect(try run("mv '\(w)/secret' '\(s)/x'") != 0, "nor a folder holding a denied one")
    #expect(try run("cat '\(w)/secret/inner/key.txt'") != 0)
    #expect(FileManager.default.fileExists(atPath: workspace.appending(path: "secret/inner/key.txt").path(percentEncoded: false)))
}
