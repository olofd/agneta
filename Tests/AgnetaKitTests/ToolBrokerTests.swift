// The broker path end to end: agneta-shell → Unix socket → ToolBroker →
// sandbox-exec with the tool profile. Needs `swift build` first for the
// agneta-shell executable.
import Foundation
import Testing
@testable import AgnetaKit

enum BuiltTools {
    static let shell = GooseHarness.repo.appending(path: ".build/debug/agneta-shell")
    static var shellBuilt: Bool { FileManager.default.isExecutableFile(atPath: shell.path(percentEncoded: false)) }
}

@Suite(.serialized, .enabled(if: BuiltTools.shellBuilt, "run swift build first"))
struct ToolBrokerTests {
    static let shell = BuiltTools.shell

    struct Result { var status: Int32; var out: String; var err: String; var reports: [[String: JSONValue]] = [] }

    /// What the broker reported for the task trace.
    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String: JSONValue]] = []
        func add(_ fields: [String: JSONValue]) { lock.withLock { items.append(fields) } }
        var all: [[String: JSONValue]] { lock.withLock { items } }
    }

    /// Starts a broker for one workspace, runs `command` through agneta-shell from `cwd`, stops the broker.
    static func run(_ command: String, cwd: URL? = nil, token: String = "t0ken") async throws -> (Result, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "agneta-broker-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory).realFileURL
        let workspace = root.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "outside"), withIntermediateDirectories: true)
        let profile = SandboxProfile(kind: .tool, writable: [workspace], denied: []).render()
        let reports = Reports()
        let broker = ToolBroker(socketPath: root.appending(path: "b.sock").path(percentEncoded: false), resolve: { token, cwd in
            token == "t0ken" && cwd.isInside(workspace) ? .init(profile: profile, environment: ["PATH": "/usr/bin:/bin", "HOME": workspace.path(percentEncoded: false)]) : nil
        }, report: { _, fields in reports.add(fields) })
        try broker.start()
        defer { broker.stop() }
        let child = try ChildProcess(executable: shell.path(percentEncoded: false), arguments: ["-c", command],
                                     environment: ["AGNETA_BROKER_SOCKET": broker.socketPath, "AGNETA_BROKER_TOKEN": token],
                                     directory: (cwd ?? workspace).path(percentEncoded: false))
        try? child.stdin.close()
        async let out = collect(child.stdout)
        async let err = collect(child.stderr)
        let (o, e) = try await (out, err)
        let raw = await child.waitForExit()
        // The broker reports just after it answers; give it a moment.
        for _ in 0..<50 where reports.all.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        return (Result(status: (raw >> 8) & 0xff, out: o, err: e, reports: reports.all), root)
    }

    static func collect(_ handle: FileHandle) async throws -> String {
        var text = ""
        for try await line in LineStream.lines(from: handle) { text += String(decoding: line, as: UTF8.self) + "\n" }
        return text
    }

    @Test func relaysOutputAndStatus() async throws {
        let (result, _) = try await Self.run("echo out; echo err 1>&2; exit 3")
        #expect(result.out == "out\n")
        #expect(result.err == "err\n")
        #expect(result.status == 3)
    }

    /// Each command's outcome reaches the task trace: command, exit, timing, sizes, stderr's end.
    @Test func reportsEachCommandForTheTrace() async throws {
        let (result, _) = try await Self.run("echo out; echo err 1>&2; sleep 0.1; exit 3")
        let report = try #require(result.reports.first)
        #expect(report["command"]?.stringValue == "echo out; echo err 1>&2; sleep 0.1; exit 3")
        #expect(report["exit"]?.intValue == 3 && report["signal"] == nil)
        #expect(report["stdoutBytes"]?.intValue == 4 && report["stderrBytes"]?.intValue == 4)
        #expect(report["stderrTail"]?.stringValue == "err\n")
        let ms: Double = switch report["ms"] { case .double(let v)?: v; case .int(let v)?: Double(v); default: 0 }
        #expect(ms >= 100)
        #expect(report["profileSha256"]?.stringValue?.count == 64)

        let (killed, _) = try await Self.run("kill -9 $$")
        #expect(killed.reports.first?["signal"]?.intValue == 9)

        let (refused, _) = try await Self.run("echo hi", cwd: FileManager.default.temporaryDirectory)
        #expect(refused.reports.first?["refused"]?.stringValue == "outside the session's folders")
        #expect(refused.reports.first?["exit"] == nil)
    }

    /// Commands can't reach LaunchServices (which would open things outside the sandbox).
    @Test func commandsCantReachLaunchServices() async throws {
        let (result, _) = try await Self.run("/usr/bin/lsappinfo info -only pid Finder 2>&1; echo done")
        #expect(!result.out.contains("\"pid\""))
        #expect(result.out.hasSuffix("done\n"))
    }

    /// Background processes a command starts end with it.
    @Test func backgroundProcessesEndWithTheCommand() async throws {
        let (result, root) = try await Self.run("(sleep 30; touch late.txt) > /dev/null 2>&1 & echo started")
        #expect(result.out == "started\n")
        try await Task.sleep(for: .milliseconds(300))
        // The background `sleep 30` must be gone: nothing in the workspace's group survives.
        let check = try ChildProcess(executable: "/bin/sh", arguments: ["-c", "pgrep -f 'sleep 30; touch late.txt' || echo none"], environment: ["PATH": "/usr/bin:/bin"])
        let out = String(decoding: check.stdout.readDataToEndOfFile(), as: UTF8.self)
        _ = await check.waitForExit()
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == "none")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "work/late.txt").path(percentEncoded: false)))
    }

    /// A background child that keeps the output open doesn't hold the command up or outlive it.
    @Test func aBackgroundChildHoldingTheOutputDoesntHangTheCommand() async throws {
        // A marker unique to this run, so the process search can't match anything else (a shell that merely mentions it).
        let marker = "late-\(UUID().uuidString.prefix(8)).txt"
        let started = ContinuousClock.now
        let (result, root) = try await Self.run("(sleep 31; touch \(marker)) & echo started")
        #expect(ContinuousClock.now - started < .seconds(10), "the command waited for its background child")
        #expect(result.out == "started\n" && result.status == 0)
        try await Task.sleep(for: .milliseconds(300))
        let check = try ChildProcess(executable: "/usr/bin/pgrep", arguments: ["-f", marker], environment: ["PATH": "/usr/bin:/bin"])
        let out = String(decoding: check.stdout.readDataToEndOfFile(), as: UTF8.self)
        _ = await check.waitForExit()
        #expect(out.isEmpty, "still running: \(out)")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "work/\(marker)").path(percentEncoded: false)))
    }

    @Test func commandsHaveNoNetworkAndStayInTheWorkspace() async throws {
        let (result, root) = try await Self.run("""
        /usr/bin/curl -s -o /dev/null --max-time 4 https://api.github.com && echo NET || echo no-network
        touch inside.txt && echo wrote-inside
        touch ../outside/escape.txt 2>/dev/null && echo ESCAPED || echo outside-denied
        ls "/Users/$(/usr/bin/id -un)/Library/Preferences" >/dev/null 2>&1 && echo HOME-READ || echo home-denied
        """)
        #expect(result.out == "no-network\nwrote-inside\noutside-denied\nhome-denied\n")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "work/inside.txt").path(percentEncoded: false)))
    }

    @Test func refusesUnknownFoldersAndWrongTokens() async throws {
        let (outside, root) = try await Self.run("echo hi", cwd: FileManager.default.temporaryDirectory)
        #expect(outside.status == 126)
        #expect(outside.err.contains("no session allows commands"))
        _ = root
        let (wrong, _) = try await Self.run("echo hi", token: "nope")
        #expect(wrong.status == 126)
        #expect(wrong.out.isEmpty)
    }
}
