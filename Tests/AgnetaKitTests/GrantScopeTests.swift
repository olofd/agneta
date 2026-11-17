// What a user allows an app at pairing, and every session held to it: tools, folders, "Allow Once", the saved
// grant, and the app's identity on reconnect.
import Foundation
import Testing
@testable import AgnetaKit

@Suite struct GrantScopeTests {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var context: PolicyContext { PolicyContext(userHome: home, agnetaRoots: [home.appending(path: "Library/Application Support/Agneta")]) }

    @Test func aScopeIsParsedStrictly() throws {
        let none = try GrantScope.requested(nil, context: context)
        #expect(none.tools == .appOnly && none.folders.isEmpty)
        let asked = try GrantScope.requested(["tools": "workspace", "folders": ["/tmp/project"]], context: context)
        #expect(asked.tools == .workspace && asked.folders.map { $0.path(percentEncoded: false).hasSuffix("/tmp/project/") } == [true])
        for bad: JSONValue in [["tools": "everything"], ["folders": "/tmp"], ["folders": [.string(home.path(percentEncoded: false))]],
                               ["folders": [.string(home.appending(path: ".ssh").path(percentEncoded: false))]], ["extra": true], "workspace"] {
            #expect(throws: PolicyRejection.self, "\(bad)") { _ = try GrantScope.requested(bad, context: context) }
        }
    }

    @Test func aSessionMustFitItsGrant() throws {
        let grant = Router.Grant(app: "App", accounts: ["a"], tools: .read, folders: ["/tmp/allowed"])
        func policy(_ tools: String, cwd: String, readable: [String] = []) throws -> SessionPolicy {
            try SessionPolicy.parse(["tools": .string(tools), "readable": .array(readable.map(JSONValue.string))], cwd: cwd, context: context)
        }
        #expect(GrantScope.check(try policy("read", cwd: "/tmp/allowed/project"), against: grant) == nil)
        #expect(GrantScope.check(try policy("workspace", cwd: "/tmp/allowed"), against: grant)?.field == "tools")
        #expect(GrantScope.check(try policy("app-only", cwd: "/tmp/elsewhere"), against: grant)?.field == "cwd")
        #expect(GrantScope.check(try policy("read", cwd: "/tmp/allowed", readable: ["/tmp/elsewhere"]), against: grant)?.field == "readable")
        // A prefix isn't containment: /tmp/allowed-not is outside /tmp/allowed.
        #expect(GrantScope.check(try policy("read", cwd: "/tmp/allowed-not"), against: grant)?.field == "cwd")
    }

    @Test func aVerifiedGrantChecksWhoReconnects() {
        let grant = Router.Grant(app: "App", identifier: "com.example.app", team: "TEAM1", verified: true, accounts: ["a"])
        let same = PeerIdentity(pid: 1, path: nil, identifier: "com.example.app", team: "TEAM1", valid: true, trusted: true)
        #expect(GrantScope.identityMatches(grant, same))
        var adHoc = same
        adHoc.trusted = false
        #expect(!GrantScope.identityMatches(grant, adHoc))
        var otherTeam = same
        otherTeam.team = "TEAM2"
        #expect(!GrantScope.identityMatches(grant, otherTeam))
        var otherApp = same
        otherApp.identifier = "com.example.other"
        #expect(!GrantScope.identityMatches(grant, otherApp))
        #expect(!GrantScope.identityMatches(grant, nil))
        #expect(GrantScope.identityMatches(Router.Grant(app: "Unsigned", accounts: ["a"]), nil)) // nothing verified to compare
    }
}

extension RouterContractTests {
    /// No scope asked: app-only tools, and only in the app's own workspace, which Agneta reports.
    @Test func aDefaultGrantIsAppOnlyInTheAppsOwnWorkspace() async throws {
        let stack = try await Stack.start(port: 47612, appWorkspaces: true)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Plain", scope: .null)
        let initialized = try await app.request("initialize", ["protocolVersion": 1, "clientCapabilities": [:], "_meta": ["agneta": ["token": .string(try #require(app.token))]]])
        let workspace = try #require(initialized["_meta"]?["agneta"]?["workspace"]?.stringValue)
        #expect(FileManager.default.fileExists(atPath: workspace))
        func newSession(_ cwd: String, tools: String?) async throws -> JSONValue {
            var meta: [String: JSONValue] = ["agneta": ["account": "brokered"]]
            if let tools { meta[SessionPolicy.key] = ["tools": .string(tools)] }
            return try await app.request("session/new", ["cwd": .string(cwd), "mcpServers": [], "_meta": .object(meta)])
        }
        _ = try await newSession(workspace, tools: "app-only")
        _ = try await newSession(workspace, tools: nil) // no policy: the grant's tools, not workspace
        for (cwd, tools, field) in [(workspace, "workspace", "tools"), (stack.root.appending(path: "work").path(percentEncoded: false), "app-only", "cwd")] {
            do {
                _ = try await newSession(cwd, tools: tools)
                Issue.record("\(field) beyond the grant was let through")
            } catch let error as RPCError {
                #expect(error.code == RPCError.invalidParams && error.data?["agneta"]?["unenforceable"]?.arrayValue?.first?.stringValue == field)
            }
        }
    }

    /// "Allow Once" works for the connection that paired, only while it lasts, and is never saved.
    @Test func allowOnceEndsWithItsConnection() async throws {
        let saved = Recorder()
        let stack = try await Stack.start(port: 47613, commit: { _, grant in saved.add(grant.app) },
                                          approve: { _ in Router.PairingAnswer(accounts: ["brokered"], remember: false) })
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        try await app.pairAndInitialize("Once")
        _ = try await stack.session(app, account: "brokered")
        let token = try #require(app.token)
        let other = AppClient(port: stack.port)
        defer { other.close() }
        await #expect(throws: RPCError.self) {
            _ = try await other.request("initialize", ["protocolVersion": 1, "clientCapabilities": [:], "_meta": ["agneta": ["token": .string(token)]]])
        }
        app.close()
        try await Task.sleep(for: .milliseconds(200))
        let later = AppClient(port: stack.port)
        defer { later.close() }
        await #expect(throws: RPCError.self) {
            _ = try await later.request("initialize", ["protocolVersion": 1, "clientCapabilities": [:], "_meta": ["agneta": ["token": .string(token)]]])
        }
        #expect(saved.all.isEmpty)
    }

    /// A grant that can't be saved isn't handed out: the token would work until the next launch and then fail.
    @Test func aGrantThatCantBeSavedIsntGiven() async throws {
        struct DiskFull: Error {}
        let stack = try await Stack.start(port: 47614, commit: { _, _ in throw DiskFull() })
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        await #expect(throws: RPCError.self) { try await app.pairAndInitialize("Unsaved") }
    }
}
