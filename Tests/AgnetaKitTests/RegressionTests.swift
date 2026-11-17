// Regression tests for security and correctness faults found in review, one per fault.
import Foundation
import Testing
@testable import AgnetaKit

@Suite struct RegressionTests {
    let context = PolicyContext(userHome: FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/com.objectivecoder.agneta"),
    ])
    var work: String { FileManager.default.temporaryDirectory.path(percentEncoded: false) }
    func parse(_ value: JSONValue, cwd: String? = nil) throws -> SessionPolicy { try SessionPolicy.parse(value, cwd: cwd ?? work, context: context) }

    /// An id outside Int64 is malformed, not a crash.
    @Test func hugeNumericIdsAreMalformedNotFatal() throws {
        #expect(RPCID(.double(1e300)) == nil)
        #expect(RPCID(.double(-9.3e18)) == nil)
        #expect(RPCID(.double(42)) == .int(42))
        #expect(throws: (any Error).self) { _ = try RPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":1e300,"method":"x"}"#.utf8)) }
    }

    /// A negative or absurd Content-Length is a bad request, not a crash.
    @Test func badContentLengthsAreRefused() {
        for length in ["-1", "abc", "99999999999"] {
            let request = LocalHTTPServer.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n{}".utf8))
            #expect(request?.method == "INVALID", "\(length)")
        }
        #expect(LocalHTTPServer.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8))?.body == Data("{}".utf8))
    }

    /// Folders that contain protected places are refused, not only folders inside them.
    @Test func foldersContainingProtectedPlacesAreRefused() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        #expect(throws: PolicyRejection.self) { _ = try parse([:], cwd: "/Users") }
        #expect(throws: PolicyRejection.self) { _ = try parse(["readable": .array([.string(home + "Library")])]) }
        #expect(throws: PolicyRejection.self) { _ = try parse(["writable": .array([.string(home + "Library/LaunchAgents")])]) }
        #expect(throws: PolicyRejection.self) { _ = try parse(["readable": .array([.string(home + ".ssh")])]) }
        #expect(throws: PolicyRejection.self) { _ = try parse(["readable": .array([.string(home + "Library/Application Support")])]) } // contains Agneta's data
        _ = try parse(["readable": .array([.string(home + "Music")])])
    }

    /// No hosts is no network; malformed or unknown policy is refused.
    @Test func policiesAreParsedStrictly() throws {
        #expect(try parse(["network": ["allow": []]]).network == .none)
        #expect(throws: PolicyRejection.self) { _ = try parse(["network": ["allow": [1]]]) }
        #expect(throws: PolicyRejection.self) { _ = try parse(["tool": "workspace"]) } // a typo isn't ignored
        #expect(throws: PolicyRejection.self) { _ = try parse(["limits": ["maxCostUSD": "5"]]) }
        #expect(throws: PolicyRejection.self) { _ = try parse(["limits": ["maxCostUSD": 0]]) }
        #expect(throws: PolicyRejection.self) { _ = try parse(["limits": ["maxTokens": 5]]) }
        #expect(try parse(["limits": ["maxCostUSD": 2.5, "maxTurns": 10]]).limits.maxCostUSD == 2.5)
    }

    /// Only loopback HTTP tool servers.
    @Test func onlyLoopbackHTTPToolServers() {
        #expect(Router.refuseServers([["type": "stdio", "name": "x", "command": "/bin/sh", "args": []]]) != nil)
        #expect(Router.refuseServers([["name": "x", "command": "/bin/sh"]]) != nil)
        #expect(Router.refuseServers([["type": "http", "name": "x", "url": "https://example.com/mcp"]]) != nil)
        #expect(Router.refuseServers([["type": "sse", "name": "x", "url": "http://127.0.0.1:1/sse"]]) != nil)
        #expect(Router.refuseServers([["type": "http", "name": "app", "url": "http://127.0.0.1:47471/mcp", "headers": []]]) == nil)
    }

    /// Profiles deny LaunchServices, AppleEvents and other processes for engines too; the Keychain only
    /// when declared; exceptions come after denies (the last matching rule wins).
    @Test func profilesCloseTheEscapes() {
        var engine = SandboxProfile(kind: .engine, writable: [], denied: [URL(filePath: "/tmp/acct/projects")])
        engine.exceptions = [URL(filePath: "/tmp/acct/projects/-work")]
        let text = engine.render()
        for rule in ["(deny lsopen)", "com.apple.coreservices.launchservicesd", "(deny appleevent-send)", "(deny signal (require-not (target same-sandbox)))"] {
            #expect(text.contains(rule), "\(rule)")
        }
        let deny = text.range(of: "(deny file-read* file-write* (subpath \"/private/tmp/acct/projects\"))")
        let allow = text.range(of: "(allow file-read* file-write* (subpath \"/private/tmp/acct/projects/-work\"))")
        #expect(deny != nil && allow != nil && deny!.lowerBound < allow!.lowerBound)
        #expect(!text.contains("com.apple.securityd")) // engines need it for TLS
        let tool = SandboxProfile(kind: .tool, writable: [], denied: []).render()
        #expect(tool.contains("com.apple.securityd") && tool.contains("(deny lsopen)"))
    }

    /// Paging completes exactly at the end, and a resumed trace's old `end` doesn't end it.
    @Test func tracePagingCompletesCorrectly() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agneta-paging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let traces = Traces(folder: folder)
        var session = traces.open(task: "t", lease: "l", engineSession: "e")
        for n in 0..<4 { session.writer.record("event", ["kind": "x", "n": .int(Int64(n))]) }
        session.writer.record("end", [:]) // seq 5
        traces.close(task: "t")
        // The end record is the last one on a full page: complete now, and nothing loops afterwards.
        let page = try #require(traces.read(task: "t", after: 0, types: Traces.defaultTypes, limit: 5))
        #expect(page.records.count == 5 && page.complete && page.next == nil)
        let first = try #require(traces.read(task: "t", after: 0, types: Traces.defaultTypes, limit: 4))
        #expect(!first.complete && first.next == 4)
        let rest = try #require(traces.read(task: "t", after: 4, types: Traces.defaultTypes, limit: 4))
        #expect(rest.records.count == 1 && rest.complete)
        // Resumed: records after the old end mean it's running again.
        session = traces.open(task: "t", lease: "l", engineSession: "e")
        session.writer.record("lifecycle", ["event": "resumed"])
        session.writer.flush()
        let resumed = try #require(traces.read(task: "t", after: 0, types: Traces.defaultTypes, limit: 100))
        #expect(!resumed.complete && resumed.next == 6)
        traces.close(task: "t")
    }
}

@Suite struct ConcurrencyRegressionTests {
    /// A resumed trace's ledger starts after what's already recorded.
    @Test func resumedLedgersDontRecountEarlierCalls() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "agneta-resume-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appending(path: "sessions/2026/11/17", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "rollout-x-thread.jsonl")
        try (#"{"type":"token_usage_record","payload":{"turn_id":"t","response_id":"old","usage":{"input_tokens":10,"output_tokens":1}}}"# + "\n").write(to: file, atomically: true, encoding: .utf8)
        let traces = Traces(folder: home.appending(path: "Traces", directoryHint: .isDirectory))
        let session = traces.open(task: "t", lease: "l", engineSession: "thread")
        session.follow(CodexRolloutLedger(codexHome: home, session: "thread"), resumed: true)
        session.turnStarted(prompt: nil)
        #expect(session.progress.turnModelCalls == 0)
        traces.close(task: "t")
    }

    /// A cost limit is refused on engines that can't report cost.
    @Test func costLimitsNeedAnEngineThatReportsCost() {
        #expect(!ClaudeCodeAdapter(executable: URL(filePath: "/x"), cli: InstalledCLI(path: URL(filePath: "/x"), version: nil, source: "path")).capabilities.reportsCost)
        #expect(GooseAdapter(executable: URL(filePath: "/x")).capabilities.reportsCost)
    }

    /// Closing waits at most the bound.
    @Test func boundedWorkGivesUp() async {
        let started = ContinuousClock.now
        await Router.bounded(seconds: 0.2) { try? await Task.sleep(for: .seconds(30)) }
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}

/// A Codex older than the app-server schema the pinned codex-acp speaks isn't used: it's marked, and one whose version
/// couldn't be read counts as too old.
@Test func aCodexOlderThanTheMinimumIsMarked() {
    func codex(_ version: String?) -> InstalledCLI {
        InstalledCLI(path: URL(filePath: "/usr/local/bin/codex"), version: version, source: "path", minimum: CLILocator.codexMinimum)
    }
    #expect(codex("0.166.0").supported && codex("0.167.2").supported && codex("1.0.0").supported)
    #expect(!codex("0.99.1").supported && !codex("0.165.9").supported && !codex(nil).supported)
    #expect(codex("0.120.0").label.contains("needs \(CLILocator.codexMinimum) or later"))
    #expect(InstalledCLI(path: URL(filePath: "/x"), version: nil, source: "path").supported) // no minimum, no check
}

/// A sign-in offers only its provider's pages: HTTPS, on the provider's domains or their subdomains, never a lookalike.
@Test func signInsOfferOnlyTheirProvidersPages() {
    func page(_ text: String, _ domains: [String]) -> Bool { SignInPage.belongs(URL(string: text)!, to: domains) }
    #expect(page("https://claude.ai/oauth/authorize?x=1", SignInPage.anthropic) && page("https://console.anthropic.com/x", SignInPage.anthropic))
    #expect(page("https://auth.openai.com/oauth/authorize", SignInPage.openAI) && page("https://chatgpt.com/x", SignInPage.openAI))
    #expect(!page("https://evilclaude.ai/x", SignInPage.anthropic) && !page("https://claude.ai.example.com/x", SignInPage.anthropic))
    #expect(!page("http://claude.ai/x", SignInPage.anthropic) && !page("https://example.com/openai.com", SignInPage.openAI))
}
