// The runtime owns what lasts: each task's history with the outcome it really had, grants removed for good, and
// what a task leaves behind going with its history. Run on the real Goose against the fake model, as the app runs.
import Foundation
import Testing

@testable import AgnetaKit

extension RouterIntegrationTests {
    @Test func theRuntimeRecordsWhatHappened() async throws {
        let stack = try await Stack.start(port: 47617, modelPort: 47618)
        do {
            let app = AppClient(port: stack.port)
            defer { app.close() }
            try await app.pairAndInitialize("Recorded")
            let finished = try await app.newSession(cwd: try stack.workspace("R"), tools: "app-only")
            #expect(try await app.prompt(finished, "hello")["stopReason"]?.stringValue == "end_turn")
            _ = try await app.request("session/close", ["sessionId": .string(finished)])
            let stopped = try await app.newSession(cwd: try stack.workspace("R"), tools: "workspace")
            await stack.runtime.stop(task: stopped)
            try await Task.sleep(for: .milliseconds(500))

            // Each outcome as it happened: closed by the app after a good turn, and stopped by the user.
            let history = await stack.runtime.history()
            #expect(
                history.first { $0.id == finished }?.outcome == .finished
                    && history.first { $0.id == finished }?.turns == 1)
            #expect(history.first { $0.id == stopped }?.outcome == .stopped)

            // Removing access is saved: the grant is gone from Agneta's records, not only from the running router.
            let grant = try #require(try stack.runtime.database.grants().values.first { $0.app == "Recorded" })
            try await stack.runtime.revoke(grant: grant.id)
            #expect(try stack.runtime.database.grants().values.allSatisfy { $0.id != grant.id })

            // Keeping no history removes ended tasks, and their traces with them.
            #expect(
                FileManager.default.fileExists(atPath: stack.traces.file(for: finished).path(percentEncoded: false)))
            await stack.runtime.setHistoryDays(0)
            #expect(await stack.runtime.history().isEmpty)
            #expect(
                !FileManager.default.fileExists(atPath: stack.traces.file(for: finished).path(percentEncoded: false)))
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }
}
