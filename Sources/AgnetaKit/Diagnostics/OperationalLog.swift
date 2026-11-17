// Agneta's own log: what Agneta did, for finding its own faults:
// event names, ids, counts and timing, never prompts, tool content, tokens or
// keys (callers pass only such fields; values are masked again on write).
// JSON lines in ~/Library/Logs/Agneta, rotated by size, kept 7 days.
import Foundation

public final class OperationalLog: @unchecked Sendable {
    public let folder: URL
    public let mask: SecretMask
    private let maxBytes: Int
    private let keepDays: Int
    private let queue = DispatchQueue(label: "agneta.log")
    private var handle: FileHandle?
    private var bytes = 0

    public init(folder: URL, mask: SecretMask = SecretMask(), maxBytes: Int = 5 << 20, keepDays: Int = 7) {
        self.folder = folder
        self.mask = mask
        self.maxBytes = maxBytes
        self.keepDays = keepDays
    }

    public var file: URL { folder.appending(path: "agneta.jsonl") }

    /// One event. Pass ids, names, counts and timings only.
    public func log(_ event: String, level: String = "info", _ fields: [String: JSONValue] = [:]) {
        let now = Date()
        queue.async { [self] in
            let masked = mask.mask(.object(fields)).objectValue ?? [:]
            let line = TraceJSON.line(header: [("t", .string(TraceWriter.timestamp(now))), ("level", .string(level)), ("event", .string(event))], fields: masked)
            guard let handle = openIfNeeded() else { return }
            try? handle.write(contentsOf: line)
            bytes += line.count
            if bytes >= maxBytes { rotate() }
        }
    }

    public func error(_ event: String, _ fields: [String: JSONValue] = [:]) { log(event, level: "error", fields) }

    /// Waits until everything logged so far is written (tests, quitting).
    public func flush() { queue.sync { try? handle?.synchronize() } }

    /// The last `count` lines, oldest first, across the current and the previous file.
    public func tail(_ count: Int) -> [String] {
        flush()
        let previous = (try? String(contentsOf: folder.appending(path: "agneta.1.jsonl"), encoding: .utf8)) ?? ""
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return Array((previous + current).split(separator: "\n").map(String.init).suffix(count))
    }

    private func openIfNeeded() -> FileHandle? {
        if let handle { return handle }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        pruneOld()
        if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: file)
        bytes = Int((try? handle?.seekToEnd()) ?? 0)
        return handle
    }

    /// agneta.jsonl → agneta.1.jsonl → agneta.2.jsonl; older ones go.
    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: folder.appending(path: "agneta.2.jsonl"))
        try? fm.moveItem(at: folder.appending(path: "agneta.1.jsonl"), to: folder.appending(path: "agneta.2.jsonl"))
        try? fm.moveItem(at: file, to: folder.appending(path: "agneta.1.jsonl"))
        bytes = 0
    }

    private func pruneOld() {
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }
}
