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
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agneta-broker-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory
        ).realFileURL
        let workspace = root.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "outside"), withIntermediateDirectories: true)
        let profile = SandboxProfile(kind: .tool, writable: [workspace], denied: []).render()
        let reports = Reports()
        let broker = ToolBroker(
            socketPath: root.appending(path: "b.sock").path(percentEncoded: false),
            resolve: { token, cwd in
                token == "t0ken" && cwd.isInside(workspace)
                    ? .init(
                        profile: profile,
                        environment: ["PATH": "/usr/bin:/bin", "HOME": workspace.path(percentEncoded: false)]) : nil
            }, report: { _, fields in reports.add(fields) })
        try broker.start()
        defer { broker.stop() }
        let child = try ChildProcess(
            executable: shell.path(percentEncoded: false), arguments: ["-c", command],
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
        let ms: Double =
            switch report["ms"] {
            case .double(let v)?: v;
            case .int(let v)?: Double(v);
            default: 0
            }
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
        let check = try ChildProcess(
            executable: "/bin/sh", arguments: ["-c", "pgrep -f 'sleep 30; touch late.txt' || echo none"],
            environment: ["PATH": "/usr/bin:/bin"])
        let out = String(decoding: check.stdout.readDataToEndOfFile(), as: UTF8.self)
        _ = await check.waitForExit()
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == "none")
        #expect(
            !FileManager.default.fileExists(atPath: root.appending(path: "work/late.txt").path(percentEncoded: false)))
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
        let check = try ChildProcess(
            executable: "/usr/bin/pgrep", arguments: ["-f", marker], environment: ["PATH": "/usr/bin:/bin"])
        let out = String(decoding: check.stdout.readDataToEndOfFile(), as: UTF8.self)
        _ = await check.waitForExit()
        #expect(out.isEmpty, "still running: \(out)")
        #expect(
            !FileManager.default.fileExists(atPath: root.appending(path: "work/\(marker)").path(percentEncoded: false)))
    }

    @Test func commandsHaveNoNetworkAndStayInTheWorkspace() async throws {
        let (result, root) = try await Self.run(
            """
            /usr/bin/curl -s -o /dev/null --max-time 4 https://api.github.com && echo NET || echo no-network
            touch inside.txt && echo wrote-inside
            touch ../outside/escape.txt 2>/dev/null && echo ESCAPED || echo outside-denied
            ls "/Users/$(/usr/bin/id -un)/Library/Preferences" >/dev/null 2>&1 && echo HOME-READ || echo home-denied
            """)
        #expect(result.out == "no-network\nwrote-inside\noutside-denied\nhome-denied\n")
        #expect(
            FileManager.default.fileExists(atPath: root.appending(path: "work/inside.txt").path(percentEncoded: false)))
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

extension ToolBrokerTests {
    /// A token's commands stop with its engine, even when their client (a detached shell) lives on: the broker lists
    /// what each token runs, and once the engine ends nothing it started keeps running, nor can it start more.
    @Test func anEnginesCommandsStopWithItAndItStartsNoMore() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agneta-broker-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory
        ).realFileURL
        let workspace = root.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = SandboxProfile(kind: .tool, writable: [workspace], denied: []).render()
        let broker = ToolBroker(
            socketPath: root.appending(path: "b.sock").path(percentEncoded: false),
            resolve: { token, cwd in
                cwd.isInside(workspace) ? .init(profile: profile, environment: ["PATH": "/usr/bin:/bin"]) : nil
            })
        try broker.start()
        defer { broker.stop() }
        func start(_ command: String, token: String) throws -> ChildProcess {
            let child = try ChildProcess(
                executable: Self.shell.path(percentEncoded: false), arguments: ["-c", command],
                environment: ["AGNETA_BROKER_SOCKET": broker.socketPath, "AGNETA_BROKER_TOKEN": token],
                directory: workspace.path(percentEncoded: false))
            try? child.stdin.close()
            return child
        }
        let long = try start("sleep 30", token: "engine-a")
        let other = try start("sleep 30", token: "engine-b")
        for _ in 0..<100
        where broker.runningCommands(token: "engine-a") == 0 || broker.runningCommands(token: "engine-b") == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(broker.runningCommands(token: "engine-a") == 1 && broker.runningCommands(token: "engine-b") == 1)

        let started = ContinuousClock.now
        #expect(broker.stopCommands(token: "engine-a") == 1)
        let raw = await long.waitForExit()
        #expect(ContinuousClock.now - started < .seconds(5), "the command ended with its engine")
        #expect((raw >> 8) & 0xff != 0, "it was stopped, not finished")
        #expect(broker.runningCommands(token: "engine-a") == 0)
        // Another engine's command runs on.
        #expect(broker.runningCommands(token: "engine-b") == 1)
        other.signalGroup(SIGKILL)
        _ = await other.waitForExit()

        // A stopped engine's token starts nothing more.
        let late = try start("echo should-not-run", token: "engine-a")
        let out = try await Self.collect(late.stdout)
        _ = await late.waitForExit()
        #expect(!out.contains("should-not-run"), "\(out)")
    }
}

extension ToolBrokerTests {
    /// A broker with agneta-shell as its holder, for one workspace, and a way to run commands through it.
    struct Held {
        let root: URL, workspace: URL, broker: ToolBroker
        init() throws {
            root =
                FileManager.default.temporaryDirectory.appending(
                    path: "agneta-held-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory
                ).realFileURL
            workspace = root.appending(path: "work", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let profile = SandboxProfile(kind: .tool, writable: [workspace], denied: []).render()
            let workspace = workspace
            broker = ToolBroker(
                socketPath: root.appending(path: "b.sock").path(percentEncoded: false),
                holder: ToolBrokerTests.shell.path(percentEncoded: false),
                resolve: { _, cwd in
                    cwd.isInside(workspace) ? .init(profile: profile, environment: ["PATH": "/usr/bin:/bin"]) : nil
                })
            try broker.start()
        }
        /// As an engine runs it: the token from the engine's file, never its environment.
        func run(_ command: String, token: String = "engine") async throws -> (status: Int32, out: String) {
            let file = root.appending(path: "token-\(token)")
            try token.write(to: file, atomically: true, encoding: .utf8)
            let child = try ChildProcess(
                executable: ToolBrokerTests.shell.path(percentEncoded: false), arguments: ["-c", command],
                environment: [
                    "AGNETA_BROKER_SOCKET": broker.socketPath,
                    "AGNETA_BROKER_TOKEN_FILE": file.path(percentEncoded: false)
                ],
                directory: workspace.path(percentEncoded: false))
            try? child.stdin.close()
            let out = try await ToolBrokerTests.collect(child.stdout)
            let raw = await child.waitForExit()
            return ((raw >> 8) & 0xff, out)
        }
        func stop() { broker.stop(); try? FileManager.default.removeItem(at: root) }
    }

    /// What a command starts in the background lives on after it returns, as in a terminal, and ends with its engine.
    @Test func aBackgroundJobOutlivesItsCommandAndEndsWithItsEngine() async throws {
        let held = try Held()
        defer { held.stop() }
        let started = ContinuousClock.now
        let first = try await held.run("(sleep 2; echo finished > bg.txt) > /dev/null 2>&1 & echo started")
        #expect(first.status == 0 && first.out.contains("started"))
        #expect(
            ContinuousClock.now - started < .seconds(2), "the command returned without waiting for its background job")
        #expect(held.broker.runningCommands(token: "engine") == 1, "the background job is listed")
        try await Task.sleep(for: .seconds(3))
        #expect(
            FileManager.default.fileExists(
                atPath: held.workspace.appending(path: "bg.txt").path(percentEncoded: false)),
            "it finished after its command")
        // Its group emptied: the holder left and nothing is listed.
        for _ in 0..<60 where held.broker.runningCommands(token: "engine") > 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(held.broker.runningCommands(token: "engine") == 0)

        // One still running when its engine ends is stopped with it.
        _ = try await held.run("(sleep 3; echo leaked > late.txt) > /dev/null 2>&1 &")
        #expect(held.broker.stopCommands(token: "engine") == 1)
        try await Task.sleep(for: .seconds(4))
        #expect(
            !FileManager.default.fileExists(
                atPath: held.workspace.appending(path: "late.txt").path(percentEncoded: false)),
            "it ended with its engine")
    }

    /// A command whose client goes away (the engine timed it out) still ends with all it started.
    @Test func aCommandWhoseClientGoesEndsWithAllItStarted() async throws {
        let held = try Held()
        defer { held.stop() }
        let child = try ChildProcess(
            executable: Self.shell.path(percentEncoded: false),
            arguments: ["-c", "(sleep 3; echo leaked > orphan.txt) & sleep 30"],
            environment: ["AGNETA_BROKER_SOCKET": held.broker.socketPath, "AGNETA_BROKER_TOKEN": "engine"],
            directory: held.workspace.path(percentEncoded: false))
        try? child.stdin.close()
        for _ in 0..<100 where held.broker.runningCommands(token: "engine") == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(300))
        child.signalGroup(SIGKILL)
        _ = await child.waitForExit()
        try await Task.sleep(for: .seconds(4))
        #expect(
            !FileManager.default.fileExists(
                atPath: held.workspace.appending(path: "orphan.txt").path(percentEncoded: false)))
        for _ in 0..<60 where held.broker.runningCommands(token: "engine") > 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(held.broker.runningCommands(token: "engine") == 0)
    }

    /// A command's end is waited for on the broker's own thread, woken by the reaper: it needs none of Swift's shared
    /// threads. Through a Task, as before, it waited for one, and with all of them busy every command hung (CI,
    /// 2026-11-22). Here every shared thread is held by blocking work until the wait has returned: the old way waited
    /// out the blockers' 3 s, this way returns as the process exits.
    @Test func waitingForAnExitNeedsNoSharedThread() async throws {
        final class Elapsed: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Duration?
            func set(_ duration: Duration) { lock.withLock { value = duration } }
            var get: Duration? { lock.withLock { value } }
        }
        let child = try ChildProcess(executable: "/bin/sh", arguments: ["-c", "sleep 0.2; exit 3"], environment: [:])
        // More blockers than the pool has threads (one per core; one with LIBDISPATCH_COOPERATIVE_POOL_STRICT).
        let width = ProcessInfo.processInfo.activeProcessorCount + 2
        let release = DispatchSemaphore(value: 0)
        // Blocking a shared thread on purpose (a synchronous function: Swift refuses the wait in async code).
        @Sendable func hold() { _ = release.wait(timeout: .now() + 3) }
        for _ in 0..<width { Task.detached { hold() } }
        let elapsed = Elapsed(), status = Counter()
        Thread {
            let started = ContinuousClock.now
            if (child.waitForExitBlocking() >> 8) & 0xff == 3 { status.add() }
            elapsed.set(ContinuousClock.now - started)
            for _ in 0..<width { release.signal() }
        }.start()
        let raw = await child.waitForExit()
        #expect((raw >> 8) & 0xff == 3)
        let deadline = ContinuousClock.now + .seconds(10)
        while elapsed.get == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(status.value == 1)
        #expect(try #require(elapsed.get) < .seconds(2), "the wait needed a shared thread")
        #expect((child.waitForExitBlocking() >> 8) & 0xff == 3) // after the exit: at once
    }

    /// Agneta stopping ends every command, background jobs included, and starts none after.
    @Test func stoppingAgnetaEndsEveryCommand() async throws {
        let held = try Held()
        defer { held.stop() }
        _ = try await held.run("(sleep 3; echo leaked > late.txt) > /dev/null 2>&1 &")
        #expect(held.broker.runningCommands(token: "engine") == 1)
        held.broker.stop()
        #expect(held.broker.runningCommands(token: "engine") == 0)
        try await Task.sleep(for: .seconds(4))
        #expect(
            !FileManager.default.fileExists(
                atPath: held.workspace.appending(path: "late.txt").path(percentEncoded: false)))
    }

    /// The holder's stdin is Agneta's: closed before the command joins, it leaves at once (the command never started);
    /// closed after, Agneta has gone, and it ends everything in its group.
    @Test(.timeLimit(.minutes(1))) func theHolderEndsItsGroupWhenAgnetaGoes() async throws {
        let idle = try ChildProcess(
            executable: Self.shell.path(percentEncoded: false), arguments: ["--hold"], environment: [:])
        let started = ContinuousClock.now
        try idle.stdin.close()
        _ = await idle.waitForExit()
        #expect(ContinuousClock.now - started < .seconds(2))

        let holder = try ChildProcess(
            executable: Self.shell.path(percentEncoded: false), arguments: ["--hold"], environment: [:])
        let job = try ChildProcess(executable: "/bin/sleep", arguments: ["30"], environment: [:], joining: holder.pid)
        try holder.stdin.write(contentsOf: Data("g".utf8))
        try await Task.sleep(for: .milliseconds(500))
        #expect(!holder.hasExited && !job.hasExited)
        try holder.stdin.close()
        let raw = await job.waitForExit()
        #expect(raw & 0x7f == SIGKILL, "the job was ended: \(raw)")
        _ = await holder.waitForExit()
    }

    /// Codex's shell (`agneta-shell --mcp`) runs calls at once, so a quick one isn't stuck behind a slow one, and a
    /// cancelled call ends its command and gets no reply.
    @Test(.timeLimit(.minutes(1))) func theMCPShellRunsCallsAtOnceAndHonoursCancel() async throws {
        let held = try Held()
        defer { held.stop() }
        let server = try ChildProcess(
            executable: Self.shell.path(percentEncoded: false), arguments: ["--mcp"],
            environment: [
                "AGNETA_BROKER_SOCKET": held.broker.socketPath, "AGNETA_BROKER_TOKEN": "engine", "AGNETA_SHELL": "1",
                "AGNETA_SHELL_CWD": held.workspace.path(percentEncoded: false)
            ])
        defer { server.signalGroup(SIGKILL) }
        final class Replies: @unchecked Sendable {
            let lock = NSLock()
            var order: [Int] = []
            var texts: [Int: String] = [:]
        }
        let replies = Replies()
        let output = server.stdout
        Thread {
            var buffer = Data()
            while true {
                let chunk = output.availableData
                if chunk.isEmpty { return }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                        let id = message["id"] as? Int
                    {
                        let text =
                            ((message["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"]
                            as? String
                        replies.lock.withLock {
                            replies.order.append(id); replies.texts[id] = text
                        }
                    }
                }
            }
        }.start()
        func send(_ message: [String: Any]) throws {
            try server.stdin.write(contentsOf: try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8))
        }
        func call(_ id: Int, _ command: String) throws {
            try send([
                "jsonrpc": "2.0", "id": id, "method": "tools/call",
                "params": ["name": "shell", "arguments": ["command": command]]
            ])
        }
        func waitFor(_ id: Int) async throws {
            for _ in 0..<200 where !replies.lock.withLock({ replies.order.contains(id) }) {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try send(["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": [:]])
        try await waitFor(0)
        try call(1, "sleep 2; echo one")
        try call(2, "echo two")
        try await waitFor(1)
        #expect(replies.lock.withLock { replies.order } == [0, 2, 1], "the quick call answered first")

        try call(3, "sleep 30; echo late > cancelled.txt")
        for _ in 0..<100 where held.broker.runningCommands(token: "engine") == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 3]])
        for _ in 0..<100 where held.broker.runningCommands(token: "engine") > 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(held.broker.runningCommands(token: "engine") == 0, "the cancelled command ended")
        try call(4, "echo four")
        try await waitFor(4)
        // Output beyond the limit is cut as it streams: its start and end come back, with what was cut between.
        try call(5, "head -c 3000000 /dev/zero | tr '\\0' x; echo; echo the-end")
        try await waitFor(5)
        let big = try #require(replies.lock.withLock { replies.texts[5] })
        #expect(
            big.utf8.count < 110_000 && big.contains("bytes cut") && big.contains("the-end"), "\(big.utf8.count) bytes")
        #expect(!replies.lock.withLock { replies.order }.contains(3), "a cancelled call gets no reply")
    }
}
