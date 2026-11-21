// Task traces (docs/DIAGNOSTICS.md): the registry the router, supervisor and
// broker report into; per task, the normalizer that turns ACP updates into
// provider-neutral events with task-scoped call ids and exact timing; the
// attributor that assigns raw JSON-RPC frames to tasks; and the reader for
// Goose's own per-model-call ledger.
import Foundation
import GRDB

public final class Traces: @unchecked Sendable {
    public let folder: URL
    public let mask = SecretMask()
    private let limits: TraceWriter.Limits
    private let lock = NSLock()
    private var sessions: [String: TraceSession] = [:]
    private var byEngineSession: [String: String] = [:] // lease key \0 engine session → task
    private var byLease: [String: Set<String>] = [:] // lease key → tasks on that engine
    /// Where each task's last page ended (its last sequence number, and the byte offset after it).
    private var pageEnds: [String: (seq: Int64, offset: UInt64)] = [:]
    private var problemHandler: (@Sendable (_ task: String, _ reason: String) -> Void)?

    /// Hears when a task's trace can't be written any more, so whoever shows Agneta's state can say so.
    public func onProblem(_ handler: @escaping @Sendable (_ task: String, _ reason: String) -> Void) {
        lock.withLock { problemHandler = handler }
    }

    public init(folder: URL, limits: TraceWriter.Limits = .init()) {
        self.folder = folder
        self.limits = limits
    }

    public func file(for task: String) -> URL { folder.appending(path: "\(task).jsonl") }

    /// Opens a task's trace. `prepare` runs before the task can be found by its engine session, so what it records
    /// (a new task's `meta`) comes first: once registered, the engine's messages are attributed to it from other
    /// threads at once.
    public func open(task: String, lease: String, engineSession: String, prepare: (TraceSession) -> Void = { _ in })
        -> TraceSession
    {
        let session = TraceSession(writer: TraceWriter(task: task, file: file(for: task), mask: mask, limits: limits))
        session.writer.onProblem { [weak self] reason in
            guard let handler = self?.lock.withLock({ self?.problemHandler }) else { return }
            handler(task, reason)
        }
        prepare(session)
        lock.withLock {
            sessions[task] = session
            byEngineSession[lease + "\u{0}" + engineSession] = task
            byLease[lease, default: []].insert(task)
        }
        return session
    }

    public func session(_ task: String) -> TraceSession? { lock.withLock { sessions[task] } }

    func task(lease: String, engineSession: String) -> String? {
        lock.withLock { byEngineSession[lease + "\u{0}" + engineSession] }
    }

    /// Tasks served by an engine (one for a dedicated engine, several for a shared one).
    public func tasks(onLease lease: String) -> [TraceSession] {
        lock.withLock { (byLease[lease] ?? []).compactMap { sessions[$0] } }
    }

    /// Ends a task's trace: flushes, closes, and forgets its bindings.
    public func close(task: String) {
        let session: TraceSession? = lock.withLock {
            byEngineSession = byEngineSession.filter { $0.value != task }
            for key in byLease.keys { byLease[key]?.remove(task) }
            return sessions.removeValue(forKey: task)
        }
        session?.close()
    }

    /// A page of a task's records after `after` (a sequence number), filtered by type: at most `limit` records
    /// and about `maxBytes` of them (always at least one). The file is read as a stream from where the previous
    /// page ended, never loaded whole; only records after `after` are decoded. `complete` is true once the page
    /// reaches the end of a trace whose last record is its `end` (a resumed task's earlier `end` doesn't count).
    public func read(
        task: String, after: Int64 = 0, types: Set<String>, limit: Int,
        maxBytes: Int = Traces.maxPageBytes
    ) -> (records: [JSONValue], next: Int64?, complete: Bool)? {
        let url = file(for: task)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var position: UInt64 = 0
        if let mark = lock.withLock({ pageEnds[task] }), mark.seq == after { position = mark.offset }
        try? handle.seek(toOffset: position)
        var records: [JSONValue] = []
        var size = 0
        var last = after
        var lastOffset = position
        var stoppedEarly = false
        var splitter = LineSplitter(limit: 64 << 20)
        reading: while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            // A partial line at the very end is a record still being written: it's left for the next page.
            for line in (try? splitter.push(chunk)) ?? [] {
                position += UInt64(line.count + 1)
                guard let seq = Self.seq(of: line) ?? (try? JSONCoding.decode(line))?["seq"]?.intValue, seq > after
                else { continue }
                guard let record = try? JSONCoding.decode(line) else { continue }
                if types.contains(record["type"]?.stringValue ?? "") {
                    if records.count >= limit || (size >= maxBytes && !records.isEmpty) {
                        stoppedEarly = true
                        break reading
                    }
                    records.append(record)
                    size += line.count
                }
                last = seq
                lastOffset = position
            }
        }
        lock.withLock { pageEnds[task] = (last, lastOffset) }
        // Complete only when the last record is the one this page read up to: the writer may have added records (a
        // task's last turn, its end) after the scan reached the end of the file.
        let final = TraceWriter.lastRecord(of: url)
        let complete = !stoppedEarly && final?["type"]?.stringValue == "end" && final?["seq"]?.intValue == last
        return (records, complete ? nil : last, complete)
    }

    /// About how much of a trace one page returns.
    public static let maxPageBytes = 8 << 20

    /// The sequence number at the start of a line Agneta wrote (`{"v":1,"seq":N,...`), without decoding the rest.
    static func seq(of line: Data) -> Int64? {
        let prefix = Array(#"{"v":1,"seq":"#.utf8)
        guard line.count > prefix.count, line.starts(with: prefix) else { return nil }
        var value: Int64 = 0
        var digits = 0
        for byte in line.dropFirst(prefix.count) {
            guard byte >= 48, byte <= 57 else { break }
            value = value * 10 + Int64(byte - 48)
            digits += 1
            if digits > 18 { return nil }
        }
        return digits > 0 ? value : nil
    }

    /// The `meta` record of a task (who owns it), or nil.
    public func meta(task: String) -> JSONValue? {
        guard let handle = try? FileHandle(forReadingFrom: file(for: task)) else { return nil }
        defer { try? handle.close() }
        var splitter = LineSplitter(limit: 64 << 20)
        while let chunk = try? handle.read(upToCount: 16 << 10), !chunk.isEmpty {
            guard let lines = try? splitter.push(chunk) else { return nil }
            for line in lines {
                if let record = try? JSONCoding.decode(line), record["type"]?.stringValue == "meta" { return record }
            }
        }
        return nil
    }

    /// Record types an app receives unless it asks otherwise: everything except the raw frames.
    public static let defaultTypes: Set<String> = [
        "meta", "config", "event", "engine.message", "engine.usage", "permission", "shell", "stderr", "lifecycle", "end"
    ]

    /// Deletes the traces of tasks no longer kept (retention, Clear History).
    public func delete(tasks: [String]) {
        for task in tasks {
            lock.withLock { _ = pageEnds.removeValue(forKey: task) }
            try? FileManager.default.removeItem(at: file(for: task))
            try? FileManager.default.removeItem(at: folder.appending(path: task, directoryHint: .isDirectory))
        }
    }

    // MARK: Reports from the supervisor and broker

    /// A shell command run by the broker for a dedicated engine.
    public func shell(lease: String, _ fields: [String: JSONValue]) {
        for session in tasks(onLease: lease) { session.writer.record("shell", fields) }
    }

    /// One line of a dedicated engine's stderr. A shared engine's lines stay in its engine.log only.
    public func stderr(lease: String, line: String) {
        guard !EngineKeys.isShared(lease) else { return }
        let sessions = tasks(onLease: lease)
        guard sessions.count == 1 else { return }
        sessions[0].writer.record("stderr", ["text": .string(line)], droppable: true)
    }

    public func engineExited(lease: String, status: Int32) {
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
        for session in tasks(onLease: lease) {
            session.writer.record(
                "lifecycle", ["event": "engine-exit", code < 0 ? "signal" : "code": .int(Int64(abs(code)))])
        }
    }

    // MARK: Raw frames

    /// A tap for one JSON-RPC connection: assigns each frame to its task by session id, or by
    /// the request id a response answers.
    public func attributor(received: String, sent: String, resolve: @escaping @Sendable (String) -> String?)
        -> FrameAttributor
    {
        FrameAttributor(traces: self, received: received, sent: sent, resolve: resolve)
    }

    /// For an engine connection: engine session ids map through the lease.
    public func engineAttributor(lease: String) -> FrameAttributor {
        attributor(received: "engine→agneta", sent: "agneta→engine") { [weak self] in
            self?.task(lease: lease, engineSession: $0)
        }
    }

    /// For an app connection: session ids are Agneta's own task ids.
    public func appAttributor() -> FrameAttributor {
        attributor(received: "app→agneta", sent: "agneta→app") { [weak self] in self?.session($0) == nil ? nil : $0 }
    }
}

public final class FrameAttributor: @unchecked Sendable {
    private weak var traces: Traces?
    private let received: String
    private let sent: String
    private let resolve: @Sendable (String) -> String?
    private let lock = NSLock()
    // Request ids (as JSON text) → task, by the direction the request travelled.
    private var requestsReceived: [String: String] = [:]
    private var requestsSent: [String: String] = [:]
    private var skipped: Set<String> = []

    init(traces: Traces, received: String, sent: String, resolve: @escaping @Sendable (String) -> String?) {
        self.traces = traces
        self.received = received
        self.sent = sent
        self.resolve = resolve
    }

    public func frame(_ direction: RPCPeer.FrameDirection, _ data: Data) {
        guard let traces, let message = try? JSONCoding.decode(data) else { return }
        let id = message["id"].map { value -> String in
            var text = ""; TraceJSON.encode(value, into: &text); return text
        }
        let isRequest = message["method"] != nil && id != nil
        // The trace's own delivery to the app isn't recorded in the trace (it would record itself).
        if message["method"]?.stringValue?.hasPrefix("agneta/trace") == true {
            if isRequest, let id { lock.withLock { _ = skipped.insert((direction == .received ? "r" : "s") + id) } }
            return
        }
        if !isRequest, let id, lock.withLock({ skipped.remove((direction == .received ? "s" : "r") + id) != nil }) {
            return
        }
        let session = message["params"]?["sessionId"]?.stringValue ?? message["result"]?["sessionId"]?.stringValue
        var task = session.flatMap(resolve)
        lock.withLock {
            if let id {
                if isRequest, let task {
                    if direction == .received { requestsReceived[id] = task } else { requestsSent[id] = task }
                } else if !isRequest {
                    // A response travels opposite to its request.
                    let owner =
                        direction == .received
                        ? requestsSent.removeValue(forKey: id) : requestsReceived.removeValue(forKey: id)
                    if task == nil { task = owner }
                }
            }
        }
        guard let task, let session = traces.session(task) else { return }
        let leg = direction == .received ? received : sent
        session.writer.record("acp", ["leg": JSONValue.string(leg), "msg": message], droppable: true)
    }
}

/// One task's trace and the state that normalizes its ACP stream.
public final class TraceSession: @unchecked Sendable {
    public let writer: TraceWriter
    private let lock = NSLock()
    private var calls: [String: (call: String, started: ContinuousClock.Instant, name: String?)] = [:]
    private var nextCall = 0
    private var turnStarted: ContinuousClock.Instant?
    private var firstToken: ContinuousClock.Instant?
    private var turnModelCalls: [JSONValue] = []
    private var modelCalls = 0
    private var turns = 0
    private var ledger: (any UsageLedger)?
    private var engine: (any EngineAdapter)?
    private var billing = "unknown"
    private var poller: Task<Void, Never>?
    /// How often the engine's records are read while a turn runs.
    var pollInterval: Duration = .seconds(2)
    /// A partial row from the stream held back until the engine's records give its final row (by id): its agent
    /// thread, when it was taken, and, once that thread has moved on to its next call, when to give up.
    private struct Held {
        var id: String
        var row: [String: JSONValue]
        var thread: String
        var taken: ContinuousClock.Instant
        var due: ContinuousClock.Instant?
    }
    private var held: [Held] = [] // oldest first
    /// When the engine's records last gave rows, and whether they've stopped giving the held ones: a row given up
    /// on with nothing read since it was taken (the transcript moved, or isn't written). Until they give rows again,
    /// stream rows are recorded at once, so a missing transcript costs one late call, not every call and turn.
    private var lastDelivery: ContinuousClock.Instant?
    private var recordsAbsent = false
    /// How long a held row waits for its final one after its thread's next call began (the call had ended by then;
    /// its final row is written about 100 ms after it ends, and read at the next poll).
    var holdAfterNext: Duration = .seconds(5)
    /// How long a turn's end waits for the final rows still held (the last call's lands just after the result).
    var finalGrace: Duration = .seconds(1)
    private var taskCost = 0.0

    init(writer: TraceWriter) {
        self.writer = writer
        // A resumed task goes on from where it was: its turns, its model calls, and its cost, which its limits count.
        turns = Int(writer.turn)
        (taskCost, modelCalls) = writer.earlier
    }

    /// What the account's costs mean: `subscription` (plan-equivalent) or `api-key` (estimated billing).
    public func set(billing: String) { lock.withLock { self.billing = billing } }

    /// The engine's own per-call usage records for this session. `resumed`: what's already recorded belongs to
    /// earlier turns (and the trace already has it), so the reader starts after it: a resumed task's first turn
    /// counts only its own calls.
    public func follow(_ ledger: (any UsageLedger)?, resumed: Bool = false) {
        if resumed, let ledger, !ledger.startAfterExisting() {
            let earlier = ledger.read()
            lock.withLock { for row in earlier.usage { if let id = row["id"]?.stringValue { seenCalls.insert(id) } } }
        }
        lock.withLock { self.ledger = ledger }
    }

    /// The engine whose updates this trace reads (how it names tools).
    public func identify(with engine: any EngineAdapter) { lock.withLock { self.engine = engine } }

    // MARK: Normalizing ACP updates

    /// One `session/update` from the engine.
    public func update(_ update: JSONValue) {
        guard let kind = update["sessionUpdate"]?.stringValue else { return }
        let now = ContinuousClock.now
        switch kind {
        case "agent_message_chunk", "agent_thought_chunk":
            noteFirstToken(now)
            var fields: [String: JSONValue] = [
                "kind": kind == "agent_message_chunk" ? "text-delta" : "thinking-delta",
                "delta": update["content"]?["text"] ?? .null
            ]
            if let message = update["messageId"] { fields["message"] = message }
            writer.record("event", fields, droppable: true)
        case "tool_call", "tool_call_update":
            noteFirstToken(now)
            toolCall(update, at: now)
        case "usage_update":
            var fields: [String: JSONValue] = [
                "kind": "usage", "cumulative": true, "size": update["size"] ?? .null, "used": update["used"] ?? .null
            ]
            if let cost = update["cost"] { fields["cost"] = cost }
            writer.record("event", fields)
        case "plan":
            writer.record("event", ["kind": "plan", "entries": update["entries"] ?? .null])
        default:
            break // session_info_update, available_commands_update, …: kept in the raw `acp` lines
        }
    }

    private func noteFirstToken(_ now: ContinuousClock.Instant) {
        lock.withLock { if turnStarted != nil && firstToken == nil { firstToken = now } }
    }

    private func toolCall(_ update: JSONValue, at now: ContinuousClock.Instant) {
        guard let engineID = update["toolCallId"]?.stringValue else { return }
        let status = update["status"]?.stringValue
        let (entry, isNew): ((call: String, started: ContinuousClock.Instant, name: String?), Bool) = lock.withLock {
            if let known = calls[engineID] { return (known, false) }
            nextCall += 1
            let entry = (call: "c\(nextCall)", started: now, name: update["title"]?.stringValue)
            calls[engineID] = entry
            return (entry, true)
        }
        if isNew {
            // Goose names the tool and the model response in _meta; the title also carries arguments.
            // The engine knows the tool's own name and its server; the title also carries arguments.
            let identity = lock.withLock { engine }?.toolIdentity(in: update) ?? (tool: nil, server: nil, message: nil)
            writer.record(
                "event",
                [
                    "kind": "tool-call", "call": .string(entry.call), "engineCall": .string(engineID),
                    "tool": identity.tool.map(JSONValue.string) ?? .null,
                    "extension": identity.server.map(JSONValue.string) ?? .null,
                    "message": identity.message.map(JSONValue.string) ?? .null, "name": update["title"] ?? .null,
                    "toolKind": update["kind"] ?? .null,
                    "input": update["rawInput"] ?? .null, "tStart": .string(TraceWriter.timestamp(Date()))
                ])
        } else if update["rawInput"] != nil || update["title"] != nil,
            status == nil || status == "pending" || status == "in_progress"
        {
            // ACP updates are upserts: the input or title can arrive after the first sighting.
            var fields: [String: JSONValue] = ["kind": "tool-input", "call": .string(entry.call)]
            if let input = update["rawInput"] { fields["input"] = input }
            if let title = update["title"] { fields["name"] = title }
            writer.record("event", fields)
        }
        guard status == "completed" || status == "failed" else { return }
        let ms =
            Double((now - entry.started).components.attoseconds) / 1e15 + Double(
                (now - entry.started).components.seconds) * 1000
        let content = update["content"] ?? .null
        var text = ""
        TraceJSON.encode(content, into: &text)
        let bytes =
            text.utf8.count
            + (update["rawOutput"].map { value -> Int in
                var raw = ""; TraceJSON.encode(value, into: &raw); return raw.utf8.count
            } ?? 0)
        writer.record(
            "event",
            [
                "kind": "tool-result", "call": .string(entry.call), "status": .string(status!),
                "isError": .bool(status == "failed"),
                "content": content, "rawOutput": update["rawOutput"] ?? .null,
                "tEnd": .string(TraceWriter.timestamp(Date())),
                "ms": .double((ms * 10).rounded() / 10), "bytes": .int(Int64(bytes)),
                "estTokens": .int(Int64(bytes / 4))
            ])
        lock.withLock { calls[engineID] = nil }
    }

    /// What limits are checked against while a turn runs: model calls in this turn so far and the
    /// task's known cost so far (both from the engine's ledger, read every 2 s).
    public var progress: (turnModelCalls: Int, taskCost: Double) {
        lock.withLock { (turnModelCalls.count + held.count, taskCost) }
    }

    // MARK: Turns

    public func turnStarted(prompt: JSONValue?) {
        let n: Int = lock.withLock {
            turns += 1
            turnStarted = ContinuousClock.now
            firstToken = nil
            turnModelCalls = []
            turnTotals = nil
            return turns
        }
        writer.turn = Int64(n)
        writer.record("event", ["kind": "prompt", "n": .int(Int64(n)), "prompt": prompt ?? .null])
        startPolling()
    }

    /// Reads the engine ledger one last time, then writes the turn summary. `cutOff`: Agneta stopped the turn (a
    /// limit), whatever the stop reason says, so its last call never gets a final row.
    @discardableResult
    public func turnEnded(stopReason: String, usage: JSONValue?, error: String? = nil, cutOff: Bool = false) async
        -> [String: JSONValue]
    {
        // The last read waits for a poll still in flight: rows it has read but not yet counted belong to this turn,
        // and the ledger hands each row out only once.
        let inFlight = lock.withLock { () -> Task<Void, Never>? in
            defer { poller = nil }
            return poller
        }
        inFlight?.cancel()
        await inFlight?.value
        await pollLedger()
        // Each thread's last call's final row lands just after the result: wait for those a little, reading off the
        // router (its earlier calls ended long ago). A call cut off (cancelled, a limit, the engine failed) never gets one.
        let cut = cutOff || ["error", "cancelled"].contains(stopReason)
        func waiting() -> Bool { lock.withLock { !recordsAbsent && held.contains { $0.due == nil } } }
        if !cut, waiting() {
            let deadline = ContinuousClock.now + finalGrace
            while ContinuousClock.now < deadline, waiting() {
                try? await Task.sleep(for: .milliseconds(25))
                await pollLedger()
            }
        }
        // What's still held goes out as it is, and the turn stops holding, in one step: a row arriving now is
        // recorded at once.
        let (started, left): (ContinuousClock.Instant?, [Held]) = lock.withLock {
            defer { turnStarted = nil; held = [] }
            if !cut { giveUp(held) }
            return (turnStarted, held)
        }
        for row in left { record(modelCall: row.row) }
        let (first, calls, n, totals): (ContinuousClock.Instant?, [JSONValue], Int, [String: [String: Double]]?) =
            lock.withLock {
                defer { turnTotals = nil }
                return (firstToken, turnModelCalls, turns, turnTotals)
            }
        func ms(_ from: ContinuousClock.Instant?, _ to: ContinuousClock.Instant?) -> JSONValue {
            guard let from, let to else { return .null }
            let duration = to - from
            return .double(
                ((Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15) * 10)
                    .rounded() / 10)
        }
        var fields: [String: JSONValue] = [
            "kind": "turn", "n": .int(Int64(n)), "stopReason": .string(stopReason),
            "ms": ms(started, ContinuousClock.now), "msToFirstToken": ms(started, first),
            "modelCalls": .int(Int64(calls.count)), "usage": usage ?? .null
        ]
        let sums = ["input", "output", "cacheRead", "cacheWrite"].map { key in
            (key, calls.reduce(Int64(0)) { $0 + ($1[key]?.intValue ?? 0) })
        }
        fields["ledger"] = .object(Dictionary(uniqueKeysWithValues: sums.map { ($0.0, JSONValue.int($0.1)) }))
        let costs = calls.compactMap { call -> Double? in
            if case .double(let v)? = call["cost"] { return v }; return call["cost"]?.intValue.map(Double.init)
        }
        fields["cost"] = costs.isEmpty ? .null : .double(costs.reduce(0, +))
        let taskCost = lock.withLock { self.taskCost }
        fields["taskCost"] = taskCost > 0 ? .double(taskCost) : .null
        fields["models"] = .array(
            Array(Set(calls.compactMap { $0["model"]?.stringValue })).sorted().map(JSONValue.string))
        fields["basis"] = "engine-ledger"
        if let totals {
            // The engine's own totals for the turn win over the per-call sums: they're complete (Claude Code's
            // per-call output is the stream's opening count) and include side calls. The call sums stay alongside.
            fields["callLedger"] = fields["ledger"]
            fields["ledger"] = .object(
                Dictionary(
                    uniqueKeysWithValues: ["input", "output", "cacheRead", "cacheWrite"].map { key in
                        (key, JSONValue.int(Int64(totals.values.reduce(0) { $0 + ($1[key] ?? 0) }.rounded())))
                    }))
            let cost = totals.values.reduce(0) { $0 + ($1["cost"] ?? 0) }
            if cost > 0 { fields["cost"] = .double(cost) }
            fields["models"] = .array(
                Array(Set(calls.compactMap { $0["model"]?.stringValue }).union(totals.keys)).sorted().map(
                    JSONValue.string))
            fields["basis"] = "engine-turn-totals"
        }
        fields["costKind"] = .string(lock.withLock { billing } == "subscription" ? "plan-equivalent" : "estimated")
        if let error { fields["error"] = .string(error) }
        writer.record("event", fields)
        writer.flush()
        return fields
    }

    private func startPolling() {
        let interval = pollInterval
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await self.pollLedger()
            }
        }
        lock.withLock { () -> Task<Void, Never>? in
            defer { poller = task }
            return poller
        }?.cancel()
    }

    /// New rows from Goose's database: messages as the model saw them, and one usage row per model call.
    func pollLedger() async {
        guard let ledger = lock.withLock({ self.ledger }) else { return }
        let rows = ledger.read()
        if let problem = rows.problem {
            writer.record("lifecycle", ["event": "engine-db-unavailable", "reason": .string(problem)])
        }
        if let notice = ledger.takeNotice() {
            writer.record("lifecycle", ["event": "engine-records-limited", "reason": .string(notice)])
        }
        for message in rows.messages { writer.record("engine.message", message) }
        if !rows.usage.isEmpty {
            lock.withLock {
                lastDelivery = ContinuousClock.now
                recordsAbsent = false
            }
        }
        for usage in rows.usage { ingest(modelCall: usage) }
        // Held rows whose final one didn't come in time go out as they are, partial.
        let now = ContinuousClock.now
        let due = lock.withLock { () -> [Held] in
            let out = held.filter { $0.due.map { $0 <= now } ?? false }
            held.removeAll { $0.due.map { $0 <= now } ?? false }
            giveUp(out)
            return out
        }
        for row in due { record(modelCall: row.row) }
    }

    /// Rows given up on: when the records gave nothing since one was taken, they've stopped giving them. Under the lock.
    private func giveUp(_ rows: [Held]) {
        if rows.contains(where: { row in lastDelivery.map { $0 < row.taken } ?? true }) { recordsAbsent = true }
    }

    /// Holds a partial row from the stream when the engine's records will give the call's final one: the same
    /// call's later content blocks are dropped, and its thread's earlier calls, which have ended, get a deadline.
    private func hold(_ usage: [String: JSONValue]) -> Bool {
        guard usage["output_partial"] == .bool(true), let id = usage["id"]?.stringValue else { return false }
        return lock.withLock {
            guard ledger?.completesStreamRows == true, !recordsAbsent, turnStarted != nil, !seenCalls.contains(id)
            else {
                return false
            }
            if held.contains(where: { $0.id == id }) { return true }
            let thread = usage["parent"]?.stringValue ?? ""
            let now = ContinuousClock.now
            for index in held.indices where held[index].thread == thread && held[index].due == nil {
                held[index].due = now + holdAfterNext
            }
            held.append(Held(id: id, row: usage, thread: thread, taken: now, due: nil))
            return true
        }
    }

    private var seenCalls: Set<String> = []
    private var planListener: (@Sendable (JSONValue) -> Void)?

    /// Hears the plan's usage when the engine's records carry it (Codex: used percent per limit window).
    public func onPlanUsage(_ listener: @escaping @Sendable (JSONValue) -> Void) {
        lock.withLock { planListener = listener }
    }

    /// The engine's running totals per model at its last report, and this turn's share of them.
    private var sessionTotals: [String: [String: Double]] = [:]
    private var turnTotals: [String: [String: Double]]?

    /// One model call's usage (from the engine's records or its stream). Rows with an `id` already seen are skipped.
    /// A row with `session_totals` is instead the engine's running totals per model (Claude Code's results). A partial
    /// row whose final one the records will give is held back until it's read, or until it's late (`hold`).
    public func ingest(modelCall usage: [String: JSONValue]) {
        if let plan = usage["plan"], plan != .null, let listener = lock.withLock({ planListener }) { listener(plan) }
        if let totals = usage["session_totals"]?.objectValue {
            writer.record("engine.usage", usage)
            ingest(sessionTotals: totals)
            return
        }
        if hold(usage) { return }
        record(modelCall: usage)
    }

    private func record(modelCall usage: [String: JSONValue]) {
        if let id = usage["id"]?.stringValue,
            !lock.withLock({
                held.removeAll { $0.id == id } // its final row came
                return seenCalls.insert(id).inserted
            })
        {
            return
        }
        writer.record("engine.usage", usage)
        let cost: Double? =
            switch usage["cost"] {
            case .double(let v)?: v;
            case .int(let v)?: Double(v);
            default: nil
            }
        let (n, billing, total) = lock.withLock { () -> (Int, String, Double) in
            modelCalls += 1
            taskCost += cost ?? 0
            return (modelCalls, self.billing, taskCost)
        }
        let call: JSONValue = [
            "kind": "model-call", "n": .int(Int64(n)), "model": usage["model"] ?? .null,
            "input": usage["input_tokens"] ?? .null, "output": usage["output_tokens"] ?? .null,
            "cacheRead": usage["cache_read_tokens"] ?? .null, "cacheWrite": usage["cache_write_tokens"] ?? .null,
            "cost": usage["cost"] ?? .null, "costSource": usage["cost_source"] ?? .null,
            "costKind": .string(billing == "subscription" ? "plan-equivalent" : "estimated"),
            "compaction": .bool((usage["is_compaction"]?.intValue ?? 0) != 0), "at": usage["created"] ?? .null,
            "basis": usage["basis"] ?? "engine-ledger",
            "outputPartial": usage["output_partial"] ?? .null, "taskCost": .double(total)
        ]
        lock.withLock { turnModelCalls.append(call) }
        writer.record("event", call.objectValue ?? [:])
    }

    /// Adds what the totals grew by since the last report to this turn. A model whose totals shrank started
    /// over (a new engine process for a resumed task), so its totals are all new.
    private func ingest(sessionTotals totals: [String: JSONValue]) {
        let keys = ["input", "output", "cacheRead", "cacheWrite", "cost"]
        lock.withLock {
            var turn = turnTotals ?? [:]
            var addedCost = 0.0
            for (model, value) in totals {
                let now = Dictionary(
                    uniqueKeysWithValues: keys.map { key -> (String, Double) in
                        switch value[key] {
                        case .double(let v)?: (key, v);
                        case .int(let v)?: (key, Double(v));
                        default: (key, 0)
                        }
                    })
                let before = sessionTotals[model] ?? [:]
                let restarted = keys.contains { (now[$0] ?? 0) < (before[$0] ?? 0) }
                for key in keys {
                    let delta = (now[key] ?? 0) - (restarted ? 0 : before[key] ?? 0)
                    turn[model, default: [:]][key, default: 0] += delta
                    if key == "cost" { addedCost += delta }
                }
                sessionTotals[model] = now
            }
            turnTotals = turn
            taskCost += addedCost
        }
    }

    /// Ends the trace. Calls still held (a session ended mid-turn) go out first, as they are.
    func close() {
        // A poll still in flight records rows at once from here on: it no longer holds them.
        let left = lock.withLock {
            defer { held = []; turnStarted = nil }
            poller?.cancel()
            return held
        }
        for row in left { record(modelCall: row.row) }
        writer.close()
    }
}

/// Reads Goose's session database read-only (goose-acp 1.59.2 schema), rows newer than those
/// already read. Any other schema is reported once and then left alone.
final class GooseLedgerReader: UsageLedger, @unchecked Sendable {
    let database: URL
    let session: String
    private let lock = NSLock()
    private var queue: DatabaseQueue?
    private var lastMessage: Int64 = 0
    private var lastUsage: Int64 = 0
    private var disabled = false

    init(database: URL, session: String) {
        self.database = database
        self.session = session
    }

    func read() -> (messages: [[String: JSONValue]], usage: [[String: JSONValue]], problem: String?) {
        lock.withLock {
            guard !disabled else { return ([], [], nil) }
            guard FileManager.default.fileExists(atPath: database.path(percentEncoded: false)) else {
                return ([], [], nil)
            }
            do {
                if queue == nil {
                    var configuration = Configuration()
                    configuration.readonly = true
                    configuration.busyMode = .timeout(0.5)
                    let opened = try DatabaseQueue(
                        path: database.path(percentEncoded: false), configuration: configuration)
                    try opened.read { db in
                        let messageColumns = Set(try db.columns(in: "messages").map(\.name))
                        let usageColumns = Set(try db.columns(in: "usage_ledger").map(\.name))
                        guard
                            messageColumns.isSuperset(of: [
                                "id", "session_id", "role", "content_json", "created_timestamp"
                            ]),
                            usageColumns.isSuperset(of: [
                                "id", "session_id", "model", "input_tokens", "output_tokens", "cost"
                            ])
                        else {
                            throw SchemaMismatch()
                        }
                    }
                    queue = opened
                }
                return try queue!.read { db in
                    let messages = try Row.fetchAll(
                        db, sql: "SELECT * FROM messages WHERE session_id = ? AND id > ? ORDER BY id",
                        arguments: [session, lastMessage]
                    ).map { row -> [String: JSONValue] in
                        lastMessage = row["id"]
                        let content = (row["content_json"] as String?).flatMap { try? JSONCoding.decode(Data($0.utf8)) }
                        let meta = (row["metadata_json"] as String?).flatMap { try? JSONCoding.decode(Data($0.utf8)) }
                        return [
                            "row": .int(row["id"]), "role": .string(row["role"]), "content": content ?? .null,
                            "meta": meta ?? .null,
                            "messageId": (row["message_id"] as String?).map(JSONValue.string) ?? .null,
                            "created": .int(row["created_timestamp"]),
                            "tokens": (row["tokens"] as Int64?).map(JSONValue.int) ?? .null
                        ]
                    }
                    let usage = try Row.fetchAll(
                        db, sql: "SELECT * FROM usage_ledger WHERE session_id = ? AND id > ? ORDER BY id",
                        arguments: [session, lastUsage]
                    ).map { row -> [String: JSONValue] in
                        lastUsage = row["id"]
                        var fields: [String: JSONValue] = [
                            "row": .int(row["id"]), "created": .int(row["created_timestamp"])
                        ]
                        for column in ["model", "cost_source"] {
                            fields[column] = (row[column] as String?).map(JSONValue.string) ?? .null
                        }
                        for column in [
                            "input_tokens", "output_tokens", "total_tokens", "cache_read_tokens", "cache_write_tokens",
                            "is_compaction"
                        ] {
                            fields[column] = (row[column] as Int64?).map(JSONValue.int) ?? .null
                        }
                        fields["cost"] = (row["cost"] as Double?).map(JSONValue.double) ?? .null
                        return fields
                    }
                    return (messages, usage, nil)
                }
            } catch is SchemaMismatch {
                disabled = true
                return ([], [], "Goose's session database has a schema this Agneta doesn't know")
            } catch {
                queue = nil // retried at the next poll (e.g. the file was still being created)
                return ([], [], nil)
            }
        }
    }

    private struct SchemaMismatch: Error {}
}

/// Delivers a task's records to its app as they're written: batched every 100 ms or 64
/// records, in sequence order, until the task ends. An app that can't keep up doesn't grow
/// Agneta's memory: past `limit` waiting records, live delivery sends what it holds, says where
/// it stopped (`overflow`), and ends; the app reads on from there with `agneta/trace/read`.
public final class TraceForwarder: @unchecked Sendable {
    private let include: Set<String>
    private let limit: Int
    private let send: @Sendable ([JSONValue]) async -> Void
    private let overflow: @Sendable (_ after: Int64) async -> Void
    private let lock = NSLock()
    private var buffer: [JSONValue] = []
    private var finished = false
    private var overflowed = false
    private var loop: Task<Void, Never>?

    public init(
        include: Set<String>, limit: Int = 10_000, send: @escaping @Sendable ([JSONValue]) async -> Void,
        overflow: @escaping @Sendable (_ after: Int64) async -> Void = { _ in }
    ) {
        self.include = include
        self.limit = limit
        self.send = send
        self.overflow = overflow
        loop = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                let (batch, done, overflowed) = self.take()
                for start in stride(from: 0, to: batch.count, by: 64) {
                    await self.send(Array(batch[start..<min(start + 64, batch.count)]))
                }
                if overflowed {
                    await self.overflow(batch.last?["seq"]?.intValue ?? 0)
                    return
                }
                if done { return }
            }
        }
    }

    public func accept(_ record: JSONValue) {
        guard include.contains(record["type"]?.stringValue ?? "") else { return }
        lock.withLock {
            guard !overflowed else { return }
            if buffer.count >= limit { overflowed = true; return }
            buffer.append(record)
        }
    }

    private func take() -> ([JSONValue], Bool, Bool) {
        lock.withLock {
            defer { buffer.removeAll() }
            return (buffer, finished, overflowed)
        }
    }

    /// Sends what's left and stops.
    public func finish() async {
        lock.withLock { finished = true }
        await loop?.value
    }
}
