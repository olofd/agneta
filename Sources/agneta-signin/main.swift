// Sign-in driver: runs Agneta's own sign-in for one subscription and shows
// each step, as the app's sign-in sheet does. Not shipped.
//   agneta-signin claude|codex --home <data folder>/Accounts/<id> [--no-browser] [--raw]
// The Claude route's adapter goes where the app keeps runtimes: <data folder>/Runtimes.
import AgnetaKit
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
guard let route = args.first else { print("usage: agneta-signin claude|codex --home <data folder>/Accounts/<id> [--no-browser] [--raw]"); exit(2) }
args.removeFirst()
var home = "", browse = true, raw = false
while !args.isEmpty {
    let flag = args.removeFirst()
    switch flag {
    case "--home": home = args.isEmpty ? "" : args.removeFirst()
    case "--no-browser": browse = false
    case "--raw": raw = true
    default: break
    }
}
guard !home.isEmpty else { print("agneta-signin needs --home <data folder>/Accounts/<id>"); exit(2) }
let account = URL(filePath: home, directoryHint: .isDirectory)
@Sendable func say(_ text: String) { print(text); fflush(stdout) }

let openBrowser = browse
let progress: SignInProgress = { step in
    switch step {
    case .openBrowser(let url):
        say("→ browser: \(url.absoluteString)")
        if openBrowser { _ = try? ChildProcess(executable: "/usr/bin/open", arguments: [url.absoluteString], environment: [:]) }
    case .confirmCode(let code, let page, let expires):
        say("→ code \(code) at \(page.absoluteString) (valid \(expires / 60) min)")
        if openBrowser { _ = try? ChildProcess(executable: "/usr/bin/open", arguments: [page.absoluteString], environment: [:]) }
    case .browserOpened(let url): say("→ opened by Claude: \(url.absoluteString)")
    case .pasteCode(let text): say("→ \(text) Type it here and press Return.")
    case .waiting(let text): say("… \(text)")
    case .signedIn(let who): say("✓ signed in: \(who)")
    }
}

let showRaw = raw

func runSignIn() async throws {
    switch route {
    case "claude":
        let repo = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let installer = RuntimeInstaller(lockFile: repo.appending(path: "Engines/runtimes.lock"), runtimes: AgnetaStore(root: account.deletingLastPathComponent().deletingLastPathComponent()).runtimesFolder)
        let adapter = try await installer.install("claude-agent-acp", progress: progress)
        say("adapter: \(adapter.path(percentEncoded: false))")
        var echo: (@Sendable (String) -> Void)?
        if showRaw { echo = { chunk in FileHandle.standardError.write(Data(chunk.utf8)) } }
        guard let cli = CLILocator.claudeCode().first else { throw SignInError.provider("Claude Code isn't installed") }
        say("Claude Code: \(cli.label)")
        let claude = ClaudeCodeSignIn(cli: cli.path, configDirectory: account.appending(path: "claude", directoryHint: .isDirectory))
        if try await claude.isSignedIn() { say("✓ already signed in to Claude"); return }
        try await claude.run(progress: progress, code: { readLine() }, output: echo)
    case "codex":
        // The Codex engine's own ChatGPT sign-in, with the user's Codex, into <account>/codex.
        guard let cli = CLILocator.codex().first(where: \.supported) else {
            throw SignInError.provider("No Codex \(CLILocator.codexMinimum) or later is installed")
        }
        let codex = CodexSignIn(cli: cli.path, codexHome: CodexAdapter.codexHome(account: account))
        if await codex.isSignedIn() { say("✓ already signed in for Codex"); return }
        try await codex.run(progress: progress)
    default:
        throw SignInError.provider("unknown route \(route)")
    }
}

let work = Task {
    do {
        try await runSignIn()
        exit(0)
    } catch {
        say("✗ \(error)")
        exit(1)
    }
}
// Ctrl-C or TERM cancels the sign-in, which also ends a running login.
signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
let stops = [SIGINT, SIGTERM].map { DispatchSource.makeSignalSource(signal: $0, queue: .main) }
for source in stops {
    source.setEventHandler { work.cancel() }
    source.resume()
}
dispatchMain()
