// The SQLite store, crash reconciliation and Reset Agneta.
import Darwin
import Foundation
import GRDB
import Testing
@testable import AgnetaKit

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "agneta-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Suite struct StoreTests {
    @Test func accountsAndGrantsRoundTrip() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try AgnetaDatabase(file: folder.appending(path: "agneta.sqlite"))
        var account = AccountRecord(id: "a1", kind: .claude, label: "Claude", email: "me@example.com")
        try database.save(account)
        account.label = "Work"
        account.paused = true
        try database.save(account)
        let grant = Router.Grant(app: "Example App", identifier: "com.example.app", team: "TEAM1", verified: true, accounts: ["a1"],
                                 engines: .only(["goose", "codex"]), tools: .read, folders: ["/tmp/project"])
        try database.save(Router.Grant(app: "Another App", accounts: ["a1"]), tokenHash: "hash2")
        try database.save(grant, tokenHash: "hash1")

        let reopened = try AgnetaDatabase(file: database.file)
        #expect(try reopened.accounts().map(\.label) == ["Work"])
        #expect(try reopened.accounts().first?.paused == true)
        let read = try #require(try reopened.grants()["hash1"])
        #expect(read.accounts == ["a1"] && read.team == "TEAM1" && read.tools == .read && read.folders == ["/tmp/project"] && read.remembered)
        #expect(read.engines == .only(["goose", "codex"]))
        #expect(try reopened.grants()["hash2"]?.engines == .all)
        try reopened.deleteGrant(id: grant.id)
        try reopened.deleteGrant(id: try #require(try reopened.grants()["hash2"]).id)
        try reopened.deleteAccount("a1")
        #expect(try reopened.grants().isEmpty)
        #expect(try reopened.accounts().isEmpty)
        let mode = try FileManager.default.attributesOfItem(atPath: database.file.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func taskHistoryRecordsTurnsUsageAndOutcome() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try AgnetaDatabase(file: folder.appending(path: "agneta.sqlite"))
        try database.taskStarted(TaskRecord(id: "s1", app: "Example App", account: "a1", title: "Naming", started: Date()))
        try database.turnStarted(task: "s1")
        try database.usage(task: "s1", usedTokens: 1_200, cost: 0.10)
        try database.turnEnded(task: "s1", stopReason: "end_turn")
        try database.turnStarted(task: "s1")
        try database.usage(task: "s1", usedTokens: nil, cost: 0.25)
        try database.turnEnded(task: "s1", stopReason: "end_turn")
        #expect(try database.history().isEmpty) // still running
        try database.taskEnded("s1", outcome: .finished)
        try database.taskEnded("s1", outcome: .stopped) // a second end doesn't overwrite the first

        let record = try #require(try database.history().first)
        #expect(record.turns == 2)
        #expect(record.usedTokens == 1_200) // unknown usage keeps the last known value
        #expect(record.cost == 0.25)
        #expect(record.outcome == .finished)
    }

    @Test func unfinishedTasksBecomeInterruptedAndRetentionPrunes() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try AgnetaDatabase(file: folder.appending(path: "agneta.sqlite"))
        let now = Date()
        try database.taskStarted(TaskRecord(id: "old", app: "Example App", account: "a", title: "Old", started: now.addingTimeInterval(-40 * 86_400)))
        try database.taskEnded("old", outcome: .finished, at: now.addingTimeInterval(-40 * 86_400 + 60))
        try database.taskStarted(TaskRecord(id: "crashed", app: "Example App", account: "a", title: "Was running", started: now.addingTimeInterval(-60)))
        try database.turnStarted(task: "crashed")

        #expect(try database.interruptUnfinishedTasks(at: now) == 1)
        #expect(try database.history().first { $0.id == "crashed" }?.outcome == .interrupted)
        #expect(try database.pruneHistory(olderThan: 30, now: now) == ["old"])
        #expect(try database.history().map(\.id) == ["crashed"])
        try database.clearHistory()
        #expect(try database.history().isEmpty)
    }

    /// A grant saved under a new token (the app paired again) replaces its row: one grant, the new token's.
    @Test func aRenewedGrantReplacesItsRow() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try AgnetaDatabase(file: folder.appending(path: "agneta.sqlite"))
        var grant = Router.Grant(app: "Again", accounts: ["a1"])
        try database.save(grant, tokenHash: "old")
        grant.accounts = ["a1", "a2"]
        try database.save(grant, tokenHash: "new")
        #expect(try database.grants().keys.sorted() == ["new"])
        #expect(try database.grants()["new"]?.accounts == ["a1", "a2"])
    }

    /// Before 1.0 there are no migrations: a database made with another schema (an earlier build's, a later one's) is
    /// refused and left exactly as it was, so the user resets.
    @Test func refusesADatabaseFromAnotherSchema() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "agneta.sqlite")
        try AgnetaDatabase(file: file).close()
        let queue = try DatabaseQueue(path: file.path(percentEncoded: false))
        try queue.write { try $0.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v5')") }
        try queue.close()

        #expect(throws: StoreError.otherSchema(file: "agneta.sqlite")) { try AgnetaDatabase(file: file) }
        let check = try DatabaseQueue(path: file.path(percentEncoded: false))
        #expect(try check.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }.contains("v5"))
    }
}

@Suite struct ReconciliationTests {
    /// A recorded engine still alive is stopped with its group; a record whose start time
    /// doesn't match (a reused pid) is left alone.
    @Test func reapsOnlyTheRecordedProcess() async throws {
        let sleeper = try ChildProcess(executable: "/bin/sleep", arguments: ["30"], environment: [:])
        let other = try ChildProcess(executable: "/bin/sleep", arguments: ["30"], environment: [:])
        defer { killpg(other.pid, SIGKILL); killpg(sleeper.pid, SIGKILL) }
        let started = try #require(EngineReaper.startTime(of: sleeper.pid))
        let otherStarted = try #require(EngineReaper.startTime(of: other.pid))
        let records = [EngineRecord(pid: sleeper.pid, started: started, account: "a"),
                       EngineRecord(pid: other.pid, started: otherStarted - 5, account: "a")]
        #expect(EngineReaper.isAlive(records[0]))
        #expect(!EngineReaper.isAlive(records[1]))

        let stopped = await EngineReaper.reap(records)
        #expect(stopped == [sleeper.pid])
        #expect(await sleeper.waitForExit() != 0)
        #expect(kill(other.pid, 0) == 0) // still running
    }

    @Test func ledgerRecordsAndForgetsEngines() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try AgnetaDatabase(file: folder.appending(path: "agneta.sqlite"))
        database.engineStarted(pid: getpid(), account: "a")
        #expect(try database.recordedEngines().map(\.pid) == [getpid()])
        database.engineStopped(pid: getpid())
        #expect(try database.recordedEngines().isEmpty)
    }
}

@Suite struct ResetTests {
    @Test func wipesKeychainAndFoldersAndResumesAfterInterruption() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appending(path: "com.example.agneta.test", directoryHint: .isDirectory)
        let caches = folder.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Accounts/a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let keychain = Keychain(service: "com.objectivecoder.agneta.tests.\(UUID().uuidString)")
        try keychain.set("secret-1", for: "a")
        try keychain.set("secret-2", for: "b")
        defer { keychain.deleteAll() }

        let reset = Reset(root: root, folders: [root, caches], keychain: keychain)
        try reset.begin()
        #expect(reset.marker.deletingLastPathComponent() == folder)
        try reset.wipe()
        // Interrupted here: the marker survives the wipe, so the next launch resumes.
        #expect(Reset(root: root, folders: [root, caches], keychain: keychain).isInterrupted)
        try reset.wipe() // repeating is safe
        reset.finish()

        #expect(!reset.isInterrupted)
        #expect(keychain.get("a") == nil && keychain.get("b") == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: caches.path(percentEncoded: false)))
    }
}

@Suite struct EngineHomeTests {
    @Test func homesFollowTheirTasksAccountsAndAge() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agneta-homes-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let traces = Traces(folder: root.appending(path: "Traces", directoryHint: .isDirectory))
        func task(_ id: String, key: String, dedicated: Bool = true) throws {
            let trace = traces.open(task: id, lease: key, engineSession: "e")
            trace.writer.record("meta", ["engine": ["key": .string(key), "dedicated": .bool(dedicated)]])
            traces.close(task: id)
            try FileManager.default.createDirectory(at: EngineHomes.home(root: root, key: key).appending(path: "goose"), withIntermediateDirectories: true)
        }
        try task("t1", key: "acct/one")
        try task("t2", key: "acct/two")
        try task("t3", key: "other/three")
        let orphan = EngineHomes.home(root: root, key: "acct/orphan")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        let running = EngineHomes.home(root: root, key: "acct/running")
        try FileManager.default.createDirectory(at: running, withIntermediateDirectories: true)
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

        // Retention: a task's home goes with it.
        EngineHomes.remove(tasks: ["t1"], traces: traces, root: root)
        #expect(!exists(EngineHomes.home(root: root, key: "acct/one")) && exists(EngineHomes.home(root: root, key: "acct/two")))
        // A sweep removes only unreferenced, old, not-running homes.
        #expect(EngineHomes.sweep(root: root, traces: traces, before: Date().addingTimeInterval(-60), keep: []).isEmpty) // all too new
        let removed = EngineHomes.sweep(root: root, traces: traces, before: Date().addingTimeInterval(60), keep: ["acct/running"])
        #expect(removed == ["acct-orphan"]) // acct-one already went with its task
        #expect(!exists(orphan) && exists(running) && exists(EngineHomes.home(root: root, key: "acct/two")))
        // Sign-out removes the account's homes only.
        EngineHomes.remove(account: "acct", root: root)
        #expect(!exists(EngineHomes.home(root: root, key: "acct/two")) && !exists(running))
        #expect(exists(EngineHomes.home(root: root, key: "other/three")))
    }
}

/// Isolated instances never share a Keychain service (Reset in one would delete the other's items) or a port, and
/// never take the user's own Agneta's ports.
@Test func isolatedInstancesKeepToThemselves() throws {
    let a = IsolatedInstance.keychainService(bundleID: "com.example.dev", home: URL(filePath: "/tmp/one", directoryHint: .isDirectory))
    let b = IsolatedInstance.keychainService(bundleID: "com.example.dev", home: URL(filePath: "/tmp/two", directoryHint: .isDirectory))
    #expect(a != b && a.hasPrefix("com.example.dev.isolated."))
    #expect(a == IsolatedInstance.keychainService(bundleID: "com.example.dev", home: URL(filePath: "/tmp/x/../one/", directoryHint: .isDirectory)))
    #expect(try IsolatedInstance.port("47641") == 47641)
    for bad in [nil, "", "abc", "80", "65534", "-1", "47331", "47329", "47321", "47333"] as [String?] {
        #expect(throws: IsolatedInstance.Problem.self, "\(bad ?? "nil")") { _ = try IsolatedInstance.port(bad) }
    }
}

/// The data folder is owner-only after every open, even one an older build (or a folder made along the way) left
/// readable by others.
@Test func theDataFolderIsOwnerOnly() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "agneta-perms-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appending(path: "Accounts/chatgpt"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path(percentEncoded: false))
    let database = try AgnetaStore(root: root).open()
    try database.close()
    let mode = try FileManager.default.attributesOfItem(atPath: root.path(percentEncoded: false))[.posixPermissions] as? Int
    #expect(mode == 0o700)
}
