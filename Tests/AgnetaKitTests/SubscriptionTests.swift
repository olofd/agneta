import Foundation
import Testing
@testable import AgnetaKit

@Suite struct SubscriptionTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "agneta-sub-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory).realFileURL

    /// Goose's Claude route runs the user's own Claude Code with the account's own folders.
    @Test func gooseRunsTheUsersClaudeCode() {
        let account = SubscriptionAccount(route: .claudeCode, home: root.appending(path: "Accounts/claude", directoryHint: .isDirectory),
                                          claudeCode: URL(filePath: "/Applications/Claude.app/Contents/MacOS/claude"))
        let env = account.gooseEnvironment(model: "haiku")
        #expect(env["GOOSE_PROVIDER"] == "claude-acp" && env["GOOSE_MODEL"] == "haiku")
        #expect(env["CLAUDE_CODE_EXECUTABLE"] == "/Applications/Claude.app/Contents/MacOS/claude")
        #expect(account.runtimeFolders.map { $0.lastPathComponent } == ["Claude.app"])
    }

    @Test func claudeConfigPathNeverEndsInASlash() {
        // Claude Code keys its keychain entry by this exact text.
        let folder = URL(filePath: "/Users/u/Accounts/claude/claude", directoryHint: .isDirectory)
        #expect(ClaudeCodeSignIn.configPath(folder) == "/Users/u/Accounts/claude/claude")
        let account = SubscriptionAccount(route: .claudeCode, home: URL(filePath: "/Users/u/Accounts/claude", directoryHint: .isDirectory))
        #expect(account.gooseEnvironment()["CLAUDE_CONFIG_DIR"] == "/Users/u/Accounts/claude/claude")
    }
}

/// The runtime installer (claude-agent-acp): pinned, one install at a time, verified on every use.
@Suite struct RuntimeInstallerTests {
    func fixture() throws -> (installer: RuntimeInstaller, root: URL, zip: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "agneta-runtime-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory).realFileURL
        let payload = root.appending(path: "payload/tool-1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let tool = payload.appending(path: "tool")
        try "#!/bin/sh\necho ok\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false))
        let zip = root.appending(path: "tool.zip")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", payload.path(percentEncoded: false), zip.path(percentEncoded: false)]
        try process.run()
        process.waitUntilExit()
        let sha = RuntimeInstaller.sha256(try Data(contentsOf: zip))
        let lock = root.appending(path: "runtimes.lock")
        let asset: JSONValue = ["url": .string(zip.absoluteString), "sha256": .string(sha)]
        try JSONCoding.encode(["tool": ["version": "1", "assets": .object([RuntimeInstaller.architecture: asset])]] as JSONValue).write(to: lock)
        return (RuntimeInstaller(lockFile: lock, runtimes: root.appending(path: "Runtimes", directoryHint: .isDirectory)), root, zip)
    }

    @Test func installsOnceAndVerifiesEveryUse() async throws {
        let (installer, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Two at once share one install.
        async let first = installer.install("tool")
        async let second = installer.install("tool")
        let (a, b) = try await (first, second)
        #expect(a == b && FileManager.default.isExecutableFile(atPath: a.path(percentEncoded: false)))
        let folder = a.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: ".content-sha256").path(percentEncoded: false)))
        // A copy that no longer hashes as installed is replaced, not trusted for its marker.
        try "#!/bin/sh\necho tampered\n".write(to: a, atomically: true, encoding: .utf8)
        let again = try await installer.install("tool")
        #expect(try String(contentsOf: again, encoding: .utf8).contains("ok"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path(percentEncoded: false)) == ["1"])
    }

    /// OpenCode's pin is its whole engine lock (`opencode.lock`), with the archive's size.
    @Test func installsFromAnEngineLock() async throws {
        let (_, root, zip) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sha = RuntimeInstaller.sha256(try Data(contentsOf: zip))
        let lock = root.appending(path: "tool.lock")
        let asset: JSONValue = ["url": .string(zip.absoluteString), "sha256": .string(sha), "size": 1234]
        try JSONCoding.encode(["engine": "tool", "version": "2", "assets": .object([RuntimeInstaller.architecture: asset])] as JSONValue).write(to: lock)
        let installer = RuntimeInstaller(lockFile: lock, runtimes: root.appending(path: "Runtimes", directoryHint: .isDirectory))
        #expect(try installer.asset("tool").size == 1234)
        #expect(throws: SignInError.self) { _ = try installer.asset("other") }
        let tool = try await installer.install("tool")
        #expect(tool.path(percentEncoded: false).hasSuffix("Runtimes/tool/2/tool"))
        #expect(FileManager.default.isExecutableFile(atPath: tool.path(percentEncoded: false)))
    }

    /// Codex's runtime: a program (node) with a folder beside it (codex-acp), installed together under the lock's name.
    @Test func installsAProgramWithWhatSitsBesideIt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agneta-runtime-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory).realFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appending(path: "payload/codex-runtime", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: payload.appending(path: "codex-acp/dist"), withIntermediateDirectories: true)
        try "#!/bin/sh\necho ok\n".write(to: payload.appending(path: "node"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: payload.appending(path: "node").path(percentEncoded: false))
        try "// adapter".write(to: payload.appending(path: "codex-acp/dist/index.js"), atomically: true, encoding: .utf8)
        // A folder deeper down with the program's name, as codex-acp's dependencies have: not the program.
        try FileManager.default.createDirectory(at: payload.appending(path: "codex-acp/node_modules/a/node"), withIntermediateDirectories: true)
        try "x".write(to: payload.appending(path: "codex-acp/node_modules/a/node/index.js"), atomically: true, encoding: .utf8)
        let zip = root.appending(path: "runtime.zip")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", payload.path(percentEncoded: false), zip.path(percentEncoded: false)]
        try process.run()
        process.waitUntilExit()
        let asset: JSONValue = ["url": .string(zip.absoluteString), "sha256": .string(RuntimeInstaller.sha256(try Data(contentsOf: zip)))]
        let lock = root.appending(path: "codex-runtime.lock")
        try JSONCoding.encode(["engine": "codex-runtime", "version": "node-1-codex-acp-2", "assets": .object([RuntimeInstaller.architecture: asset])] as JSONValue).write(to: lock)
        let installer = RuntimeInstaller(lockFile: lock, runtimes: root.appending(path: "Runtimes", directoryHint: .isDirectory))
        #expect(installer.installed("codex-runtime", executable: "node") == nil)
        let node = try await installer.install("codex-runtime", executable: "node")
        #expect(node.path(percentEncoded: false).hasSuffix("Runtimes/codex-runtime/node-1-codex-acp-2/node"))
        #expect(FileManager.default.fileExists(atPath: node.deletingLastPathComponent().appending(path: "codex-acp/dist/index.js").path(percentEncoded: false)))
        #expect(installer.installed("codex-runtime", executable: "node") == node)
        // What sits beside the program is checked too: changed JavaScript fails the check, and an install replaces it.
        #expect(installer.verified("codex-runtime", executable: "node") == node)
        let script = node.deletingLastPathComponent().appending(path: "codex-acp/dist/index.js")
        try "// changed".write(to: script, atomically: true, encoding: .utf8)
        #expect(installer.verified("codex-runtime", executable: "node") == nil)
        _ = try await installer.install("codex-runtime", executable: "node")
        #expect(try String(contentsOf: script, encoding: .utf8) == "// adapter")
        #expect(installer.verified("codex-runtime", executable: "node") == node)
    }

    @Test func aDownloadThatDoesntMatchItsPinIsRefused() async throws {
        let (installer, root, zip) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not the pinned archive".utf8).write(to: zip)
        await #expect(throws: SignInError.self) { _ = try await installer.install("tool") }
    }
}
