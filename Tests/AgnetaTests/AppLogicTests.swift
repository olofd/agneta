import AgnetaKit
import Foundation
import Testing
@testable import Agneta

/// Apps asking for access: one shown at a time, each answered once, in the app's provider order.
@MainActor @Suite struct ApprovalsTests {
    final class Window {
        var shown: [UUID] = []
        var closed = 0
    }

    func desk(_ window: Window) -> Approvals {
        let approvals = Approvals()
        approvals.present = { window.shown.append($0) }
        approvals.dismiss = { window.closed += 1 }
        approvals.order = { ["a", "b", "c"] }
        approvals.allowance = { $0 == ["goose", "opencode"] ? .all : .only($0) }
        return approvals
    }

    @Test func answersInOrderOneAtATime() async throws {
        let window = Window(), approvals = desk(window)
        let first = Router.PairingRequest(app: "First"), second = Router.PairingRequest(app: "Second")
        async let firstAnswer = approvals.ask(first, allowed: ["a"], engines: ["goose", "opencode"])
        async let secondAnswer = approvals.ask(second, allowed: ["a"], engines: ["goose", "opencode"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(window.shown == [first.id] && approvals.current?.app == "First")

        // The window's ticks are the answer: providers in the app's order, engines as an allowance.
        approvals.current?.allowed = ["c", "a"]
        approvals.current?.engines = ["goose"]
        approvals.answer(remember: true)
        let answered = await firstAnswer
        #expect(answered == Router.PairingAnswer(accounts: ["a", "c"], engines: .only(["goose"]), remember: true))
        try await Task.sleep(for: .milliseconds(50))
        #expect(window.closed == 1 && window.shown == [first.id, second.id] && approvals.current?.app == "Second")

        approvals.answer(remember: nil) // Don't Allow
        let refused = await secondAnswer
        #expect(refused == nil)
        #expect(approvals.current == nil)
    }

    /// A provider connected while an app waits with none ticked gets ticked; one with a choice made is left alone.
    @Test func aProviderConnectedMeanwhileIsTicked() async throws {
        let window = Window(), approvals = desk(window)
        async let answer = approvals.ask(Router.PairingRequest(app: "Early"), allowed: [], engines: ["goose", "opencode"])
        try await Task.sleep(for: .milliseconds(50))
        approvals.providerAdded("b")
        approvals.providerAdded("c")
        #expect(approvals.current?.allowed == ["b"])
        approvals.answer(remember: false)
        let answered = await answer
        #expect(answered == Router.PairingAnswer(accounts: ["b"], engines: .all, remember: false))
    }

    /// Reset refuses everything, shown or waiting, and closes the window.
    @Test func resetRefusesAll() async throws {
        let window = Window(), approvals = desk(window)
        async let one = approvals.ask(Router.PairingRequest(app: "One"), allowed: ["a"], engines: [])
        async let two = approvals.ask(Router.PairingRequest(app: "Two"), allowed: ["a"], engines: [])
        try await Task.sleep(for: .milliseconds(50))
        approvals.refuseAll()
        let (first, second) = await (one, two)
        #expect(first == nil && second == nil)
        #expect(approvals.current == nil && window.closed == 1)
    }
}

/// Signing in, one attempt at a time: a failure is shown on its own window, and an old attempt never touches a new one.
@MainActor @Suite struct SignInFlowTests {
    func flow() -> SignInFlow {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agneta-signin-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let log = OperationalLog(folder: folder)
        return SignInFlow(library: EngineLibrary(runtimes: folder, log: log), log: log)
    }

    @Test func aFailureShowsAndAnOldAttemptIsIgnored() async throws {
        let signIn = flow()
        // An API key isn't signed in to: the flow fails at once, and says so.
        let first = signIn.start(.openAIKey, home: FileManager.default.temporaryDirectory, account: "x") { Issue.record("signed in") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(signIn.state?.failed != nil && signIn.state?.finished == false)

        // A new attempt replaces it; closing the old one's window then changes nothing.
        let second = signIn.start(.anthropicKey, home: FileManager.default.temporaryDirectory, account: "y") {}
        #expect(second != first && signIn.state?.kind == .anthropicKey)
        signIn.windowClosed(first)
        #expect(signIn.state != nil)
        signIn.windowClosed(second)
        #expect(signIn.state == nil)
    }
}

/// The engine library's answers the windows rely on, with every engine present (the showcase's engines).
@MainActor @Suite struct EngineLibraryTests {
    func library() -> EngineLibrary {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agneta-library-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let library = EngineLibrary(runtimes: folder, log: OperationalLog(folder: folder))
        library.useSample()
        return library
    }

    @Test func allowancesAndReasons() {
        let library = library()
        let every = Set(library.catalog.entries.keys)
        #expect(library.allowance(every) == .all && library.ids(.all) == every)
        #expect(library.allowance(["goose"]) == .only(["goose"]))
        let chatGPT = AccountRecord(kind: .chatGPT, label: "ChatGPT")
        #expect(library.cantRun(chatGPT, engines: every) == nil)
        #expect(library.cantRun(chatGPT, engines: ["goose"]) == "ChatGPT can't run on any engine ticked here")
        #expect(library.engines(for: .claude).map(\.id) == ["claude-code", "goose"])
        #expect(library.all.map(\.id) == ["goose", "opencode", "claude-code", "codex"])
    }
}
