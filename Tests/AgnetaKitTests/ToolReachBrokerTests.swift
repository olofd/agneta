// What a contained session reaches beyond its folders is held to its app before every command, not only when the
// session opens: an app could serve its port at the check, stop, and have another program take it. At the broker,
// the next command is refused, the session's commands stop, and the router is told; end to end, through a real Goose
// session, the app hears its session stopped with `stoppedBy: "reach"` and why.
import Foundation
import Testing

@testable import AgnetaKit

/// Who the broker said was lost, and why.
final class LostReach: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(token: String, reason: String)] = []
    func add(_ token: String, _ reason: String) { lock.withLock { items.append((token, reason)) } }
    var all: [(token: String, reason: String)] { lock.withLock { items } }
}

extension ToolBrokerTests {
    /// Runs `command` through agneta-shell on `broker`, from `cwd`: its status and standard error.
    static func shell(_ command: String, broker: ToolBroker, cwd: URL) async throws -> (status: Int32, err: String) {
        let child = try ChildProcess(
            executable: shell.path(percentEncoded: false), arguments: ["-c", command],
            environment: ["AGNETA_BROKER_SOCKET": broker.socketPath, "AGNETA_BROKER_TOKEN": "t0ken"],
            directory: cwd.path(percentEncoded: false))
        try? child.stdin.close()
        async let out = collect(child.stdout)
        async let err = collect(child.stderr)
        let (_, e) = try await (out, err)
        let raw = await child.waitForExit()
        return ((raw >> 8) & 0xff, e)
    }

    @Test func aCommandIsRefusedOnceTheAppsServerIsReplaced() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agneta-reach-broker-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory
        ).realFileURL
        let workspace = root.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let own = try ReachListener.port()
        defer { own.stop() }
        let me = try #require(PeerIdentity.instance(of: getpid()))
        let check = ToolReach.Check(
            app: ToolReach.App(team: nil, processes: [me]), name: "Example", endpoints: [own.endpoint])
        let profile = SandboxProfile(kind: .tool, writable: [workspace], denied: [], loopbackPorts: [own.port]).render()
        let lost = LostReach()
        let reports = Reports()
        let broker = ToolBroker(
            socketPath: root.appending(path: "b.sock").path(percentEncoded: false),
            resolve: { token, cwd in
                guard token == "t0ken", cwd.isInside(workspace) else { return nil }
                return .init(
                    profile: profile, environment: ["PATH": "/usr/bin:/bin"],
                    reach: { ToolReach.lost(check, lookup: .system).map { "\($0) is no longer served by Example" } })
            }, report: { _, fields in reports.add(fields) }, lost: lost.add)
        try broker.start()
        defer { broker.stop() }

        #expect(try await Self.shell("echo ok", broker: broker, cwd: workspace).status == 0)
        #expect(lost.all.isEmpty)

        own.stop()
        let other = try await ReachListener.nc(port: own.port, unrelated: true)
        defer { other.stop() }
        let refused = try await Self.shell("echo again", broker: broker, cwd: workspace)
        #expect(refused.status == 126 && refused.err.contains("port \(own.port) is no longer served"), "\(refused)")
        #expect(lost.all.map(\.token) == ["t0ken"] && lost.all.first?.reason.contains("port \(own.port)") == true)
        for _ in 0..<50 where reports.all.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(reports.all.last?["refused"]?.stringValue?.contains("no longer served") == true)
        // Its engine runs nothing more, whatever serves the port next.
        #expect(try await Self.shell("echo later", broker: broker, cwd: workspace).status == 126)
    }
}

extension RouterIntegrationTests {
    @Test func aContainedSessionStopsWhenItsAppsServerIsReplaced() async throws {
        let stack = try await Stack.start(port: 47460, modelPort: 47470)
        do {
            let app = AppClient(port: stack.port)
            defer { app.close() }
            try await app.pairAndInitialize("Reach")
            let own = try ReachListener.port()
            defer { own.stop() }
            let result = try await app.request(
                "session/new",
                [
                    "cwd": .string(try stack.workspace("R").path(percentEncoded: false)), "mcpServers": [],
                    "_meta": [
                        SessionPolicy.key: [
                            "tools": "workspace", "sandbox": "contained", "network": "none", "approval": "never-ask",
                            "toolPorts": [.int(Int64(own.port))]
                        ],
                        "agneta": ["account": "dev"]
                    ]
                ])
            #expect(result["_meta"]?["agneta"]?["sandbox"]?.stringValue == "contained")
            let session = try #require(result["sessionId"]?.stringValue)
            _ = try await app.prompt(session, #"CALL shell {"command": "echo first-ran"}"#)
            #expect(app.toolOutput(session).contains("first-ran"))
            #expect(app.notifications("agneta/sessionStopped").isEmpty)

            own.stop()
            let other = try await ReachListener.nc(port: own.port, unrelated: true)
            defer { other.stop() }
            _ = try? await app.prompt(session, #"CALL shell {"command": "echo second-ran"}"#)
            for _ in 0..<100 where app.notifications("agneta/sessionStopped").isEmpty {
                try await Task.sleep(for: .milliseconds(50))
            }
            let stopped = try #require(app.notifications("agneta/sessionStopped").first)
            #expect(stopped["stoppedBy"]?.stringValue == "reach" && stopped["sessionId"]?.stringValue == session)
            #expect(stopped["reason"]?.stringValue?.contains("port \(own.port) is no longer served by Reach") == true)
            #expect(!app.toolOutput(session).contains("second-ran"))
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }
}
