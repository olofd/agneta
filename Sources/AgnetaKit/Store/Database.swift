// Agneta's records in one SQLite file: accounts, app grants and each app's
// usage by hour, task history, the engines it started, and settings. GRDB with a single writer.
// Before 1.0 there's no compatibility promise: the schema may change in place
// under a new id, and a database made with another id is left untouched and
// refused, so the user resets (docs/ARCHITECTURE.md). Small forward migrations
// are added where they're cheap (the sandbox modes added two). Secrets
// never land here: API keys are in the Keychain, subscription tokens in each
// account's folder, app tokens only as SHA-256 hashes.
import Foundation
import GRDB

public enum StoreError: Error, Equatable, CustomStringConvertible {
    /// The file was made by a build of Agneta with another schema; nothing was changed.
    case otherSchema(file: String)

    public var description: String {
        switch self {
        case .otherSchema: "Agneta's data was saved by another build of Agneta, which this one can't read."
        }
    }
}

/// How a task ended, as people read it in Activity.
public enum TaskOutcome: String, Codable, Sendable {
    case finished, stopped, failed
    /// Running when Agneta quit or crashed; nothing is replayed.
    case interrupted
}

/// One task in Activity's history.
public struct TaskRecord: Sendable, Equatable, Identifiable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sessions"
    public var id: String
    public var app: String
    public var appIdentifier: String?
    public var account: String
    public var title: String
    public var started: Date
    public var ended: Date?
    public var outcome: TaskOutcome?
    public var turns: Int
    public var usedTokens: Int?
    /// Estimated or reported cost in US dollars, cumulative for the task; unknown stays nil.
    public var cost: Double?

    public init(
        id: String, app: String, appIdentifier: String? = nil, account: String, title: String, started: Date,
        ended: Date? = nil, outcome: TaskOutcome? = nil, turns: Int = 0, usedTokens: Int? = nil, cost: Double? = nil
    ) {
        self.id = id
        self.app = app
        self.appIdentifier = appIdentifier
        self.account = account
        self.title = title
        self.started = started
        self.ended = ended
        self.outcome = outcome
        self.turns = turns
        self.usedTokens = usedTokens
        self.cost = cost
    }
}

/// An engine process Agneta started, recorded so a crash can't orphan it.
public struct EngineRecord: Sendable, Equatable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "engines"
    public var pid: Int32
    /// The process's start time (seconds since 1970, microsecond precision): with the pid, its identity.
    public var started: Double
    public var account: String
}

public final class AgnetaDatabase: Sendable {
    public let file: URL
    private let queue: DatabaseQueue

    /// Opens the database, creating it if needed. One made with another schema is refused, untouched.
    public init(file: URL) throws {
        self.file = file
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "agneta"
        queue = try DatabaseQueue(path: file.path(percentEncoded: false), configuration: configuration)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false))
        let migrator = Self.migrator
        try queue.read { db in
            if try migrator.hasBeenSuperseded(db) { throw StoreError.otherSchema(file: file.lastPathComponent) }
        }
        try migrator.migrate(queue)
    }

    /// Opens an existing store for inspection. Only the host creates or migrates it.
    public init(reading file: URL) throws {
        self.file = file
        var configuration = Configuration()
        configuration.readonly = true
        // The host may be writing: wait out its lock for up to 5 s rather than
        // fail a `tasks` call with "database is locked" (the 0.7.0 review).
        configuration.busyMode = .timeout(5)
        queue = try DatabaseQueue(path: file.path(percentEncoded: false), configuration: configuration)
        let migrator = Self.migrator
        try queue.read { db in
            guard try migrator.hasCompletedMigrations(db), try !migrator.hasBeenSuperseded(db) else {
                throw StoreError.otherSchema(file: file.lastPathComponent)
            }
        }
    }

    // MARK: Schema

    /// The schema's id: a new one whenever the schema changes, until 1.0.
    static let schema = "2026-11-18"

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(schema) { db in
            try db.create(table: "accounts") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("label", .text).notNull()
                t.column("email", .text)
                t.column("model", .text)
                t.column("created", .datetime).notNull()
                t.column("paused", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "grants") { t in
                t.primaryKey("tokenHash", .text)
                t.column("id", .text).notNull().unique()
                t.column("app", .text).notNull()
                t.column("identifier", .text)
                t.column("team", .text)
                t.column("verified", .boolean).notNull()
                // The providers (account ids) and engines ("all", or engine ids) the app may use (Access).
                t.column("accounts", .jsonText).notNull()
                t.column("engines", .jsonText).notNull()
                t.column("created", .datetime).notNull()
                t.column("tools", .text).notNull()
                t.column("folders", .jsonText).notNull()
            }
            try db.create(table: "sessions") { t in
                t.primaryKey("id", .text)
                t.column("app", .text).notNull()
                t.column("appIdentifier", .text)
                t.column("account", .text).notNull()
                t.column("title", .text).notNull()
                t.column("started", .datetime).notNull().indexed()
                t.column("ended", .datetime).indexed()
                t.column("outcome", .text)
                t.column("turns", .integer).notNull().defaults(to: 0)
                t.column("usedTokens", .integer)
                t.column("cost", .double)
            }
            try db.create(table: "turns") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session", .text).notNull().indexed().references("sessions", onDelete: .cascade)
                t.column("started", .datetime).notNull()
                t.column("ended", .datetime)
                t.column("stopReason", .text)
                t.column("costAtStart", .double)
                t.column("cost", .double)
            }
            try db.create(table: "engines") { t in
                t.primaryKey("pid", .integer)
                t.column("started", .double).notNull()
                t.column("account", .text).notNull()
            }
            try db.create(table: "settings") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        // An earlier development build's flag, since replaced by the grant's sandbox (below): the column is read by
        // nothing, but the migration stays, so a database that ran it still opens.
        migrator.registerMigration("2026-11-19-developer-access") { db in
            try db.alter(table: "grants") { t in
                t.add(column: "developerAccess", .boolean).notNull().defaults(to: false)
            }
        }
        // The most each app's tasks may do (Router.Grant.sandbox). Grants made before it were approved as contained, so
        // they stay contained; a new pairing writes what the user chose (developer access unless they choose less).
        migrator.registerMigration("2026-11-19-grant-sandbox") { db in
            try db.alter(table: "grants") { t in
                t.add(column: "sandbox", .text).notNull().defaults(to: Sandbox.contained.rawValue)
            }
        }
        // The limits the user sets for each app (AppLimits), as JSON so further kinds need no migration; grants made
        // before have none. And each app's usage by hour (AppMeter), kept 35 days whatever task history keeps.
        migrator.registerMigration("2026-11-20-app-limits") { db in
            try db.alter(table: "grants") { t in t.add(column: "limits", .jsonText).notNull().defaults(to: "{}") }
            try db.create(table: "app_usage") { t in
                t.column("grantID", .text).notNull()
                t.column("hour", .datetime).notNull()
                t.column("cost", .double).notNull().defaults(to: 0)
                t.column("inputTokens", .integer).notNull().defaults(to: 0)
                t.column("outputTokens", .integer).notNull().defaults(to: 0)
                t.column("turns", .integer).notNull().defaults(to: 0)
                t.column("tasks", .integer).notNull().defaults(to: 0)
                t.primaryKey(["grantID", "hour"])
            }
        }
        // Turns on API keys whose models had no price (AppMeter.Usage.unpriced). A migration of its own: a database that
        // ran the one above already won't run it again.
        migrator.registerMigration("2026-11-21-app-usage-unpriced") { db in
            try db.alter(table: "app_usage") { t in t.add(column: "unpriced", .integer).notNull().defaults(to: 0) }
        }
        return migrator
    }

    // MARK: Accounts

    public func accounts() throws -> [AccountRecord] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM accounts ORDER BY created").compactMap { row in
                guard let kind = AccountKind(rawValue: row["kind"]) else { return nil }
                return AccountRecord(
                    id: row["id"], kind: kind, label: row["label"], email: row["email"], model: row["model"],
                    created: row["created"],
                    paused: row["paused"])
            }
        }
    }

    public func save(_ account: AccountRecord) throws {
        try queue.write { db in try Self.insert(account, db) }
    }

    private static func insert(_ account: AccountRecord, _ db: GRDB.Database) throws {
        try db.execute(
            sql: """
                INSERT INTO accounts (id, kind, label, email, model, created, paused) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, label = excluded.label, email = excluded.email,
                    model = excluded.model, paused = excluded.paused
                """,
            arguments: [
                account.id, account.kind.rawValue, account.label, account.email, account.model, account.created,
                account.paused
            ])
    }

    public func deleteAccount(_ id: String) throws {
        try queue.write { db in try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [id]) }
    }

    // MARK: Grants

    /// Token hash → grant.
    public func grants() throws -> [String: Router.Grant] {
        try queue.read { db in
            var grants: [String: Router.Grant] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM grants") {
                let accounts =
                    (try? JSONDecoder().decode([String].self, from: Data((row["accounts"] as String).utf8))) ?? []
                let folders =
                    (try? JSONDecoder().decode([String].self, from: Data((row["folders"] as String).utf8))) ?? []
                let engines =
                    (try? JSONDecoder().decode(EngineAllowance.self, from: Data((row["engines"] as String).utf8)))
                    ?? .only([])
                // Limits that can't be read would leave the app unlimited: the grant isn't restored rather than that.
                guard
                    let limits = try? JSONDecoder().decode(
                        AppLimits.self, from: Data(((row["limits"] as String?) ?? "{}").utf8))
                else { continue }
                grants[row["tokenHash"]] = Router.Grant(
                    id: row["id"], app: row["app"], identifier: row["identifier"], team: row["team"],
                    verified: row["verified"], accounts: accounts, engines: engines, created: row["created"],
                    tools: SessionPolicy.Tools(rawValue: row["tools"]) ?? .appOnly, folders: folders,
                    sandbox: Sandbox(rawValue: row["sandbox"] ?? "") ?? .contained, limits: limits)
            }
            return grants
        }
    }

    /// Saves a grant, in the same transaction removing the grant `replacing` names (an app's earlier one), whose usage
    /// goes on under this one: pairing again doesn't reset what an app has spent.
    public func save(_ grant: Router.Grant, tokenHash: String, replacing: String? = nil) throws {
        try queue.write { db in
            if let replacing {
                try db.execute(sql: "DELETE FROM grants WHERE id = ?", arguments: [replacing])
                try db.execute(
                    sql: "UPDATE app_usage SET grantID = ? WHERE grantID = ?", arguments: [grant.id, replacing])
            }
            try Self.insert(grant, hash: tokenHash, db)
        }
    }

    private static func insert(_ grant: Router.Grant, hash: String, _ db: GRDB.Database) throws {
        let accounts = String(decoding: try JSONEncoder().encode(grant.accounts), as: UTF8.self)
        let folders = String(decoding: try JSONEncoder().encode(grant.folders), as: UTF8.self)
        let engines = String(decoding: try JSONCoding.encode(grant.engines), as: UTF8.self)
        let limits = String(decoding: try JSONEncoder().encode(grant.limits), as: UTF8.self)
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO grants (tokenHash, id, app, identifier, team, verified, accounts, created, tools, folders, engines, sandbox, limits)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                hash, grant.id, grant.app, grant.identifier, grant.team, grant.verified, accounts, grant.created,
                grant.tools.rawValue, folders, engines, grant.sandbox.rawValue, limits
            ])
    }

    /// Removes a grant (Remove Access), and its app's usage with it.
    public func deleteGrant(id: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM grants WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM app_usage WHERE grantID = ?", arguments: [id])
        }
    }

    // MARK: App usage

    /// Adds to an app's usage in the hour `hour` starts (AppMeter.hour), only while its grant is saved: a turn that
    /// ended after Remove Access (or an Allow Once grant's, kept in memory) leaves nothing behind.
    public func addUsage(grant: String, hour: Date, _ usage: AppMeter.Usage) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_usage (grantID, hour, cost, inputTokens, outputTokens, turns, tasks, unpriced)
                    SELECT ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM grants WHERE id = ?)
                    ON CONFLICT(grantID, hour) DO UPDATE SET cost = cost + excluded.cost, inputTokens = inputTokens + excluded.inputTokens,
                        outputTokens = outputTokens + excluded.outputTokens, turns = turns + excluded.turns, tasks = tasks + excluded.tasks,
                        unpriced = unpriced + excluded.unpriced
                    """,
                arguments: [
                    grant, hour, usage.cost, usage.inputTokens, usage.outputTokens, usage.turns, usage.tasks,
                    usage.unpriced, grant
                ])
        }
    }

    /// Grants whose saved limits can't be read: they aren't restored, so their apps pair again (`grants()`).
    public func unreadableLimits() throws -> [String] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, limits FROM grants").compactMap { row in
                (try? JSONDecoder().decode(AppLimits.self, from: Data(((row["limits"] as String?) ?? "{}").utf8)))
                    == nil ? row["id"] : nil
            }
        }
    }

    /// Each app's usage by hour, from `since` on.
    public func usage(since: Date) throws -> [String: [Date: AppMeter.Usage]] {
        try queue.read { db in
            var usage: [String: [Date: AppMeter.Usage]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM app_usage WHERE hour >= ?", arguments: [since]) {
                usage[row["grantID"], default: [:]][row["hour"]] = AppMeter.Usage(
                    cost: row["cost"], inputTokens: row["inputTokens"],
                    outputTokens: row["outputTokens"], turns: row["turns"], tasks: row["tasks"],
                    unpriced: (row["unpriced"] as Int?) ?? 0)
            }
            return usage
        }
    }

    /// Forgets app usage older than `date`.
    public func pruneUsage(before date: Date) throws {
        try queue.write { db in try db.execute(sql: "DELETE FROM app_usage WHERE hour < ?", arguments: [date]) }
    }

    // MARK: Task history

    public func taskStarted(_ task: TaskRecord) throws {
        try queue.write { db in try task.insert(db, onConflict: .ignore) }
    }

    /// A finished task resumed with `session/load` is running again.
    public func taskResumed(_ task: String) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE sessions SET ended = NULL, outcome = NULL WHERE id = ?", arguments: [task])
        }
    }

    public func turnStarted(task: String, at date: Date = Date()) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO turns (session, started, costAtStart) SELECT id, ?, cost FROM sessions WHERE id = ?",
                arguments: [date, task])
        }
    }

    public func turnEnded(task: String, stopReason: String, at date: Date = Date()) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    UPDATE turns SET ended = ?, stopReason = ?,
                        cost = (SELECT cost FROM sessions WHERE id = turns.session) - COALESCE(costAtStart, 0)
                    WHERE id = (SELECT MAX(id) FROM turns WHERE session = ? AND ended IS NULL)
                    """, arguments: [date, stopReason, task])
            try db.execute(sql: "UPDATE sessions SET turns = turns + 1 WHERE id = ?", arguments: [task])
        }
    }

    /// Latest cumulative usage reported for a task. Unknown values leave what's stored.
    public func usage(task: String, usedTokens: Int?, cost: Double?) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET usedTokens = COALESCE(?, usedTokens), cost = COALESCE(?, cost) WHERE id = ?",
                arguments: [usedTokens, cost, task])
        }
    }

    public func taskEnded(_ task: String, outcome: TaskOutcome, at date: Date = Date()) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET ended = ?, outcome = ? WHERE id = ? AND ended IS NULL",
                arguments: [date, outcome.rawValue, task])
        }
    }

    /// The ids of every ended task, whatever its age: whether a trace's task is still running can't be read from a page
    /// of history (agneta-diag listed every task older than its limit as running).
    public func endedTaskIDs() throws -> Set<String> {
        try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM sessions WHERE ended IS NOT NULL"))
        }
    }

    /// Ended tasks, newest first.
    public func history(limit: Int = 500) throws -> [TaskRecord] {
        try queue.read { db in
            try TaskRecord.fetchAll(
                db, sql: "SELECT * FROM sessions WHERE ended IS NOT NULL ORDER BY started DESC LIMIT ?",
                arguments: [limit])
        }
    }

    /// Tasks still marked running from an earlier launch become "interrupted". Returns how many.
    @discardableResult
    public func interruptUnfinishedTasks(at date: Date = Date()) throws -> Int {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE turns SET ended = ?, stopReason = 'interrupted' WHERE ended IS NULL", arguments: [date])
            try db.execute(
                sql: "UPDATE sessions SET ended = ?, outcome = 'interrupted' WHERE ended IS NULL", arguments: [date])
            return db.changesCount
        }
    }

    /// Deletes ended tasks that started more than `days` ago. Returns their ids, so their traces go too.
    @discardableResult
    public func pruneHistory(olderThan days: Int, now: Date = Date()) throws -> [String] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return try queue.write { db in
            let ids = try String.fetchAll(
                db, sql: "SELECT id FROM sessions WHERE ended IS NOT NULL AND started < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM sessions WHERE ended IS NOT NULL AND started < ?", arguments: [cutoff])
            return ids
        }
    }

    /// Deletes every ended task. Returns their ids, so their traces go too.
    @discardableResult
    public func clearHistory() throws -> [String] {
        try queue.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM sessions WHERE ended IS NOT NULL")
            try db.execute(sql: "DELETE FROM sessions WHERE ended IS NOT NULL")
            return ids
        }
    }

    // MARK: Engines

    public func recordEngine(_ engine: EngineRecord) throws {
        try queue.write { db in try engine.save(db) }
    }

    public func forgetEngine(pid: Int32) throws {
        try queue.write { db in try db.execute(sql: "DELETE FROM engines WHERE pid = ?", arguments: [pid]) }
    }

    public func recordedEngines() throws -> [EngineRecord] {
        try queue.read { db in try EngineRecord.fetchAll(db) }
    }

    // MARK: Settings

    public func setting(_ key: String) throws -> String? {
        try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
    }

    public func set(_ value: String?, for key: String) throws {
        try queue.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
            }
        }
    }

    /// Closes the file (before Reset deletes it).
    public func close() throws { try queue.close() }
}

extension AgnetaDatabase: EngineLedger {
    public func engineStarted(pid: pid_t, account: String) {
        guard let started = EngineReaper.startTime(of: pid) else { return }
        try? recordEngine(EngineRecord(pid: pid, started: started, account: account))
    }

    public func engineStopped(pid: pid_t) { try? forgetEngine(pid: pid) }
}
