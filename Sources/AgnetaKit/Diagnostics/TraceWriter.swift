// Appends one task's trace (docs/DIAGNOSTICS.md, `agneta/trace`). Records
// get their sequence number when they're recorded, so the file order is the
// order things happened; writing happens on a serial queue so a turn never
// waits on the disk. Under pressure or past the size cap, raw frames and text
// deltas are dropped first and counted. Past the hard cap nothing more is
// written but the task's end. A write that fails stops the trace and is
// reported: a trace that silently lost records would mislead whoever reads it.
import Darwin
import Foundation

public final class TraceWriter: @unchecked Sendable {
    public struct Limits: Sendable {
        /// Bytes per task before droppable records are skipped.
        public var maxBytes: Int
        /// Records waiting for the disk before droppable records are skipped.
        public var maxPending: Int
        /// Bytes per task before every record is skipped (counted), except the task's end.
        public var maxTotalBytes: Int
        /// Bytes per record: a larger one (a huge tool output) is written as a stub that keeps what identifies it.
        public var maxRecordBytes: Int
        public init(maxBytes: Int = 200 << 20, maxPending: Int = 20_000, maxTotalBytes: Int = 1 << 30, maxRecordBytes: Int = 16 << 20) {
            self.maxBytes = maxBytes
            self.maxPending = maxPending
            self.maxTotalBytes = maxTotalBytes
            self.maxRecordBytes = maxRecordBytes
        }
    }

    public let task: String
    public let file: URL
    let mask: SecretMask
    private let limits: Limits
    private let queue: DispatchQueue
    private let handle: FileHandle?
    private let started = ContinuousClock.now
    private let lock = NSLock()
    private var seq: Int64 = 0
    private var currentTurn: Int64 = 0
    private var pending = 0
    private var bytes = 0
    private var dropped = 0
    private var truncatedNoted = false
    private var fullNoted = false
    /// The task's end is written: nothing more goes after it.
    private var ended = false
    /// Why the trace stopped being written (a write failed), or nil.
    private var failure: String?
    private var problemHandler: (@Sendable (String) -> Void)?
    private var lastSync = ContinuousClock.now
    private var closed = false
    private var listener: (@Sendable (JSONValue) -> Void)?
    /// What a resumed task had already used: its cost so far, and how many model calls it had made.
    public private(set) var earlier: (taskCost: Double, modelCalls: Int) = (0, 0)

    /// Sees every record as it's written, masked, in sequence order (live delivery to the app).
    public func observe(_ listener: @escaping @Sendable (JSONValue) -> Void) { lock.withLock { self.listener = listener } }

    /// Hears once when the trace can't be written any more (the disk is full, the file went away).
    public func onProblem(_ handler: @escaping @Sendable (String) -> Void) { lock.withLock { problemHandler = handler } }

    /// Why this trace stopped being written, or nil while it's whole.
    public var problem: String? { lock.withLock { failure } }

    public init(task: String, file: URL, mask: SecretMask, limits: Limits = Limits()) {
        self.task = task
        self.file = file
        self.mask = mask
        self.limits = limits
        queue = DispatchQueue(label: "agneta.trace.\(task)")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: file)
        if let handle { bytes = Int((try? handle.seekToEnd()) ?? 0) } else { failure = "the trace file couldn't be opened" }
        // A resumed task continues its trace: numbering and turns go on from the last line.
        if bytes > 0, let last = Self.lastRecord(of: file) {
            seq = last["seq"]?.intValue ?? 0
            currentTurn = last["turn"]?.intValue ?? 0
            earlier = Self.usageSoFar(of: file)
        }
    }

    /// A trace's cost so far and its model-call count, from its latest records: the last `turn` or `model-call`
    /// event carries the task's cost, and the last `model-call` its number. Read backwards from the end, decoding
    /// only lines that can hold them.
    static func usageSoFar(of file: URL) -> (taskCost: Double, modelCalls: Int) {
        guard let handle = try? FileHandle(forReadingFrom: file), let size = try? handle.seekToEnd() else { return (0, 0) }
        defer { try? handle.close() }
        let costKey = Data(#""taskCost":"#.utf8), callKind = Data(#""kind":"model-call""#.utf8)
        var cost: Double?, calls: Int?
        var end = size
        var carry = Data() // the start of a line cut by the previous chunk's boundary
        while end > 0, cost == nil || calls == nil {
            let start = end > 1 << 20 ? end - (1 << 20) : 0
            try? handle.seek(toOffset: start)
            var data = handle.readData(ofLength: Int(end - start))
            data.append(carry)
            var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            // The first piece may continue in the chunk before this one; it's read with that chunk.
            carry = start > 0 ? Data(lines.removeFirst()) : Data()
            for line in lines.reversed() where cost == nil || calls == nil {
                let isCall = line.range(of: callKind) != nil
                guard isCall || (cost == nil && line.range(of: costKey) != nil),
                      let record = try? JSONCoding.decode(Data(line)), record["type"]?.stringValue == "event" else { continue }
                let kind = record["kind"]?.stringValue
                if cost == nil, kind == "turn" || kind == "model-call" {
                    cost = switch record["taskCost"] { case .double(let v)?: v; case .int(let v)?: Double(v); default: kind == "turn" ? 0 : nil }
                }
                if calls == nil, kind == "model-call" { calls = record["n"]?.intValue.map(Int.init) }
            }
            end = start
        }
        return (cost ?? 0, calls ?? 0)
    }

    /// The last complete record of a trace file (read from its end).
    static func lastRecord(of file: URL) -> JSONValue? {
        guard let handle = try? FileHandle(forReadingFrom: file), let size = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }
        var window: UInt64 = 64 << 10
        while true {
            let start = size > window ? size - window : 0
            try? handle.seek(toOffset: start)
            let data = handle.readData(ofLength: Int(size - start))
            let lines = data.split(separator: UInt8(ascii: "\n"))
            if let line = lines.last(where: { (try? JSONCoding.decode(Data($0))) != nil }) { return try? JSONCoding.decode(Data(line)) }
            if start == 0 { return nil }
            window *= 4
        }
    }

    public var turn: Int64 {
        get { lock.withLock { currentTurn } }
        set { lock.withLock { currentTurn = newValue } }
    }

    /// Appends a record. `droppable` records (raw frames, deltas) may be skipped under pressure.
    /// Records are queued in call order on the writer's serial queue, and numbered there as they're
    /// written, so the file order is the sequence order and a record the caps skip leaves no gap;
    /// masking and encoding happen on that queue, off the turn.
    public func record(_ type: String, _ fields: [String: JSONValue], droppable: Bool = false) {
        let now = Date()
        let elapsed = ContinuousClock.now - started
        lock.withLock {
            guard !closed, failure == nil else { return }
            if droppable && pending >= limits.maxPending {
                dropped += 1
                return
            }
            pending += 1
            let turn = currentTurn
            queue.async { [self] in write(turn: turn, at: now, elapsed: elapsed, type: type, fields: fields, droppable: droppable) }
        }
    }

    private func write(turn: Int64, at now: Date, elapsed: Duration, type: String, fields: [String: JSONValue], droppable: Bool) {
        defer { lock.withLock { pending = max(0, pending - 1) } }
        // What was dropped is counted before the task's end, so the end stays the last record.
        if type == "end" { noteDropped(turn: turn, at: now, elapsed: elapsed) }
        // The caps apply to what's on disk now. Past the hard cap only the task's end still goes in.
        let pastCap = lock.withLock { droppable ? bytes >= limits.maxBytes : bytes >= limits.maxTotalBytes && type != "end" }
        if pastCap {
            lock.withLock { if failure == nil { dropped += 1 } }
            return
        }
        append(turn: turn, at: now, elapsed: elapsed, type: type, fields: fields)
        // Crossing a cap is noted right after the record that crossed it.
        let (truncated, full): (Bool, Bool) = lock.withLock {
            let truncated = bytes >= limits.maxBytes && !truncatedNoted
            if truncated { truncatedNoted = true }
            let full = bytes >= limits.maxTotalBytes && !fullNoted
            if full { fullNoted = true }
            if type == "end" { ended = true }
            return (truncated, full)
        }
        if truncated { append(turn: turn, at: now, elapsed: elapsed, type: "lifecycle", fields: ["event": "trace-truncated", "maxBytes": .int(Int64(limits.maxBytes))]) }
        if full { append(turn: turn, at: now, elapsed: elapsed, type: "lifecycle", fields: ["event": "trace-full", "maxTotalBytes": .int(Int64(limits.maxTotalBytes))]) }
    }

    /// Numbers, masks and writes one record now, on the writer's queue; the caller has checked the caps.
    private func append(turn: Int64, at now: Date, elapsed: Duration, type: String, fields: [String: JSONValue]) {
        let numbered: Int64? = lock.withLock {
            guard failure == nil else { return nil }
            seq += 1
            return seq
        }
        guard let seq = numbered else { return }
        let mono = elapsed.components.seconds * 1_000_000_000 + elapsed.components.attoseconds / 1_000_000_000
        let masked = mask.mask(.object(fields)).objectValue ?? [:]
        let header: [(String, JSONValue)] = [("v", 1), ("seq", .int(seq)), ("t", .string(Self.timestamp(now))), ("mono", .int(mono)),
                                             ("task", .string(task)), ("turn", .int(turn)), ("type", .string(type))]
        var line = TraceJSON.line(header: header, fields: masked)
        if line.count > limits.maxRecordBytes {
            // What identifies the record stays; its content is replaced by its size.
            var stub: [String: JSONValue] = ["oversize": .int(Int64(line.count))]
            for key in ["kind", "call", "tool", "extension", "event", "status", "isError", "n", "stopReason"] { stub[key] = masked[key] }
            line = TraceJSON.line(header: header, fields: stub.filter { $0.value != .null })
        }
        do {
            guard let handle else { throw CocoaError(.fileNoSuchFile) }
            try handle.write(contentsOf: line)
        } catch {
            fail("writing failed: \(error.localizedDescription)")
            return
        }
        if let listener = lock.withLock({ self.listener }) {
            listener(.object(masked.merging(header, uniquingKeysWith: { _, header in header })))
        }
        let sync: Bool = lock.withLock {
            bytes += line.count
            let sync = ContinuousClock.now - lastSync > .seconds(1)
            if sync { lastSync = ContinuousClock.now }
            return sync
        }
        if sync, let handle { fsync(handle.fileDescriptor) }
    }

    /// Records how many records were dropped since the last note, if any; on the writer's queue.
    private func noteDropped(turn: Int64, at now: Date, elapsed: Duration) {
        let count: Int = lock.withLock {
            guard !ended else { return 0 }
            defer { dropped = 0 }
            return dropped
        }
        if count > 0 { append(turn: turn, at: now, elapsed: elapsed, type: "lifecycle", fields: ["event": "dropped", "records": .int(Int64(count))]) }
    }

    /// The trace can't be written: stop, keep why, and say so once.
    private func fail(_ reason: String) {
        let handler: (@Sendable (String) -> Void)? = lock.withLock {
            guard failure == nil else { return nil }
            failure = reason
            return problemHandler
        }
        handler?(reason)
    }

    /// Writes everything recorded so far to disk (turn end, task end), with the count of anything dropped.
    public func flush() {
        let turn = self.turn
        let elapsed = ContinuousClock.now - started
        queue.sync {
            noteDropped(turn: turn, at: Date(), elapsed: elapsed)
            if let handle { fsync(handle.fileDescriptor) }
        }
    }

    public func close() {
        flush()
        lock.withLock { closed = true }
        queue.sync { try? handle?.close() }
    }

    /// ISO 8601 in UTC with microseconds.
    public static func timestamp(_ date: Date) -> String {
        let interval = date.timeIntervalSince1970
        var seconds = time_t(interval.rounded(.down))
        let micros = Int((interval - Double(seconds)) * 1_000_000)
        var parts = tm()
        gmtime_r(&seconds, &parts)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%06dZ", parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday,
                      parts.tm_hour, parts.tm_min, parts.tm_sec, micros)
    }
}
