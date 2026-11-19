// The sandbox through the router, over the wire: what a task gets by default, when the app asks for less, when it
// asks for more than its grant, on an engine that can't contain its tools, which engine a task gets, what the access
// report says, and that narrowing an app's grant stops what no longer fits.
import Foundation
import Testing
@testable import AgnetaKit

extension RouterContractTests {
    /// The reply's `sandbox` for a session, or the refusal's field and reason.
    static func sandbox(_ stack: Stack, _ app: AppClient, account: String, tools: String, ask: String? = nil) async -> (level: String?, refused: String?) {
        do {
            var policy: JSONValue = ["tools": .string(tools), "approval": "never-ask"]
            if let ask { policy = policy.setting("sandbox", to: .string(ask)) }
            let result = try await app.request("session/new", ["cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                                                               "_meta": [SessionPolicy.key: policy, "agneta": ["account": .string(account)]]])
            return (result["_meta"]?["agneta"]?["sandbox"]?.stringValue, nil)
        } catch let error as RPCError {
            return (nil, "\(error.data?["agneta"]?["unenforceable"]?.arrayValue?.first?.stringValue ?? "?"): \(error.data?["agneta"]?["reason"]?.stringValue ?? error.message)")
        } catch {
            return (nil, "\(error)")
        }
    }

    /// Full power by default; an app may ask for less; fewer tools than workspace stay contained.
    @Test func aGrantsDefaultIsFullPowerAndAnAppMayAskForLess() async throws {
        let stack = try await Stack.start(port: 47700)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Sandbox")
        #expect(await Self.sandbox(stack, app, account: "brokered", tools: "workspace").level == "developer")
        #expect(await Self.sandbox(stack, app, account: "brokered", tools: "workspace", ask: "contained").level == "contained")
        #expect(await Self.sandbox(stack, app, account: "brokered", tools: "workspace", ask: "developer").level == "developer")
        let read = await Self.sandbox(stack, app, account: "brokered", tools: "read")
        #expect(read.level == "contained", "\(read)")
        #expect(await Self.sandbox(stack, app, account: "brokered", tools: "app-only").level == "contained")
    }

    /// The user chose Contained for this app: its tasks get it, and asking for more is refused with why.
    @Test func anAppNeverGetsMoreThanItsGrant() async throws {
        let stack = try await Stack.start(port: 47705, approve: { _ in Router.PairingAnswer(accounts: ["brokered", "native"], remember: true, sandbox: .contained) })
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Sandbox")
        #expect(await Self.sandbox(stack, app, account: "brokered", tools: "workspace").level == "contained")
        #expect(await Self.sandbox(stack, app, account: "brokered", tools: "workspace", ask: "contained").level == "contained")
        let more = await Self.sandbox(stack, app, account: "brokered", tools: "workspace", ask: "developer")
        #expect(more.level == nil && more.refused?.hasPrefix("sandbox: ") == true && more.refused?.contains("less, not more") == true, "\(more)")
    }

    /// Goose on a Claude plan can't contain its tools: it runs with full power when nobody asked for less, reported as
    /// such whatever the tools, and is refused, with why, when the app or the user asked for Contained.
    @Test func anEngineThatCantContainItsToolsIsHonestAboutIt() async throws {
        let open = try await Stack.start(port: 47701)
        defer { open.stop() }
        let app = AppClient(port: open.port)
        defer { app.close() }
        try await app.pairAndInitialize("Sandbox")
        #expect(await Self.sandbox(open, app, account: "native", tools: "workspace").level == "developer")
        #expect(await Self.sandbox(open, app, account: "native", tools: "app-only").level == "developer")
        let asked = await Self.sandbox(open, app, account: "native", tools: "workspace", ask: "contained")
        #expect(asked.refused?.contains("Goose") == true && asked.refused?.contains("choose another engine") == true, "\(asked)")

        let closed = try await Stack.start(port: 47702, approve: { _ in Router.PairingAnswer(accounts: ["brokered", "native"], remember: true, sandbox: .contained) })
        defer { closed.stop() }
        let contained = AppClient(port: closed.port)
        defer { contained.close() }
        try await contained.pairAndInitialize("Sandbox")
        #expect(await Self.sandbox(closed, contained, account: "native", tools: "app-only").refused?.contains("Goose") == true)
        #expect(await Self.sandbox(closed, contained, account: "brokered", tools: "workspace").level == "contained")
    }

    /// An app granted fewer tools than the workspace was never offered the choice (the dialog shows it only for
    /// workspace tools), so its tasks stay contained: an engine that can't contain them is refused, with why.
    @Test func anAppWithFewerToolsStaysContained() async throws {
        let stack = try await Stack.start(port: 47706)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Sandbox", scope: ["tools": "read", "folders": [.string(stack.root.appending(path: "work").realFileURL.path(percentEncoded: false))]])
        let initialize = try await app.request("initialize", ["protocolVersion": 1, "_meta": ["agneta": ["token": .string(app.token ?? "")]]])
        #expect(initialize["_meta"]?["agneta"]?["access"]?["scope"]?["sandbox"] == "contained")
        let read = await Self.sandbox(stack, app, account: "brokered", tools: "read")
        #expect(read.level == "contained", "\(read)")
        let more = await Self.sandbox(stack, app, account: "brokered", tools: "read", ask: "developer")
        #expect(more.refused?.contains("workspace tools") == true, "\(more)")
        let goose = await Self.sandbox(stack, app, account: "native", tools: "app-only")
        #expect(goose.level == nil && goose.refused?.contains("Goose") == true, "\(goose)")
    }

    /// What an app sees: its grant's mode, and the levels each engine can provide on each provider.
    @Test func theAccessReportSaysWhatEachEngineCanProvide() async throws {
        let stack = try await Stack.start(port: 47703)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Sandbox")
        let initialize = try await app.request("initialize", ["protocolVersion": 1, "_meta": ["agneta": ["token": .string(app.token ?? "")]]])
        let access = try #require(initialize["_meta"]?["agneta"]?["access"])
        #expect(access["scope"]?["sandbox"] == "developer")
        let providers = access["providers"]?.arrayValue ?? []
        let claude = try #require(providers.first { $0["id"] == "native" })
        #expect(claude["sandboxLevels"]?["goose"] == ["developer"] && claude["uncontained"] == ["goose"])
        let key = try #require(providers.first { $0["id"] == "brokered" })
        #expect(key["sandboxLevels"]?["goose"] == ["contained", "developer"] && key["uncontained"] == [])
    }

    /// Narrowing an app to Contained in Settings → Apps stops its tasks that run with more; the rest keep running.
    @Test func narrowingAGrantStopsWhatNoLongerFits() async throws {
        let stack = try await Stack.start(port: 47704)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Sandbox")
        let free = try await stack.session(app, account: "brokered", tools: "workspace")
        let kept = try await stack.session(app, account: "brokered", tools: "workspace", sandbox: "contained")
        let grant = try #require(await stack.router.tokens.values.first)
        try await stack.router.setAccess(grant: grant.id, accounts: grant.accounts, engines: grant.engines, sandbox: .contained)
        try await Task.sleep(for: .milliseconds(300))
        let open = Set(await stack.router.sessions.keys)
        #expect(!open.contains(free) && open.contains(kept), "\(open)")
    }
}

/// Which engine a task gets when it names none: one that can provide the mode it wants, where the app may use one.
@Test func aTaskThatNamesNoEngineGetsOneThatCanProvideItsMode() {
    let cli = InstalledCLI(path: URL(filePath: "/usr/bin/false"), version: "1", source: "path")
    let catalog = EngineCatalog(ready: [ClaudeCodeAdapter(executable: URL(filePath: "/usr/bin/false"), cli: cli), GooseAdapter(executable: URL(filePath: "/usr/bin/false"))],
                                defaults: ProviderEngines(selected: [.claude: "goose"]))
    #expect(Access.defaultEngine(for: .claude, allowed: .all, catalog: catalog, sandbox: .developer) == "goose")
    #expect(Access.defaultEngine(for: .claude, allowed: .all, catalog: catalog, sandbox: .contained) == "claude-code")
    #expect(Access.defaultEngine(for: .claude, allowed: .all, catalog: catalog) == "goose")
    // Only Goose allowed: it's still the engine, and the resolver refuses a contained task on it with why.
    #expect(Access.defaultEngine(for: .claude, allowed: .only(["goose"]), catalog: catalog, sandbox: .contained) == "goose")
}
