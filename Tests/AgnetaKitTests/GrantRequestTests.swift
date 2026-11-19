// An app asks for exactly what it needs: it finds out what Agneta offers before pairing (`agneta/catalog`), asks Agneta
// to help connect a provider when there's none (`agneta/setup`), names the providers, engines and mode it wants when
// it pairs, and hears what of that it didn't get (`unmet`). Ports 4771x.
import Foundation
import Testing
@testable import AgnetaKit

extension RouterContractTests {
    /// Before pairing, an app sees Agneta's offer: every provider kind, whether one is connected, each kind's engines
    /// and the modes they can provide, and the engines here. Never the user's accounts themselves.
    @Test func anUnpairedAppSeesWhatAgnetaOffers() async throws {
        let stack = try await Stack.start(port: 47710)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        let catalog = try await app.request("agneta/catalog", [:])
        #expect(catalog["connected"] == true)
        let providers = catalog["providers"]?.arrayValue ?? []
        #expect(providers.compactMap { $0["kind"]?.stringValue } == AccountKind.allCases.map(\.rawValue))
        let claude = try #require(providers.first { $0["kind"] == "claude" })
        #expect(claude["connected"] == true && claude["name"] == "Claude plan")
        let goose = try #require(claude["engines"]?.arrayValue?.first { $0["id"] == "goose" })
        #expect(goose["sandboxLevels"] == ["developer"] && goose["uncontained"] == true)
        #expect(providers.first { $0["kind"] == "chatgpt" }?["connected"] == false)
        #expect(catalog["engines"]?.arrayValue?.contains { $0["id"] == "goose" && $0["state"] == "ready" } == true)
        // Nothing that names the user's accounts.
        let text = String(decoding: try JSONEncoder().encode(catalog), as: UTF8.self)
        #expect(!text.contains("\"label\"") && !text.contains("brokered") && !text.contains("native"), "\(text)")
    }

    /// An app with nothing to ask for asks Agneta to help the user connect a provider; it hears when one is.
    @Test func anAppAsksAgnetaToSetUpAProvider() async throws {
        let seen = Noted()
        let stack = try await Stack.start(port: 47711)
        defer { stack.stop() }
        await stack.router.observe { event in if case .setupRequested(let app, let kind) = event { seen.add("\(app) \(kind?.rawValue ?? "any")") } }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        #expect(try await app.request("agneta/setup", ["name": "Example App", "kind": "chatgpt"])["shown"] == true)
        await #expect(throws: RPCError.self) { _ = try await app.request("agneta/setup", ["kind": "gemini"]) }
        #expect(seen.items == ["Example App chatgpt"])
        // A provider connected meanwhile reaches the app as Agneta's new offer.
        _ = try await app.request("agneta/catalog", [:])
        await stack.router.add(account: "plan", label: "ChatGPT", kind: .chatGPT, billing: "subscription")
        for _ in 0..<40 where app.notifications("agneta/catalogChanged").isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        let changed = try #require(app.notifications("agneta/catalogChanged").last?["catalog"])
        #expect(changed["providers"]?.arrayValue?.first { $0["kind"] == "chatgpt" }?["connected"] == true)
    }

    /// What an app names when it pairs reaches the approval window, and the reply says what of it wasn't given.
    @Test func aPairingAskIsNarrowedAndAnsweredHonestly() async throws {
        let asked = Noted()
        let stack = try await Stack.start(port: 47712, approve: { request in
            asked.add("\(request.providers?.map(\.rawValue) ?? []) \(request.engines ?? []) \(request.sandboxAsked?.rawValue ?? "any")")
            return Router.PairingAnswer(accounts: ["native"], engines: .only(["goose"]), remember: true, sandbox: .developer)
        })
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        let paired = try await app.request("agneta/pair", ["name": "Narrow", "scope": ["tools": "workspace", "providers": ["claude", "chatgpt"],
                                                                                       "engines": ["goose"], "sandbox": "contained"]])
        #expect(asked.items == ["[\"claude\", \"chatgpt\"] [\"goose\"] contained"])
        let unmet = paired["unmet"]?.arrayValue ?? []
        // ChatGPT isn't connected; Goose can't keep a Claude plan's tasks contained.
        #expect(unmet.contains { $0["provider"] == "chatgpt" && $0["reason"]?.stringValue?.contains("not connected") == true }, "\(unmet)")
        #expect(unmet.contains { $0["provider"] == "claude" && $0["sandbox"] == "contained" }, "\(unmet)")
        #expect(paired["access"]?["providers"]?.arrayValue?.count == 1)
    }

    /// A prompt running when its task is stopped is answered as cancelled, even when the engine never answers it.
    @Test func aStoppedTasksPromptIsAnsweredAsCancelled() async throws {
        let stack = try await Stack.start(port: 47713)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Stopper")
        let session = try await stack.session(app, account: "brokered")
        await stack.engines.wedge()
        let prompt = Task { try await app.prompt(session, "hello") }
        try await Task.sleep(for: .milliseconds(300))
        await stack.router.stop(session)
        let answered = Task { try await prompt.value }
        let deadline = Task { try await Task.sleep(for: .seconds(10)); answered.cancel() }
        let result = try await answered.value
        deadline.cancel()
        #expect(result["stopReason"] == "cancelled", "\(result)")
    }

    /// "all" asks for everything; unknown names are refused, with the ones there are.
    @Test func aScopeNamesKnownProvidersAndEnginesOrAll() throws {
        let context = PolicyContext(userHome: FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [])
        let known: Set<String> = ["claude-code", "codex", "goose", "opencode"]
        let all = try GrantScope.requested(["providers": "all", "engines": "all", "sandbox": "any"], context: context, known: known)
        #expect(all.providers == AccountKind.allCases && all.engines == known.sorted() && all.sandbox == nil)
        let narrow = try GrantScope.requested(["providers": ["claude", "claude"], "engines": ["claude-code"], "sandbox": "contained"], context: context, known: known)
        #expect(narrow.providers == [.claude] && narrow.engines == ["claude-code"] && narrow.sandbox == .contained)
        #expect(try GrantScope.requested(["tools": "read"], context: context, known: known).providers == nil)
        for bad: JSONValue in [["providers": ["gemini"]], ["engines": ["cursor"]], ["providers": []], ["providers": "some"], ["sandbox": "everything"]] {
            #expect(throws: PolicyRejection.self, "\(bad)") { _ = try GrantScope.requested(bad, context: context, known: known) }
        }
    }
}

/// What a test saw, from any thread.
final class Noted: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ item: String) { lock.withLock { list.append(item) } }
    var items: [String] { lock.withLock { list } }
}
