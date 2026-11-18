import Foundation
import Testing
@testable import AgnetaKit

@Suite struct PolicyTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "agneta-policy-\(UUID().uuidString)", directoryHint: .isDirectory)
    var home: URL { root.appending(path: "home", directoryHint: .isDirectory) }
    var context: PolicyContext { PolicyContext(userHome: home, agnetaRoots: [home.appending(path: "Library/Application Support/Agneta")]) }

    init() throws {
        for path in ["home/Documents/Example/Project.example/Workspace", "home/Documents/Example/Project.example/Private", "home/Library/Containers/com.example.app/Data", "home/Library/Application Support/Agneta/Accounts/a"] {
            try FileManager.default.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
        }
    }

    var workspace: String { home.appending(path: "Documents/Example/Project.example/Workspace").path(percentEncoded: false) }

    @Test func missingPolicyFallsBackToWorkspaceToolsWithAppApproval() throws {
        let policy = try SessionPolicy.parse(nil, cwd: workspace, context: context)
        #expect(policy.tools == .workspace)
        #expect(policy.approval == .askApp)
        #expect(policy.network == .none)
    }

    @Test func parsesAProjectPackagePolicy() throws {
        let privateFolder = home.appending(path: "Documents/Example/Project.example/Private").path(percentEncoded: false)
        let policy = try SessionPolicy.parse(["tools": "workspace", "denied": [.string(privateFolder)], "network": "none", "approval": "never-ask", "limits": ["maxTurns": 50]],
                                             cwd: workspace, context: context)
        #expect(policy.denied.count == 1)
        #expect(policy.approval == .neverAsk)
        #expect(policy.limits.maxTurns == 50)
    }

    /// Any JSON number an app sends as a limit is refused or used, never a crash: `Int(1e300)` traps.
    @Test func outOfRangeLimitsAreRefusedNotACrash() {
        for limits: JSONValue in [["maxTurns": .double(1e300)], ["maxSeconds": .double(-1e300)], ["maxTurns": .double(2.5)],
                                  ["maxSeconds": .double(Double(Int32.max) + 1)], ["maxTurns": 0], ["maxCostUSD": .double(-1)]] {
            #expect(throws: PolicyRejection.self, "\(limits)") { _ = try SessionPolicy.parse(["limits": limits], cwd: workspace, context: context) }
        }
        #expect((try? SessionPolicy.parse(["limits": ["maxTurns": .double(12), "maxSeconds": 600, "maxCostUSD": .double(0.5)]], cwd: workspace, context: context))?.limits.maxTurns == 12)
    }

    /// A folder checked when the session was authorized and swapped for a symlink before the sandbox profile is written
    /// stays the folder that was checked: the profile never follows the new link past the checks.
    @Test func aFolderSwappedForASymlinkAfterTheCheckGainsNothing() throws {
        let notes = URL(filePath: workspace).appending(path: "notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let secret = root.appending(path: "home/Library/Containers/com.example.app/Data", directoryHint: .isDirectory)
        let policy = try SessionPolicy.parse(["tools": "workspace", "writable": [.string(notes.path(percentEncoded: false))]], cwd: workspace, context: context)
        try FileManager.default.removeItem(at: notes)
        try FileManager.default.createSymbolicLink(at: notes, withDestinationURL: secret)
        for profile in [policy.toolProfile(scratch: root.appending(path: "scratch")).render(), {
            var engine = SandboxProfile(kind: .engine, writable: [policy.workspace] + policy.writable, denied: [])
            engine.verbatim = policy.checkedPaths
            return engine.render()
        }()] {
            #expect(!profile.contains(secret.realFileURL.path(percentEncoded: false)), "the profile followed the swapped-in link")
            #expect(profile.contains("\"\(policy.writable[0].path(percentEncoded: false).trimmingSuffix("/"))\""))
        }
    }

    @Test func projectPackageRequirements() throws {
        // Read-only folders inside the workspace, and the one port and Unix socket its tools may reach.
        let tests = home.appending(path: "Documents/Example/Project.example/Workspace/tests").path(percentEncoded: false)
        let policy = try SessionPolicy.parse(["readOnly": [.string(tests)], "toolPorts": [47392], "toolSockets": ["/tmp/tools.sock"]], cwd: workspace, context: context)
        let profile = policy.toolProfile(scratch: root.appending(path: "scratch")).render()
        #expect(profile.contains("(deny file-write* (subpath \"\(URL(filePath: tests).realFileURL.path(percentEncoded: false))\"))"))
        #expect(profile.contains("(allow network-outbound (remote tcp \"localhost:47392\"))"))
        #expect(profile.contains("(allow network-outbound (remote unix-socket (path-literal \"/private/tmp/tools.sock\")))"))
        #expect(throws: PolicyRejection.self) { try SessionPolicy.parse(["toolPorts": [0]], cwd: workspace, context: context) }
    }

    @Test func refusesWhatItCantEnforce() {
        func rejection(_ value: JSONValue, cwd: String? = nil) -> String? {
            do { _ = try SessionPolicy.parse(value, cwd: cwd ?? workspace, context: context); return nil }
            catch let error as PolicyRejection { return error.field }
            catch { return "other" }
        }
        #expect(rejection(["tools": "everything"]) == "tools")
        #expect(rejection(["network": ["allow": ["example.com"]]]) == "network")
        #expect(rejection(["readable": ["relative/path"]]) == "readable")
        #expect(rejection([:], cwd: home.appending(path: "Library/Containers/com.example.app/Data").path(percentEncoded: false)) == "cwd")
        #expect(rejection([:], cwd: home.appending(path: "Library/Application Support/Agneta/Accounts/a").path(percentEncoded: false)) == "cwd")
        #expect(rejection([:], cwd: home.path(percentEncoded: false)) == "cwd")
        #expect(rejection(["denied": [.string(workspace)]]) == "denied")
    }

    @Test func realPathsKeepPrivate() {
        #expect(URL(filePath: "/tmp/agneta-x/y").realFileURL.path(percentEncoded: false) == "/private/tmp/agneta-x/y")
    }

    @Test func refusalIsATypedRPCError() {
        let error = PolicyRejection(field: "network", reason: "x").rpcError
        #expect(error.code == RPCError.invalidParams)
        #expect(error.data?["agneta"]?["unenforceable"] == ["network"])
    }

    @Test func toolProfileHasNoNetworkAndNoKeychain() {
        let profile = SandboxProfile(kind: .tool, writable: [URL(filePath: "/w")], denied: [URL(filePath: "/w/held")]).render()
        #expect(profile.contains("(deny file-write* (require-not (require-any (subpath \"/w\")"))
        #expect(profile.contains("(deny file-read* file-write* (subpath \"/w/held\"))"))
        #expect(profile.contains("(deny network-outbound (require-not (remote unix-socket"))
        #expect(!profile.contains("(allow network-outbound"))
        #expect(profile.contains("com.apple.securityd"))
        // Reads are allow-listed: the session's folders and system locations, nothing else.
        #expect(profile.contains("(deny file-read-data (require-all (require-not (literal \"/\")) (require-not (subpath \"/w\")) (require-not (path-ancestors \"/w\"))"))
        #expect(profile.contains("(require-not (subpath \"/usr\"))"))
    }

    @Test func engineProfileAllowsProvidersAndTheToolServer() {
        let profile = SandboxProfile(kind: .engine, writable: [URL(filePath: "/w")], denied: [], loopbackPorts: [47392], remotePorts: [443]).render()
        #expect(profile.contains("(allow network-outbound (remote tcp \"localhost:47392\"))"))
        #expect(profile.contains("(allow network-outbound (remote tcp \"*:443\"))"))
        #expect(profile.contains("(deny appleevent-send)")) // engines script no other apps either
    }
}
