// Apps asking for access, as the approval window shows them: one at a time, each answered exactly once (by the user,
// by closing its window, by its app going away, after five minutes, or by Reset), in AgnetaKit's ApprovalQueue.
import AgnetaKit
import Foundation
import Observation

@MainActor @Observable
final class Approvals {
    /// An app asking, with what the user has ticked so far.
    struct Request: Identifiable, Sendable {
        /// The router's pairing request id.
        let id: UUID
        var app: String
        var identifier: String?
        var verified: Bool
        var code: String
        /// The providers ticked: one to start with, which the user adds to deliberately.
        var allowed: Set<String>
        /// The engines ticked (Advanced): every one to start with, since the app picks per task.
        var engines: Set<String>
        /// What the app asks to do: the most built-in tools, and folders of the user's beyond its own workspace.
        var tools: SessionPolicy.Tools = .appOnly
        var folders: [URL] = []
        /// The app has remembered access already, which Always Allow replaces (Router.sameApp).
        var replaces = false
        /// The most its tasks may do: where the app's own ask starts it (full power unless it asks for less).
        var sandbox: Sandbox = .default
        /// What the app asked for, which narrows the window: the provider kinds it named (nil: the user picks among
        /// all), whether it named its engines, and whether it asked for contained (then fixed: it asked for no more).
        var kinds: [AccountKind]?
        var namedEngines = false
        var sandboxFixed = false
    }

    /// A request nobody answers is refused after this long: a window nobody saw shouldn't keep its app waiting.
    static let timeout: Duration = .seconds(300)

    /// The request on screen; the window's edits change what it allows.
    var current: Request? {
        get { queue.current }
        set { queue.current = newValue }
    }

    private var queue = ApprovalQueue<Request, Router.PairingAnswer>()
    /// Shows and closes the approval window (WindowPresenter), set by the app.
    var present: @MainActor (UUID) -> Void = { _ in }
    var dismiss: @MainActor () -> Void = {}
    /// The providers in the order the app lists them, so "the first allowed" (a session's default) stays stable.
    var order: @MainActor () -> [String] = { [] }
    /// What a set of ticked engines allows (EngineLibrary.allowance).
    var allowance: @MainActor (Set<String>) -> EngineAllowance = { _ in .all }

    /// Asks the user, and waits for the answer: nil for Don't Allow.
    func ask(_ pairing: Router.PairingRequest, allowed: Set<String>, engines: Set<String>, replaces: Bool = false) async -> Router.PairingAnswer? {
        await withCheckedContinuation { continuation in
            let request = Request(id: pairing.id, app: pairing.app, identifier: pairing.peer?.identifier, verified: pairing.code == nil,
                                  code: pairing.code ?? "", allowed: allowed, engines: engines, tools: pairing.tools, folders: pairing.folders,
                                  replaces: replaces, sandbox: pairing.sandbox, kinds: pairing.providers, namedEngines: pairing.engines != nil,
                                  sandboxFixed: pairing.sandboxAsked == .contained)
            if queue.add(id: pairing.id, request, answer: { continuation.resume(returning: $0) }) { present(pairing.id) }
            _Concurrency.Task { [weak self] in
                try? await _Concurrency.Task.sleep(for: Self.timeout)
                self?.settle(pairing.id, with: nil)
            }
        }
    }

    /// The user's answer to the request on screen: nil for Don't Allow, else Allow Once (`remember` false) or Always
    /// Allow.
    func answer(remember: Bool?) {
        guard let pending = current else { return }
        let allowed = order().filter(pending.allowed.contains)
        settle(pending.id, with: remember.map {
            Router.PairingAnswer(accounts: allowed, engines: allowance(pending.engines), remember: $0, sandbox: pending.sandbox)
        })
    }

    /// Answers a request, shown or waiting; nil is Don't Allow. Answering one already answered does nothing.
    func settle(_ id: UUID, with answer: Router.PairingAnswer?) {
        guard queue.answer(id, with: answer) else { return }
        dismiss()
        if let next = current?.id {
            DispatchQueue.main.async { self.present(next) }
        }
    }

    /// A provider just connected: a request with none ticked (there was none to offer) gets it, and so does one that
    /// asked for its kind.
    func providerAdded(_ id: String, kind: AccountKind) {
        if current?.allowed.isEmpty == true || current?.kinds?.contains(kind) == true { current?.allowed.insert(id) }
    }

    /// Refuses every request (Reset).
    func refuseAll() {
        queue.refuseAll()
        dismiss()
    }

    /// The showcase's request.
    func addSample(_ request: Request) {
        _ = queue.add(id: request.id, request, answer: { _ in })
    }
}
