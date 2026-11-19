// Signing in to a plan, one at a time: each provider's own login (Codex for a ChatGPT plan, Claude Code for a Claude
// plan, with the adapter its engines need), shown step by step in the sign-in window, with the code to paste when
// Claude asks for one. Cancelling, closing the window or starting another stops it; one that finishes late never
// touches a newer one's window. What happens to the account once signed in is the app's (AppModel).
import AgnetaKit
import AppKit
import Foundation
import Observation

@MainActor @Observable
final class SignInFlow {
    /// What the sign-in window shows.
    struct State {
        var kind: AccountKind
        var text: String
        var page: URL?
        var needsCode = false
        var finished = false
        var failed: String?
    }

    /// The sign-in on screen, if any.
    private(set) var state: State?
    /// Which attempt is current: a cancelled or replaced one finishing late is ignored.
    private(set) var attempt = UUID()
    private var task: _Concurrency.Task<Void, Never>?
    private var codeAnswer: CheckedContinuation<String?, Never>?
    /// Undoes what the attempt under way made (a new provider's folder) if it ends without signing in.
    private var discard: (@MainActor () -> Void)?
    private let library: EngineLibrary
    private let log: OperationalLog

    init(library: EngineLibrary, log: OperationalLog) {
        self.library = library
        self.log = log
    }

    /// Signs in with `kind`'s own login into the account folder `home`, then runs `signedIn` (which keeps the account).
    /// `discard` runs if the attempt ends any other way: cancelled, failed, closed or replaced. Returns the attempt, for
    /// the window to name.
    func start(
        _ kind: AccountKind, home: URL, account: String, discard: (@MainActor () -> Void)? = nil,
        signedIn: @escaping @MainActor () async -> Void
    ) -> UUID {
        abandon()
        let attempt = UUID()
        self.attempt = attempt
        self.discard = discard
        state = State(kind: kind, text: "Starting…")
        task = _Concurrency.Task { [weak self] in
            guard let self else { return }
            let progress: SignInProgress = { step in
                _Concurrency.Task { @MainActor in self.show(step, attempt: attempt) }
            }
            do {
                try await signIn(kind, home: home, progress: progress)
                guard self.attempt == attempt, !_Concurrency.Task.isCancelled else { return }
                log.log("signed-in", ["account": .string(account), "kind": .string(kind.rawValue)])
                self.discard = nil
                await signedIn()
                state?.finished = true
                state?.text = "\(kind.provider) is connected."
            } catch {
                if failed(error, attempt: attempt) {
                    log.error(
                        "sign-in-failed",
                        ["kind": .string(kind.rawValue), "reason": .string(String(describing: type(of: error)))])
                }
            }
        }
        return attempt
    }

    /// Each plan's own login, with the user's own program.
    private func signIn(_ kind: AccountKind, home: URL, progress: @escaping SignInProgress) async throws {
        switch kind {
        case .chatGPT:
            // A ChatGPT plan runs on the user's own Codex, signed in with Codex's own login.
            guard let cli = library.program("codex") else {
                throw SignInError.provider(
                    (library.installs["codex"] ?? []).isEmpty
                        ? "Codex isn't installed. Install Codex, then try again"
                        : "Your Codex is older than \(CLILocator.codexMinimum), which Agneta needs. Update Codex, then try again"
                )
            }
            try await CodexSignIn(cli: cli.path, codexHome: CodexAdapter.codexHome(account: home)).run(
                progress: progress)
        case .claude:
            // The user's own Claude Code signs in; the adapter its engines run it through is fetched now too.
            guard let cli = library.program("claude") else {
                throw SignInError.provider(
                    "Claude Code isn't installed. Install the Claude app or Claude Code, then try again")
            }
            _ = try await library.install("claude-code", progress: progress)
            try await ClaudeCodeSignIn(
                cli: cli.path, configDirectory: home.appending(path: "claude", directoryHint: .isDirectory)
            )
            .run(progress: progress, code: { await self.waitForCode() })
        case .openAIKey, .anthropicKey:
            throw SignInError.provider("An API key is added, not signed in to")
        }
    }

    /// Shows a sign-in's failure on its own window; a cancelled or replaced one shows nothing. True when shown.
    private func failed(_ error: Error, attempt: UUID) -> Bool {
        guard self.attempt == attempt else { return false }
        discard?()
        discard = nil
        if error is CancellationError || (error as? SignInError) == .cancelled {
            state = nil
            return false
        }
        state?.failed = "\(error)"
        return true
    }

    private func show(_ step: SignInStep, attempt: UUID) {
        guard state != nil, self.attempt == attempt else { return }
        switch step {
        case .openBrowser(let url):
            state?.page = url
            NSWorkspace.shared.open(url)
        case .browserOpened(let url):
            state?.page = url
        case .confirmCode(let code, let page, _):
            state?.page = page
            state?.text = "Confirm the code \(code) on the page that opened."
            NSWorkspace.shared.open(page)
        case .pasteCode(let text):
            state?.needsCode = true
            state?.text = text
        case .waiting(let text):
            state?.text = text
        case .signedIn:
            break
        }
    }

    private func waitForCode() async -> String? {
        await withCheckedContinuation { codeAnswer = $0 }
    }

    /// The code the user pasted.
    func submit(_ code: String) {
        state?.needsCode = false
        state?.text = "Checking the code…"
        codeAnswer?.resume(returning: code)
        codeAnswer = nil
    }

    /// Cancel or Done: stops it and closes its window.
    func cancel() {
        abandon()
        state = nil
        WindowPresenter.shared.closeSignIn()
    }

    /// The window closed: closing it is cancelling, unless that sign-in finished or another replaced it.
    func windowClosed(_ attempt: UUID) {
        guard self.attempt == attempt, state?.finished != true else { return }
        abandon()
        state = nil
    }

    /// Stops the sign-in under way: its code prompt answered (nobody will type it), its task cancelled, its attempt
    /// retired.
    func abandon() {
        codeAnswer?.resume(returning: nil)
        codeAnswer = nil
        task?.cancel()
        task = nil
        attempt = UUID()
        discard?()
        discard = nil
    }

    /// Reset: nothing in progress, nothing shown.
    func clear() {
        abandon()
        state = nil
    }

    /// The showcase's sign-in.
    func showSample(_ sample: State) { state = sample }
}
