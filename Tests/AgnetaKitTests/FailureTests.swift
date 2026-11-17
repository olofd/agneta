// Failure tests that match Agneta's promises (Stop stops, Remove Access cuts off, nothing is lost silently), each
// checking where things end up: processes, storage, and what Agneta's UI hears. On the real Goose where it matters.
import Darwin
import Foundation
import Testing
@testable import AgnetaKit

extension RouterIntegrationTests {
    /// The engine's process id, from the task's trace.
    static func enginePID(_ stack: Stack, _ session: String) throws -> pid_t {
        let meta = try #require(String(contentsOf: stack.traces.file(for: session), encoding: .utf8).split(separator: "\n").first)
        return pid_t(try #require(try JSONCoding.decode(Data(meta.utf8))["engine"]?["pid"]?.intValue))
    }

    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// An engine that stops responding mid-turn (here frozen with SIGSTOP) can't hold up Stop: the task ends within
    /// Stop's bound, the process is gone, history says stopped, and the trace is closed with its end.
    @Test func stopEndsATaskWhoseEngineStoppedResponding() async throws {
        let stack = try await Stack.start(port: 47621, modelPort: 47622)
        do {
            let ended = Recorder()
            await stack.runtime.observe { event in if case .router(.sessionEnded(let id, let ending)) = event { ended.add("\(id) \(ending.rawValue)") } }
            let app = AppClient(port: stack.port)
            defer { app.close() }
            try await app.pairAndInitialize("Wedged")
            let session = try await app.newSession(cwd: try stack.workspace("Wedged"), tools: "workspace")
            let pid = try Self.enginePID(stack, session)
            kill(pid, SIGSTOP)
            let turn = Task { try? await app.prompt(session, "hello") }
            try await Task.sleep(for: .milliseconds(300))
            let started = ContinuousClock.now
            await stack.runtime.stop(task: session)
            #expect(ContinuousClock.now - started < .seconds(8), "Stop waited on the frozen engine")
            for _ in 0..<60 where Self.alive(pid) { try await Task.sleep(for: .milliseconds(50)) }
            #expect(!Self.alive(pid), "the frozen engine is still running")
            _ = await turn.value
            #expect(ended.all == ["\(session) stopped"])
            #expect(await stack.runtime.history().first { $0.id == session }?.outcome == .stopped)
            let last = try String(contentsOf: stack.traces.file(for: session), encoding: .utf8).split(separator: "\n").last.map { try JSONCoding.decode(Data($0.utf8)) }
            #expect(last?["type"]?.stringValue == "end")
            #expect(await stack.supervisor.processCount == 0)
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }

    /// A closed task whose engine state is gone (deleted from outside) fails to resume cleanly: an error, no session
    /// left behind, no engine process left running, and the task can be tried again.
    @Test func resumingATaskWhoseEngineStateIsGoneFailsCleanly() async throws {
        let stack = try await Stack.start(port: 47623, modelPort: 47624)
        do {
            let app = AppClient(port: stack.port)
            defer { app.close() }
            try await app.pairAndInitialize("Deleted")
            let workspace = try stack.workspace("Deleted")
            let session = try await app.newSession(cwd: workspace, tools: "workspace")
            #expect(try await app.prompt(session, "hello")["stopReason"]?.stringValue == "end_turn")
            _ = try await app.request("session/close", ["sessionId": .string(session)])
            let key = try #require(stack.traces.meta(task: session)?["engine"]?["key"]?.stringValue)
            try FileManager.default.removeItem(at: EngineHomes.home(root: stack.root.appending(path: "agneta"), key: key))
            let load: JSONValue = ["sessionId": .string(session), "cwd": .string(workspace.path(percentEncoded: false)), "mcpServers": []]
            await #expect(throws: RPCError.self) { _ = try await app.request("session/load", load) }
            for _ in 0..<40 where await stack.supervisor.processCount > 0 { try await Task.sleep(for: .milliseconds(50)) }
            #expect(await stack.supervisor.processCount == 0)
            #expect(await stack.runtime.router.sessionCount == 0)
            // Not stuck as "already open": a second try is answered the same way.
            await #expect(throws: RPCError.self) { _ = try await app.request("session/load", load) }
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }

    /// The disk under the traces fills up: the task still runs to its end, Agneta's UI is told its records are
    /// incomplete, and its history is still kept.
    @Test func aFullDiskStopsTheTraceNotTheTask() async throws {
        let stack = try await Stack.start(port: 47625, modelPort: 47626)
        let volume = stack.root.appending(path: "small", directoryHint: .isDirectory)
        let image = stack.root.appending(path: "small.dmg")
        func hdiutil(_ arguments: [String]) async -> Int32 {
            guard let child = try? ChildProcess(executable: "/usr/bin/hdiutil", arguments: arguments, environment: ["PATH": "/usr/bin:/bin"]) else { return -1 }
            return await child.waitForExit()
        }
        do {
            // A 2 MB volume of its own, filled to the last few kilobytes, where the traces are written.
            try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
            #expect(await hdiutil(["create", "-size", "2m", "-fs", "HFS+", "-volname", "agneta-full", image.path(percentEncoded: false)]) == 0)
            #expect(await hdiutil(["attach", image.path(percentEncoded: false), "-mountpoint", volume.path(percentEncoded: false), "-nobrowse", "-quiet"]) == 0)
            let filler = volume.appending(path: "filler")
            FileManager.default.createFile(atPath: filler.path(percentEncoded: false), contents: nil)
            let handle = try FileHandle(forWritingTo: filler)
            let chunk = Data(count: 64 << 10)
            while (try? handle.write(contentsOf: chunk)) != nil {}
            try handle.close()
            let traces = stack.root.appending(path: "agneta/Traces")
            try? FileManager.default.removeItem(at: traces)
            try FileManager.default.createSymbolicLink(at: traces, withDestinationURL: volume)

            let problems = Recorder()
            await stack.runtime.observe { event in if case .traceProblem(let task, _) = event { problems.add(task) } }
            let app = AppClient(port: stack.port)
            defer { app.close() }
            try await app.pairAndInitialize("Full")
            let session = try await app.newSession(cwd: try stack.workspace("Full"), tools: "app-only")
            for _ in 0..<3 { #expect(try await app.prompt(session, "hello")["stopReason"]?.stringValue == "end_turn") }
            for _ in 0..<40 where problems.all.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
            #expect(problems.all.contains(session), "Agneta's UI wasn't told the trace stopped")
            _ = try await app.request("session/close", ["sessionId": .string(session)])
            try await Task.sleep(for: .milliseconds(200))
            #expect(await stack.runtime.history().first { $0.id == session }?.outcome == .finished)
        } catch {
            _ = await hdiutil(["detach", volume.path(percentEncoded: false), "-force", "-quiet"])
            await stack.stop()
            throw error
        }
        _ = await hdiutil(["detach", volume.path(percentEncoded: false), "-force", "-quiet"])
        await stack.stop()
    }
}

extension RouterContractTests {
    /// Access removed while the session's engine is still starting: nothing is handed to the app, the engine is let
    /// go, the app's connection closes, and its token no longer works.
    @Test func accessRemovedWhileAnEngineStartsHandsNothingOut() async throws {
        let stack = try await Stack.start(port: 47627)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Revoked")
        let token = try #require(app.token)
        await stack.engines.starting(takes: .milliseconds(600))
        let opening = Task { try await stack.session(app, account: "brokered") }
        try await Task.sleep(for: .milliseconds(150))
        let grant = try #require(await stack.router.tokens.values.first { $0.app == "Revoked" })
        await stack.router.revoke(grant: grant.id)
        await #expect(throws: (any Error).self) { _ = try await opening.value }
        try await Task.sleep(for: .milliseconds(800))
        #expect(await stack.router.sessionCount == 0)
        #expect(await stack.engines.opened == stack.engines.released, "an engine was kept for a session nobody got")
        let other = AppClient(port: stack.port)
        defer { other.close() }
        await #expect(throws: RPCError.self) {
            _ = try await other.request("initialize", ["protocolVersion": 1, "clientCapabilities": [:], "_meta": ["agneta": ["token": .string(token)]]])
        }
    }
}
