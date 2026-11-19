// The app limits' records: limits saved with the grant, a database from before them migrated, each app's usage by
// hour added up, carried over when an unverified app pairs again, removed with its access, and pruned.
import Foundation
import GRDB
import Testing
@testable import AgnetaKit

struct AppUsageStoreTests {
    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agneta-usage-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func limitsAndUsageAreKeptWithTheGrant() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try AgnetaDatabase(file: folder.appending(path: "agneta.sqlite"))
        let limits = AppLimits(spend: .init(max: 5, period: .day), atOnce: 2)
        let grant = Router.Grant(app: "Example App", accounts: ["a1"], limits: limits)
        try database.save(grant, tokenHash: "h1")
        let hour = AppMeter.hour(of: Date())
        try database.addUsage(grant: grant.id, hour: hour, .init(cost: 0.5, inputTokens: 10, outputTokens: 2, turns: 1))
        try database.addUsage(grant: grant.id, hour: hour, .init(cost: 0.25, turns: 1, tasks: 1))
        try database.addUsage(grant: "other", hour: hour.addingTimeInterval(-40 * 86_400), .init(tasks: 1))

        let reopened = try AgnetaDatabase(file: database.file)
        #expect(try reopened.grants()["h1"]?.limits == limits)
        let usage = try reopened.usage(since: hour.addingTimeInterval(-35 * 86_400))
        #expect(usage == [grant.id: [hour: .init(cost: 0.75, inputTokens: 10, outputTokens: 2, turns: 2, tasks: 1)]])
        try reopened.pruneUsage(before: hour.addingTimeInterval(-35 * 86_400))
        #expect(try reopened.usage(since: .distantPast).keys.sorted() == [grant.id])

        // An unverified app pairing again gets a new grant: its usage goes on under it.
        let renewed = Router.Grant(app: "Example App", accounts: ["a1"], limits: limits)
        try reopened.save(renewed, tokenHash: "h2", replacing: grant.id)
        #expect(try reopened.usage(since: .distantPast)[renewed.id]?[hour]?.turns == 2 && reopened.usage(since: .distantPast)[grant.id] == nil)
        // Remove Access takes it away.
        try reopened.deleteGrant(id: renewed.id)
        #expect(try reopened.usage(since: .distantPast).isEmpty)
    }

    /// A database from before app limits opens with its grants unlimited, the migration applied in place.
    @Test func grantsFromBeforeLimitsHaveNone() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "agneta.sqlite")
        let queue = try DatabaseQueue(path: file.path(percentEncoded: false))
        // The schema as it was before this migration.
        try AgnetaDatabase.migrator.migrate(queue, upTo: "2026-11-19-grant-sandbox")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO grants (tokenHash, id, app, verified, accounts, engines, created, tools, folders, sandbox)
                VALUES ('h1', 'g1', 'Old App', 0, '["a1"]', '"all"', ?, 'app-only', '[]', 'contained')
                """, arguments: [Date()])
        }
        try queue.close()
        let database = try AgnetaDatabase(file: file)
        #expect(try database.grants()["h1"]?.limits == AppLimits.none)
        try database.addUsage(grant: "g1", hour: AppMeter.hour(of: Date()), .init(tasks: 1))
        #expect(try database.usage(since: .distantPast)["g1"] != nil)
    }

    /// The runtime records what the router counts, so an app's usage counts after a restart; Remove Access clears it.
    @Test func usageCountsAfterARestartAndGoesWithAccess() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgnetaStore(root: root.appending(path: "agneta", directoryHint: .isDirectory))
        func open() async throws -> AgnetaRuntime {
            try await AgnetaRuntime(.init(store: store, shellTool: URL(filePath: "/usr/bin/true"))) { _ in nil }
        }
        let grant = Router.Grant(app: "Example App", accounts: ["a1"], limits: AppLimits(spend: .init(max: 5, period: .day), newTasks: .init(max: 2, period: .day)))
        var runtime = try await open()
        try runtime.database.save(grant, tokenHash: "h1")
        await runtime.shutdown()

        runtime = try await open()
        let router = runtime.router
        await router.taskCommitted(meter: grant.id, at: await router.reserveTask(meter: grant.id))
        await router.addUsage(meter: grant.id, AppMeter.Usage(cost: 3, inputTokens: 10, outputTokens: 2, turns: 1))
        #expect(await runtime.appStatus(grant: grant.id).today == AppMeter.Usage(cost: 3, inputTokens: 10, outputTokens: 2, turns: 1, tasks: 1))
        for _ in 0..<100 where (try? runtime.database.usage(since: .distantPast)[grant.id]?.values.first?.turns) != 1 { try await Task.sleep(for: .milliseconds(10)) }
        await runtime.shutdown()

        runtime = try await open()
        let restored = await runtime.appStatus(grant: grant.id)
        #expect(restored.today.tasks == 1 && restored.spent == 3 && restored.started == 1)
        try await runtime.revoke(grant: grant.id)
        #expect(try runtime.database.usage(since: .distantPast).isEmpty)
        #expect(await runtime.appStatus(grant: grant.id).today.isEmpty)
        await runtime.shutdown()
    }
}
