// Signs a ChatGPT account in for the Codex engine with the user's own
// `codex login`, for the account's own CODEX_HOME. Codex keeps the sign-in in
// the login Keychain ("Codex Auth", keyed by that folder; keyring mode, set in
// the folder's config.toml) and refreshes it itself, so no token is in a file
// that the engine's own tools could read. Separate from Agneta's own ChatGPT
// sign-in, so two programs never refresh the same login.
import Foundation

public struct CodexSignIn: Sendable {
    public let cli: URL
    public let codexHome: URL

    public init(cli: URL, codexHome: URL) {
        self.cli = cli
        self.codexHome = codexHome
    }

    /// What Codex says (`codex login status`): the sign-in is in the Keychain, not a file Agneta could check.
    public func isSignedIn() async -> Bool { await codex(["login", "status"]) == 0 }

    /// Codex's own logout, which removes the Keychain entry; deleting the folder alone would leave it behind.
    public func signOut() async { _ = await codex(["logout"]) }

    private func codex(_ arguments: [String]) async -> Int32? {
        try? CodexAdapter.writeConfig(codexHome)
        guard let child = try? ChildProcess(executable: cli.path(percentEncoded: false), arguments: arguments, environment: environment) else { return nil }
        try? child.stdin.close()
        let deadline = Task { try await Task.sleep(for: .seconds(20)); await child.stop() }
        defer { deadline.cancel() }
        let status = await child.waitForExit()
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
    }

    private var environment: [String: String] {
        ["HOME": FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false), "CODEX_HOME": codexHome.path(percentEncoded: false),
         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    }

    public func run(progress: @escaping SignInProgress, timeout: Duration = .seconds(600)) async throws {
        try CodexAdapter.writeConfig(codexHome)
        let child = try ChildProcess(executable: cli.path(percentEncoded: false), arguments: ["login"], environment: environment)
        try? child.stdin.close()
        progress(.waiting("Waiting for ChatGPT in your browser…"))
        let watcher = Task {
            for stream in [child.stdout, child.stderr] {
                Task {
                    for try await line in LineStream.lines(from: stream) {
                        let text = String(decoding: line, as: UTF8.self)
                        if let range = text.range(of: #"https://\S+"#, options: .regularExpression), let url = URL(string: String(text[range])),
                           SignInPage.belongs(url, to: SignInPage.openAI) {
                            progress(.browserOpened(url))
                        }
                    }
                }
            }
        }
        let deadline = Task { try await Task.sleep(for: timeout); await child.stop() }
        let status = await withTaskCancellationHandler { await child.waitForExit() } onCancel: { killpg(child.pid, SIGTERM) }
        deadline.cancel()
        watcher.cancel()
        if Task.isCancelled { throw SignInError.cancelled }
        guard status == 0, await isSignedIn() else { throw SignInError.provider("Codex didn't finish signing in") }
        progress(.signedIn("ChatGPT (Codex)"))
    }
}
