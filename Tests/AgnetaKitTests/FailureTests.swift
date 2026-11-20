// Failure tests that match Agneta's promises (Stop stops, Remove Access cuts off, nothing is lost silently), each
// checking where things end up: processes, storage, and what Agneta's UI hears. On the real Goose where it matters.
import Darwin
import Foundation
import GRDB
import Testing

@testable import AgnetaKit

extension RouterIntegrationTests {
    /// The engine's process id, from the task's trace.
    static func enginePID(_ stack: Stack, _ session: String) throws -> pid_t {
        let meta = try #require(stack.traces.text(of: session).split(separator: "\n").first)
        return pid_t(try #require(try JSONCoding.decode(Data(meta.utf8))["engine"]?["pid"]?.intValue))
    }

    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// An engine that stops responding mid-turn (here frozen with SIGSTOP) can't hold up Stop: the task ends within
    /// Stop's bound, the process is gone, history says stopped, and the trace is closed with its end.
    @Test func stopEndsATaskWhoseEngineStoppedResponding() async throws {
        let stack = try await Stack.start(port: 47621, modelPort: 47622)
        do {
            let ended = Recorder()
            await stack.runtime.observe { event in
                if case .router(.sessionEnded(let id, let ending)) = event { ended.add("\(id) \(ending.rawValue)") }
            }
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
            let last = try stack.traces.text(of: session).split(separator: "\n").last.map {
                try JSONCoding.decode(Data($0.utf8))
            }
            #expect(last?["type"]?.stringValue == "end")
            #expect(await stack.supervisor.processCount == 0)
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }

    /// A task that told the account's shared Goose `words`, closed and recorded as finished: the task, its
    /// conversation, and the folder of the engine's database.
    static func sharedTask(_ stack: Stack, _ app: AppClient, _ words: String) async throws -> (
        task: String, conversation: Router.SharedConversation, database: URL
    ) {
        let task = try await app.newSession(cwd: try stack.workspace("Shared"), tools: "app-only")
        #expect(try await app.prompt(task, "Please remember \(words)")["stopReason"]?.stringValue == "end_turn")
        let meta = try #require(stack.traces.meta(task: task))
        let conversation = try #require(Router.sharedConversation(meta))
        let database = URL(filePath: try #require(meta["engine"]?["stateRoot"]?.stringValue)).appending(
            path: "data/sessions", directoryHint: .isDirectory)
        _ = try await app.request("session/close", ["sessionId": .string(task)])
        #expect(try await stack.outcome(of: task) == .finished)
        return (task, conversation, database)
    }

    /// The files of an engine's database that hold `words`.
    static func holding(_ words: String, in database: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: database.path(percentEncoded: false))) ?? []
        return names.filter {
            (try? Data(contentsOf: database.appending(path: $0)))?.range(of: Data(words.utf8)) != nil
        }
    }

    /// A shared engine that stops answering (frozen here) can't hold up deleting conversations, nor every deletion
    /// after them: the pass ends within `deleteWithin` however many are queued, says why once, and keeps them all
    /// queued. Once it answers again (deleting the one it was asked for, late), asking again deletes the rest and
    /// clears its storage, and the engine serves on.
    @Test func aFrozenSharedEngineCantHoldUpDeletingAConversation() async throws {
        let stack = try await Stack.start(port: 47636, modelPort: 47637)
        do {
            let left = Recorder()
            await stack.runtime.observe { event in
                if case .conversationsLeft(let count, let problem) = event { left.add("\(count) \(problem ?? "")") }
            }
            let app = AppClient(port: stack.port)
            defer { app.close() }
            try await app.pairAndInitialize("Frozen")
            let words = ["numbat", "quoll"].map { "\($0)-\(UUID().uuidString.prefix(6))" }
            var tasks: [(task: String, conversation: Router.SharedConversation, database: URL)] = []
            for told in words { tasks.append(try await Self.sharedTask(stack, app, told)) }
            let pid = try Self.enginePID(stack, tasks[0].task)
            kill(pid, SIGSTOP)
            let started = ContinuousClock.now
            await stack.runtime.clearHistory()
            await stack.runtime.conversationsSettled()
            kill(pid, SIGCONT)
            #expect(ContinuousClock.now - started < Router.deleteWithin + .seconds(5), "the deletion waited on Goose")
            #expect(Set(await stack.runtime.pendingConversations) == Set(tasks.map(\.conversation)))
            #expect(left.all == ["2 Goose didn't answer within 10 s"])

            await stack.runtime.retryForgetting()
            await stack.runtime.conversationsSettled()
            #expect(await stack.runtime.pendingConversations.isEmpty)
            #expect(left.all.last == "0 ")
            for told in words { #expect(Self.holding(told, in: tasks[0].database).isEmpty, "\(told)") }
            let next = try await app.newSession(cwd: try stack.workspace("Shared"), tools: "app-only")
            #expect(try await app.prompt(next, "hello")["stopReason"]?.stringValue == "end_turn")
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }

    /// A conversation isn't taken as deleted while a file of the engine's database still holds its words: when
    /// another connection keeps Goose's log in use (here a reader holding its snapshot), Agneta can't clear it, says
    /// so, and keeps the conversation queued as deleted; asked again, only the clearing is tried, and goes through.
    @Test func aConversationStaysQueuedUntilNoFileHoldsIt() async throws {
        let stack = try await Stack.start(port: 47638, modelPort: 47639)
        do {
            let left = Recorder()
            await stack.runtime.observe { event in
                if case .conversationsLeft(let count, let problem) = event { left.add("\(count) \(problem ?? "")") }
            }
            let app = AppClient(port: stack.port)
            defer { app.close() }
            try await app.pairAndInitialize("Held")
            let words = "bilby-\(UUID().uuidString.prefix(6))"
            let shared = try await Self.sharedTask(stack, app, words)
            var holdingOpen = Configuration()
            holdingOpen.allowsUnsafeTransactions = true
            let reader = try DatabaseQueue(
                path: shared.database.appending(path: "sessions.db").path(percentEncoded: false),
                configuration: holdingOpen)
            defer { try? reader.close() }
            try reader.inDatabase { db in
                try db.beginTransaction(.deferred)
                _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions")
            }

            await stack.runtime.clearHistory()
            await stack.runtime.conversationsSettled()
            var deleted = shared.conversation
            deleted.deleted = true
            #expect(await stack.runtime.pendingConversations == [deleted])
            #expect(left.all == ["1 Goose's storage: its log is still in use"])
            #expect(!Self.holding(words, in: shared.database).isEmpty)

            try reader.inDatabase { try $0.rollback() }
            await stack.runtime.retryForgetting()
            await stack.runtime.conversationsSettled()
            #expect(await stack.runtime.pendingConversations.isEmpty)
            #expect(left.all.last == "0 ")
            #expect(Self.holding(words, in: shared.database).isEmpty)
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
            try FileManager.default.removeItem(
                at: EngineHomes.home(root: stack.root.appending(path: "agneta"), key: key))
            let load: JSONValue = [
                "sessionId": .string(session), "cwd": .string(workspace.path(percentEncoded: false)), "mcpServers": []
            ]
            await #expect(throws: RPCError.self) { _ = try await app.request("session/load", load) }
            for _ in 0..<40 where await stack.supervisor.processCount > 0 {
                try await Task.sleep(for: .milliseconds(50))
            }
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
            guard
                let child = try? ChildProcess(
                    executable: "/usr/bin/hdiutil", arguments: arguments, environment: ["PATH": "/usr/bin:/bin"])
            else { return -1 }
            return await child.waitForExit()
        }
        do {
            // A 2 MB volume of its own, filled to the last few kilobytes, where the traces are written.
            try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
            #expect(
                await hdiutil([
                    "create", "-size", "2m", "-fs", "HFS+", "-volname", "agneta-full", image.path(percentEncoded: false)
                ]) == 0)
            #expect(
                await hdiutil([
                    "attach", image.path(percentEncoded: false), "-mountpoint", volume.path(percentEncoded: false),
                    "-nobrowse", "-quiet"
                ]) == 0)
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
            #expect(try await stack.outcome(of: session) == .finished)
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
        // The engine is let go once its start finishes: waited for, not timed (a slow runner took longer than 800 ms).
        for _ in 0..<100 where await stack.engines.opened != stack.engines.released {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await stack.router.sessionCount == 0)
        #expect(await stack.engines.opened == stack.engines.released, "an engine was kept for a session nobody got")
        let other = AppClient(port: stack.port)
        defer { other.close() }
        await #expect(throws: RPCError.self) {
            _ = try await other.request(
                "initialize",
                ["protocolVersion": 1, "clientCapabilities": [:], "_meta": ["agneta": ["token": .string(token)]]])
        }
    }
}
