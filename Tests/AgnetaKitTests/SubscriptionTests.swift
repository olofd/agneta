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

    @Test func aDownloadThatDoesntMatchItsPinIsRefused() async throws {
        let (installer, root, zip) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not the pinned archive".utf8).write(to: zip)
        await #expect(throws: SignInError.self) { _ = try await installer.install("tool") }
    }
}
