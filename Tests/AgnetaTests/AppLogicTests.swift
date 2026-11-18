import AgnetaKit
import CryptoKit
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

    /// What a new provider's sign-in made is undone when the attempt ends without signing in: once when it fails, once
    /// when it's cancelled or replaced, never twice.
    @Test func anAttemptThatEndsWithoutSigningInDiscardsItsFolder() async throws {
        let signIn = flow()
        var discarded: [String] = []
        _ = signIn.start(.openAIKey, home: FileManager.default.temporaryDirectory, account: "failed", discard: { discarded.append("failed") }) {}
        try await Task.sleep(for: .milliseconds(100))
        #expect(discarded == ["failed"] && signIn.state?.failed != nil)
        signIn.cancel() // closing the failed window discards nothing more
        #expect(discarded == ["failed"])

        let replaced = signIn.start(.claude, home: FileManager.default.temporaryDirectory, account: "replaced", discard: { discarded.append("replaced") }) {}
        _ = signIn.start(.anthropicKey, home: FileManager.default.temporaryDirectory, account: "next", discard: { discarded.append("next") }) {}
        #expect(discarded.prefix(2) == ["failed", "replaced"])
        signIn.windowClosed(replaced) // the replaced attempt's window: already discarded
        #expect(discarded.filter { $0 == "replaced" }.count == 1)
        signIn.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(discarded.filter { $0 == "next" }.count == 1)
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

/// The library's download decisions, with a real pinned download from a local archive: what starts by itself, what a
/// failure does to the default, and what putting a failure away means.
@MainActor @Suite struct EngineDownloadTests {
    /// A build's folders with `opencode.lock` pinning a local zip of a tiny `opencode`; `pinned: false` pins the wrong
    /// hash, so the download fails its check.
    func library(pinned: Bool = true) throws -> (EngineLibrary, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "agneta-downloads-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory).realFileURL
        let payload = root.appending(path: "payload/opencode", directoryHint: .isDirectory)
        let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let program = payload.appending(path: "opencode")
        try "#!/bin/sh\necho ok\n".write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path(percentEncoded: false))
        let zip = root.appending(path: "opencode.zip")
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", payload.path(percentEncoded: false), zip.path(percentEncoded: false)]
        try ditto.run()
        ditto.waitUntilExit()
        let digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        let sha = pinned ? digest : String(repeating: "0", count: 64)
        let asset: JSONValue = ["url": .string(zip.absoluteString), "sha256": .string(sha), "size": 100]
        try JSONCoding.encode(["engine": "opencode", "version": "1", "assets": .object([RuntimeInstaller.architecture: asset])] as JSONValue)
            .write(to: resources.appending(path: "opencode.lock"))
        let library = EngineLibrary(runtimes: root.appending(path: "Runtimes", directoryHint: .isDirectory), log: OperationalLog(folder: root),
                                    bundled: Bundled(programs: root.appending(path: "MacOS", directoryHint: .isDirectory), resources: resources))
        library.kindsInUse = { [.openAIKey] }
        library.refresh()
        return (library, root)
    }

    func state(_ library: EngineLibrary) -> String? { library.catalog.entries["opencode"]?.state.name }

    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    }

    /// A sign-in's install (Claude Code's adapter, for a Claude plan) is a download like any other while it runs, so the
    /// sign-in window and the panel show its progress; once installed it leaves no card, and installing again
    /// downloads nothing.
    @Test func aSignInsInstallIsShownAsADownload() async throws {
        let (library, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let going = Task { try await library.install("opencode") }
        // The install runs on the main actor up to its download, so one yield finds it listed; a local file arrives
        // faster than any polling.
        await Task.yield()
        #expect(library.downloads["opencode"] != nil) // its total is the pin's, until the server's own arrives
        _ = try await going.value
        #expect(library.downloads.isEmpty && state(library) == "ready")
        _ = try await library.install("opencode")
        #expect(library.downloads.isEmpty)
        let log = try String(contentsOf: root.appending(path: "agneta.jsonl"), encoding: .utf8)
        #expect(log.components(separatedBy: "\"reason\":\"sign-in\"").count == 2) // one download, not two
    }

    /// An engine nobody needs isn't fetched; choosing it as a provider's default fetches it, and it becomes ready.
    @Test func choosingADefaultDownloadsIt() async throws {
        let (library, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(state(library) == "downloadable" && library.downloads.isEmpty)
        #expect(library.engine(for: .openAIKey) == "goose")
        library.select("opencode", for: .openAIKey)
        try await waitUntil { self.state(library) == "ready" }
        #expect(state(library) == "ready" && library.downloads.isEmpty && library.engine(for: .openAIKey) == "opencode")
    }

    /// A default whose download fails: tasks run on another engine meanwhile. Put away, it isn't fetched again by
    /// itself; a task asking for it fetches it again.
    @Test func aFailedDownloadFallsBackAndStaysPutAway() async throws {
        let (library, root) = try library(pinned: false)
        defer { try? FileManager.default.removeItem(at: root) }
        library.select("opencode", for: .openAIKey)
        try await waitUntil { self.state(library) == "failed" }
        #expect(state(library) == "failed" && library.engine(for: .openAIKey) == "goose")
        #expect(library.chosenEngine(for: .openAIKey) == "opencode") // Settings still shows the choice

        library.putAway("opencode")
        try await Task.sleep(for: .milliseconds(300))
        #expect(state(library) == "downloadable" && library.downloads.isEmpty)

        library.download("opencode", reason: "task")
        try await waitUntil { self.state(library) == "failed" }
        #expect(state(library) == "failed")
    }
}
