// The limits the user sets for each app (AppLimits), held: what it spends on API keys, its turns at once and its new
// tasks, counted per grant (Grant.meter) in an AppMeter. Every check that can refuse work is synchronous and happens
// before the first wait of the request it guards, and again after each wait (the app may have spent meanwhile, or
// the user lowered a limit), so a burst of requests can't all pass one check. At a limit the work is refused with
// `-32016`, or for a running turn stopped as a policy limit stops it, and Agneta's UI hears of it once.
import Foundation

/// A limit that stopped a turn: the app's own policy's (`setBy: "app"`) or one the user set for the app (`"user"`),
/// as the prompt's result reports it in `agneta/limit`.
struct LimitHit: Sendable {
    var limit: String
    var value: JSONValue
    var setBy = "app"
    var extra: [String: JSONValue] = [:]

    var report: JSONValue {
        var fields: [String: JSONValue] = ["limit": .string(limit), "value": value, "setBy": .string(setBy)]
        fields.merge(extra) { _, new in new }
        return .object(fields)
    }
}

/// A limit the user set for an app stopped its work, for Agneta's UI and log: ids, numbers and words, no content.
public struct AppLimitNotice: Sendable, Equatable {
    public var grant: String
    public var app: String
    /// `spend` or `newTasks`.
    public var limit: String
    /// The limit as the user set it: "$5 a day".
    public var summary: String
    /// What's been used: "$5.04 today", "10 this hour".
    public var used: String
    /// When it resets, when known.
    public var resetsAt: Date?
    /// In words: "at midnight".
    public var resets: String?

    public init(
        grant: String, app: String, limit: String, summary: String, used: String, resetsAt: Date?, resets: String?
    ) {
        self.grant = grant
        self.app = app
        self.limit = limit
        self.summary = summary
        self.used = used
        self.resetsAt = resetsAt
        self.resets = resets
    }
}

extension Router {
    static let appLimitReached: Int64 = -32016

    /// What the app checking against a limit is doing.
    enum NewTaskCheck {
        /// Not starting a task (a prompt, a load): only spending is checked.
        case none
        /// About to start one, not yet counted: refused when the count is at the limit.
        case beforeCounting
        /// Starting one already counted (after a wait): refused only when the count is over it.
        case counted
    }

    /// The limits of the grant `meter` names, as they are now.
    func limits(meter: String) -> AppLimits { tokens.values.first { $0.meter == meter }?.limits ?? .none }

    /// Whether a turn on this account counts toward a spending limit: everything but a plan, which isn't charged per
    /// call. An account Agneta doesn't know counts.
    func countsSpend(_ account: String) -> Bool { accounts[account]?.kind.subscription == nil }

    func meter(_ id: String) -> AppMeter { meters[id] ?? AppMeter() }

    /// What the app has spent in its spending limit's period, its running turns' cost so far included.
    func spent(meter id: String, period: AppLimits.Period) -> Double {
        let settled = meter(id).spent(period, now: now(), calendar: calendar)
        return runningTurns.reduce(settled) { sum, entry in
            guard entry.value.meter == id, entry.value.counted else { return sum }
            return sum
                + max(
                    0,
                    (traces?.session(entry.key)?.progress.taskCost ?? entry.value.costAtStart) - entry.value.costAtStart
                )
        }
    }

    /// The app's turns running now.
    func running(meter id: String) -> Int { runningTurns.values.count { $0.meter == id } }

    static func timestamp(_ date: Date?) -> JSONValue { date.map { .string(TraceWriter.timestamp($0)) } ?? .null }

    /// Why the app's limits refuse this now, or nil. Spending applies on accounts charged per call only.
    func appLimitRefusal(_ grant: Grant, account: String, newTask: NewTaskCheck) -> RPCError? {
        let limits = grant.limits, at = now()
        if let spend = limits.spend, countsSpend(account) {
            let used = spent(meter: grant.meter, period: spend.period)
            if used >= spend.max {
                let resetsAt = meter(grant.meter).resetsAt(spend.period, now: at, calendar: calendar)
                return appLimitError(
                    grant, limit: "spend", summary: "\(AppLimits.dollars(spend.max)) \(AppLimits.per(spend.period))",
                    max: .double(spend.max), used: .double(used),
                    usedWords: AppLimits.cents(used) + Self.this(spend.period),
                    period: spend.period, whenReached: spend.whenReached, resetsAt: resetsAt)
            }
        }
        if let starts = limits.newTasks, newTask != .none {
            let used = meter(grant.meter).tasks(starts.period, now: at, calendar: calendar)
            if newTask == .beforeCounting ? used >= starts.max : used > starts.max {
                let resetsAt = meter(grant.meter).resetsAt(starts.period, now: at, calendar: calendar)
                return appLimitError(
                    grant, limit: "newTasks",
                    summary: limits.parts.last { $0.contains("new task") } ?? "\(starts.max) new tasks",
                    max: .int(Int64(starts.max)), used: .int(Int64(used)),
                    usedWords: "\(used)" + Self.this(starts.period),
                    period: starts.period, whenReached: starts.whenReached, resetsAt: resetsAt)
            }
        }
        return nil
    }

    static func this(_ period: AppLimits.Period) -> String {
        switch period {
        case .hour: " in the last hour"
        case .day: " today"
        case .week: " this week"
        case .month: " this month"
        }
    }

    /// `-32016`, said as the user's choice, with when it resets; and Agneta's UI hears of it.
    func appLimitError(
        _ grant: Grant, limit: String, summary: String, max: JSONValue, used: JSONValue, usedWords: String,
        period: AppLimits.Period, whenReached: AppLimits.WhenReached, resetsAt: Date?
    ) -> RPCError {
        let resets = resetsAt.map { AppLimits.resets(at: $0, now: now(), calendar: calendar) }
        let again =
            resets.map { limit == "spend" || period != .hour ? " It resets \($0)." : " A new task can start \($0)." }
            ?? ""
        onEvent(
            .appLimitReached(
                AppLimitNotice(
                    grant: grant.meter, app: grant.app, limit: limit, summary: summary, used: usedWords,
                    resetsAt: resetsAt, resets: resets)))
        return RPCError(
            code: Self.appLimitReached, message: "\(grant.app)'s limit in Agneta is reached: \(summary).\(again)",
            data: [
                "agneta": [
                    "appLimit": [
                        "limit": .string(limit), "max": max, "used": used, "period": .string(period.rawValue),
                        "resetsAt": Self.timestamp(resetsAt), "whenReached": .string(whenReached.rawValue)
                    ]
                ]
            ])
    }

    // MARK: New tasks

    /// Counts a new task before its engine starts, so concurrent starts can't all pass the check. Returns when it was
    /// counted, for `refundTask` if it doesn't start after all.
    func reserveTask(meter id: String) -> Date {
        let at = now()
        meters[id, default: AppMeter()].taskStarted(at: at)
        return at
    }

    func refundTask(meter id: String, at date: Date) { meters[id]?.taskRefunded(startedAt: date) }

    /// An app paired again under a new grant: what counted toward the old one counts toward the new one from now on,
    /// its running turns, waiting turns and Allow Once grants included.
    func recount(from old: String, to new: String) {
        if let usage = meters.removeValue(forKey: old) { meters[new] = usage }
        for (id, session) in sessions where session.meter == old { sessions[id]?.meter = new }
        for (id, turn) in runningTurns where turn.meter == old { runningTurns[id]?.meter = new }
        for index in waiting.indices where waiting[index].meter == old { waiting[index].meter = new }
        for (hash, grant) in tokens where grant.countsAs == old { tokens[hash]?.countsAs = new }
        for (appID, app) in apps where app.grant?.countsAs == old { apps[appID]?.grant?.countsAs = new }
    }

    /// The task counted at `date` started: it's saved with the app's usage.
    func taskCommitted(meter id: String, at date: Date) {
        onEvent(.appUsage(grant: id, hour: AppMeter.hour(of: date), usage: AppMeter.Usage(tasks: 1)))
    }

    // MARK: Turns

    /// A turn's usage joins its app's meter, in the same step that takes it out of the running turns: never counted
    /// twice, never lost. Its cost counts only on an account charged per call.
    func meterTurn(_ id: String, _ turn: RunningTurn) {
        guard turn.began else { return }
        let cost =
            turn.counted ? max(0, (traces?.session(id)?.progress.taskCost ?? turn.costAtStart) - turn.costAtStart) : 0
        let unpriced = turn.counted && cost == 0 && turn.modelCalls > 0
        if unpriced {
            traces?.session(id)?.writer.record(
                "lifecycle", ["event": "unpriced", "modelCalls": .int(Int64(turn.modelCalls))])
        }
        addUsage(
            meter: turn.meter,
            AppMeter.Usage(
                cost: cost, inputTokens: turn.tokens.input, outputTokens: turn.tokens.output, turns: 1,
                unpriced: unpriced ? 1 : 0))
    }

    func addUsage(meter id: String, _ usage: AppMeter.Usage) {
        guard !usage.isEmpty else { return }
        let at = now()
        meters[id, default: AppMeter()].add(usage, at: at)
        onEvent(.appUsage(grant: id, hour: AppMeter.hour(of: at), usage: usage))
    }

    /// The spending limit a running turn's app has reached, or nil: checked against the limit as it is now, so a limit
    /// raised meanwhile lets the turn go on. Every running turn of the app it counts finds it at its own watchdog's next
    /// check (within half a second); nothing is written into another session, which could outlive the turn it was for.
    func appSpendHit(_ id: String) -> LimitHit? {
        guard let turn = runningTurns[id], turn.began, turn.counted, let spend = limits(meter: turn.meter).spend else {
            return nil
        }
        let used = spent(meter: turn.meter, period: spend.period)
        guard used >= spend.max else { return nil }
        let resetsAt = meter(turn.meter).resetsAt(spend.period, now: now(), calendar: calendar)
        let hit = LimitHit(
            limit: "appSpend", value: .double(spend.max), setBy: "user",
            extra: ["period": .string(spend.period.rawValue), "resetsAt": Self.timestamp(resetsAt)])
        traces?.session(id)?.writer.record(
            "lifecycle", ["event": "app-limit", "limit": "spend", "max": .double(spend.max), "used": .double(used)])
        if let grant = tokens.values.first(where: { $0.meter == turn.meter }) {
            onEvent(
                .appLimitReached(
                    AppLimitNotice(
                        grant: turn.meter, app: grant.app, limit: "spend",
                        summary: "\(AppLimits.dollars(spend.max)) \(AppLimits.per(spend.period))",
                        used: AppLimits.cents(used) + Self.this(spend.period), resetsAt: resetsAt,
                        resets: resetsAt.map { AppLimits.resets(at: $0, now: now(), calendar: calendar) })))
        }
        return hit
    }

    /// `agneta/usage`'s `app`: where the app stands against its spending limit after this turn, and `unpriced` when
    /// this turn on an API key called models its engine gave no price for, so the limit didn't count it.
    func appUsageReport(meter id: String, unpriced: Bool) -> JSONValue? {
        guard let spend = limits(meter: id).spend else { return nil }
        var report: JSONValue = [
            "spent": .double(spent(meter: id, period: spend.period)), "max": .double(spend.max),
            "period": .string(spend.period.rawValue),
            "resetsAt": Self.timestamp(meter(id).resetsAt(spend.period, now: now(), calendar: calendar))
        ]
        if unpriced { report = report.setting("unpriced", to: true) }
        return report
    }

    // MARK: Engines a spending limit can't count

    /// The engines a task on this account can't run on while the app's spending limit counts it: those that never
    /// report cost (Codex), which the limit couldn't hold.
    func uncounted(_ grant: Grant, account: String) -> Set<String> {
        guard grant.limits.spend != nil, countsSpend(account), let kind = accounts[account]?.kind else { return [] }
        return Set(
            ProviderEngines.supported(by: kind).filter { grant.engines.allows($0) && ProviderEngines.cost($0) == .none }
        )
    }

    /// The refusal for a task on an engine the app's spending limit can't count, or nil.
    func uncountedRefusal(_ engine: String, account: String, grant: Grant) -> RPCError? {
        uncounted(grant, account: account).contains(engine)
            ? accessRefusal(.uncounted(engine), account: account, grant: grant) : nil
    }

    /// The grant's engines, less those its spending limit can't count on this account.
    func allowance(_ grant: Grant, account: String) -> EngineAllowance {
        let excluded = uncounted(grant, account: account)
        guard !excluded.isEmpty else { return grant.engines }
        switch grant.engines {
        case .all:
            return .only(
                Set(AccountKind.allCases.flatMap(ProviderEngines.supported(by:))).union(catalog.entries.keys)
                    .subtracting(excluded))
        case .only(let some): return .only(some.subtracting(excluded))
        }
    }

    // MARK: What the app sees

    /// The access report's `limits`: what the user set and where the app stands, or nil when nothing is set.
    func limitsReport(_ grant: Grant) -> AccessReport.Limits? {
        let limits = grant.limits, at = now()
        guard !limits.isEmpty else { return nil }
        var report = AccessReport.Limits()
        if let spend = limits.spend {
            // The engines the app may use on API keys, by when their cost is known; one that never reports it can't run.
            let engines = Set(
                grant.accounts.compactMap { accounts[$0] }.filter { $0.kind.subscription == nil }
                    .flatMap { ProviderEngines.supported(by: $0.kind) }
            ).filter(grant.engines.allows)
            report.spend = .init(
                max: spend.max, currency: "USD", period: spend.period.rawValue, whenReached: spend.whenReached.rawValue,
                used: spent(meter: grant.meter, period: spend.period),
                resetsAt: meter(grant.meter).resetsAt(spend.period, now: at, calendar: calendar).map(
                    TraceWriter.timestamp),
                billing: "api-key",
                counted: Dictionary(
                    uniqueKeysWithValues: engines.filter { ProviderEngines.cost($0) != .none }.map {
                        ($0, ProviderEngines.cost($0).rawValue)
                    }),
                uncounted: engines.filter { ProviderEngines.cost($0) == .none && catalog.usable($0) }.sorted())
        }
        if let atOnce = limits.atOnce { report.atOnce = .init(max: atOnce, running: running(meter: grant.meter)) }
        if let starts = limits.newTasks {
            report.newTasks = .init(
                max: starts.max, period: starts.period.rawValue, whenReached: starts.whenReached.rawValue,
                used: meter(grant.meter).tasks(starts.period, now: at, calendar: calendar),
                resetsAt: meter(grant.meter).resetsAt(starts.period, now: at, calendar: calendar).map(
                    TraceWriter.timestamp))
        }
        return report
    }

    /// An app's usage and limits now, for Settings: today's totals, and each limit's count in its period.
    public func appStatus(grant id: String) -> AppLimitStatus {
        let limits = limits(meter: id), at = now()
        var status = AppLimitStatus(
            today: meter(id).total(.day, now: at, calendar: calendar), running: running(meter: id))
        status.today.cost = spent(meter: id, period: .day)
        if let spend = limits.spend {
            status.spent = spent(meter: id, period: spend.period)
            status.spendResets = meter(id).resetsAt(spend.period, now: at, calendar: calendar).map {
                AppLimits.resets(at: $0, now: at, calendar: calendar)
            }
        }
        if let starts = limits.newTasks { status.started = meter(id).tasks(starts.period, now: at, calendar: calendar) }
        return status
    }

    /// Forgets usage older than `date`, as the runtime's saved usage does.
    public func pruneUsage(before date: Date) {
        for id in meters.keys { meters[id]?.prune(before: date) }
    }

    /// The most turns that run at once, the highest an app's "at once" may be.
    public nonisolated var maxAtOnce: Int { concurrency.global }

    // MARK: Changing them

    /// Sets the limits the user chose for an app (Settings → Apps), for every connection holding the grant (and Allow
    /// Once grants counting against it), and saves them. A lower spending limit stops the app's running turns at their
    /// next check; a lower "at once" lets running turns finish and holds new ones; a higher one lets waiting turns run.
    public func setLimits(grant id: String, limits: AppLimits) async throws {
        if let problem = limits.problem(global: concurrency.global) {
            throw RPCError(code: RPCError.invalidParams, message: problem)
        }
        for (hash, grant) in tokens where grant.id == id || grant.countsAs == id {
            var changed = grant
            changed.limits = limits
            if changed.remembered, let commit { try await commit(hash, changed, nil) }
            // Removed while it was saved: stays removed. Anything else changed meanwhile stays as it is now.
            guard var current = tokens[hash], current.id == grant.id else { continue }
            current.limits = limits
            tokens[hash] = current
            if current.remembered { onEvent(.grantChanged(tokenHash: hash, grant: current)) }
            await apply(current)
        }
        admitWaiting()
    }
}

/// An app's usage and where it stands against its limits, as Settings shows it.
public struct AppLimitStatus: Sendable, Equatable {
    /// Today's totals (cost: on API keys, its running turns included).
    public var today: AppMeter.Usage
    /// Its turns running now.
    public var running: Int
    /// Spent in the spending limit's period, when one is set, and when that resets, in words.
    public var spent: Double?
    public var spendResets: String?
    /// New tasks in the new-task limit's period, when one is set.
    public var started: Int?

    public init(
        today: AppMeter.Usage = .init(), running: Int = 0, spent: Double? = nil, spendResets: String? = nil,
        started: Int? = nil
    ) {
        self.today = today
        self.running = running
        self.spent = spent
        self.spendResets = spendResets
        self.started = started
    }
}
