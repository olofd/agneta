// Signs a ChatGPT account in for the Codex engine with the user's own
// `codex login`, into the account's own CODEX_HOME (Codex keeps its sign-in
// in auth.json there and refreshes it itself). Separate from Agneta's own
// ChatGPT sign-in, so two programs never refresh the same login.
import Foundation

public struct CodexSignIn: Sendable {
    public let cli: URL
    public let codexHome: URL

    public init(cli: URL, codexHome: URL) {
        self.cli = cli
        self.codexHome = codexHome
    }

    public var isSignedIn: Bool { FileManager.default.fileExists(atPath: codexHome.appending(path: "auth.json").path(percentEncoded: false)) }

    public func run(progress: @escaping SignInProgress, timeout: Duration = .seconds(600)) async throws {
        try CodexAdapter.writeConfig(codexHome)
        let child = try ChildProcess(executable: cli.path(percentEncoded: false), arguments: ["login"], environment: [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false), "CODEX_HOME": codexHome.path(percentEncoded: false),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
        ])
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
        guard status == 0, isSignedIn else { throw SignInError.provider("Codex didn't finish signing in") }
        progress(.signedIn("ChatGPT (Codex)"))
    }
}
