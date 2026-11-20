// Claude Code's per-call usage, from its own session transcript (measured on Claude Code 2.1.326 through
// claude-agent-acp 0.107.2): `$CLAUDE_CONFIG_DIR/projects/<cwd, non-alphanumerics as "-">/<session>.jsonl`, and a
// subagent's calls in `<session>/subagents/agent-<id>.jsonl` beside it. Each assistant message's content blocks are
// one line each, all with the message's id and its final usage and stop reason, written together about 100 ms
// after the call ends: during the turn for every call but the last, whose lines land 10–25 ms after the prompt's
// result. A resumed session (session/load, a new process) appends to the same file. A line without a stop reason
// (a call cut off) holds the stream's opening count, so it isn't final and is left alone.
//
// The session's folder is the engine's to write, so it's read as untrusted: every component below `projects` is
// opened without following links, only regular files are read (never a FIFO, which would block, nor a device), a
// file is opened only when its size changed, at most `chunk` bytes per file per read, and a line longer than
// `maxLine` is dropped. Only lines that can be assistant messages are decoded.
import Darwin
import Foundation

final class ClaudeCodeTranscriptLedger: UsageLedger, @unchecked Sendable {
    let config: URL
    let session: String
    /// The project folder Claude Code names after the session's workspace, tried before the others.
    let preferredFolder: String?
    /// Bytes read from one file in one read, and from all of them.
    static let chunk = 4 << 20
    static let maxReadPerPoll = 32 << 20
    /// The longest line kept, and all files' unfinished lines together: past either, a line is dropped to its end.
    static let maxLine = 16 << 20
    static let maxBuffered = 32 << 20
    /// Subagent transcripts read (the first by name), and folder entries looked at to find them. Planted names
    /// sorting first can hide a real subagent's calls: no worse than forging its lines, which the engine also can.
    static let maxSubagents = 256
    static let maxNames = 4096
    /// New calls given per read (the rest are read at the next), and in all: the ids kept to report each once stay
    /// bounded, however many lines are planted.
    static let maxRowsPerRead = 4096
    static let maxCalls = 65_536
    private let lock = NSLock()
    private var folder: String? // the project folder holding the session's transcript, once found
    private var files: [String: (offset: Int64, partial: Data, discarding: Bool)] = [:] // by path below the folder
    private var reported: Set<String> = []
    private var skipWhenFound = false
    private var notice: String?
    private var noticed = false
    private var noticedTotal = false

    /// Nil for a session id that isn't a UUID, as Claude Code's are: it becomes a file name.
    init?(config: URL, session: String, preferredFolder: String? = nil) {
        guard UUID(uuidString: session) != nil else { return nil }
        self.config = config
        self.session = session
        self.preferredFolder = preferredFolder
    }

    var completesStreamRows: Bool { true }

    func takeNotice() -> String? {
        lock.withLock {
            defer { notice = nil }
            return notice
        }
    }

    /// What the reader holds between reads (for tests): unfinished lines' bytes and files followed.
    var held: (bytes: Int, files: Int) {
        lock.withLock { (files.values.reduce(0) { $0 + $1.partial.count }, files.count) }
    }

    // MARK: Opening without following links or leaving the device

    /// The projects folder, and the device it's on: nothing on another (a mount could block a read) is opened.
    private func openProjects() -> (fd: Int32, device: dev_t)? {
        let path = config.appending(path: "projects").path(percentEncoded: false)
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            close(fd)
            return nil
        }
        return (fd, info.st_dev)
    }

    private static func openFolder(_ name: String, in parent: Int32, device: dev_t) -> Int32? {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == device else {
            close(fd)
            return nil
        }
        return fd
    }

    /// The size of a regular file in a folder, without following a link; nil for anything else.
    private static func regularSize(_ name: String, in folder: Int32, device: dev_t) -> Int64? {
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_dev == device
        else { return nil }
        return Int64(info.st_size)
    }

    /// Up to `maxNames` entries of a folder that pass `keep`, sorted.
    private static func names(in folder: Int32, keep: (String) -> Bool = { _ in true }) -> [String] {
        let copy = dup(folder)
        guard copy >= 0 else { return [] }
        guard let directory = fdopendir(copy) else {
            close(copy)
            return []
        }
        defer { closedir(directory) }
        var names: [String] = []
        while names.count < maxNames, let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name != "." && name != ".." && keep(name) { names.append(name) }
        }
        return names.sorted()
    }

    /// The folder holding `<session>.jsonl`: the preferred one, else any. Found once.
    private func locate(_ projects: Int32, device: dev_t) -> String? {
        if let folder { return folder }
        for name in [preferredFolder].compactMap({ $0 }) + Self.names(in: projects) {
            guard let fd = Self.openFolder(name, in: projects, device: device) else { continue }
            defer { close(fd) }
            if Self.regularSize("\(session).jsonl", in: fd, device: device) != nil {
                folder = name
                return name
            }
        }
        return nil
    }

    /// Each transcript (the session's, then its subagents'), as its path below the project folder, the open folder
    /// holding it, its name there and its size. Links and anything not a regular file are left out.
    private func transcripts(
        _ projects: Int32, _ folder: String, device: dev_t, _ body: (String, Int32, String, Int64) -> Void
    ) {
        guard let own = Self.openFolder(folder, in: projects, device: device) else { return }
        defer { close(own) }
        let file = "\(session).jsonl"
        if let size = Self.regularSize(file, in: own, device: device) { body(file, own, file, size) }
        guard let sessionFolder = Self.openFolder(session, in: own, device: device) else { return }
        defer { close(sessionFolder) }
        guard let subagents = Self.openFolder("subagents", in: sessionFolder, device: device) else { return }
        defer { close(subagents) }
        for name in Self.names(in: subagents, keep: { $0.hasSuffix(".jsonl") }).prefix(Self.maxSubagents) {
            if let size = Self.regularSize(name, in: subagents, device: device) {
                body("subagents/\(name)", subagents, name, size)
            }
        }
    }

    /// Up to `count` new bytes of a regular file from `offset`; nil when it's no longer one. Never blocks: the file
    /// is checked again once open, and opened non-blocking in case it was swapped for a FIFO in between.
    private static func readNew(_ name: String, in folder: Int32, device: dev_t, from offset: Int64, count: Int)
        -> Data?
    {
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_dev == device else { return nil }
        let count = Int(min(Int64(info.st_size) - offset, Int64(count)))
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        return read > 0 ? data.prefix(read) : Data()
    }

    // MARK: Reading

    /// On resume: what's there belongs to earlier turns, so reading starts at each file's end (sizes only, nothing
    /// read). A transcript not found yet is skipped to its end when it is.
    func startAfterExisting() -> Bool {
        lock.withLock {
            guard let (projects, device) = openProjects() else {
                skipWhenFound = true
                return true
            }
            defer { close(projects) }
            guard let folder = locate(projects, device: device) else {
                skipWhenFound = true
                return true
            }
            skipToEnds(projects, folder, device: device)
            return true
        }
    }

    private func skipToEnds(_ projects: Int32, _ folder: String, device: dev_t) {
        files = [:]
        transcripts(projects, folder, device: device) { path, _, _, size in files[path] = (size, Data(), false) }
    }

    func read() -> (messages: [[String: JSONValue]], usage: [[String: JSONValue]], problem: String?) {
        lock.withLock {
            guard let (projects, device) = openProjects() else { return ([], [], nil) }
            defer { close(projects) }
            guard let folder = locate(projects, device: device) else { return ([], [], nil) }
            if skipWhenFound {
                skipWhenFound = false
                skipToEnds(projects, folder, device: device)
                return ([], [], nil)
            }
            var usage: [[String: JSONValue]] = []
            var listed: Set<String> = []
            var budget = Self.maxReadPerPoll
            var buffered = files.values.reduce(0) { $0 + $1.partial.count }
            transcripts(projects, folder, device: device) { path, holder, name, size in
                listed.insert(path)
                var state = files[path] ?? (0, Data(), false)
                // Replaced by a shorter file: what's there now is taken as read, so nothing is counted twice.
                if size < state.offset { state = (size, Data(), false) }
                defer { files[path] = state }
                guard budget > 0, usage.count < Self.maxRowsPerRead, reported.count < Self.maxCalls,
                    size > state.offset,
                    var data = Self.readNew(
                        name, in: holder, device: device, from: state.offset, count: min(Self.chunk, budget))
                else { return }
                budget -= data.count
                state.offset += Int64(data.count)
                if state.discarding { // inside a line too long to keep: only what follows its end
                    guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return }
                    data = data[data.index(after: newline)...]
                    state.discarding = false
                }
                buffered -= state.partial.count
                let unscanned = state.partial.count // what's held has no newline: only the new bytes are searched
                state.partial.append(data)
                var start = state.partial.startIndex
                var from = state.partial.startIndex + unscanned
                while usage.count < Self.maxRowsPerRead, reported.count < Self.maxCalls,
                    let newline = state.partial[from...].firstIndex(of: UInt8(ascii: "\n"))
                {
                    if let row = Self.call(state.partial[start..<newline]), let id = row["id"]?.stringValue,
                        reported.insert(id).inserted
                    {
                        usage.append(row)
                    }
                    start = state.partial.index(after: newline)
                    from = start
                }
                if usage.count >= Self.maxRowsPerRead || reported.count >= Self.maxCalls {
                    // At a cap: what's after the last line read is read again next time (at the total, never).
                    state.offset -= Int64(state.partial.endIndex - start)
                    state.partial = Data()
                    if reported.count >= Self.maxCalls {
                        if !noticedTotal {
                            noticedTotal = true
                            notice = "Claude Code's transcript gave \(Self.maxCalls) calls; later ones aren't read"
                        }
                    } else if !noticed {
                        noticed = true
                        notice =
                            "Claude Code's transcript gave more than \(Self.maxRowsPerRead) calls at once; the rest are read later"
                    }
                    return
                }
                state.partial.removeSubrange(state.partial.startIndex..<start)
                if state.partial.count > Self.maxLine || buffered + state.partial.count > Self.maxBuffered {
                    state.partial = Data() // a line too long to be a call's: dropped up to its end
                    state.discarding = true
                }
                buffered += state.partial.count
            }
            files = files.filter { listed.contains($0.key) } // files gone, or no longer read, are forgotten
            return ([], usage, nil)
        }
    }

    private static let assistantMarker = Data(#""type":"assistant""#.utf8)

    /// One transcript line as a final call's usage row, or nil.
    static func call(_ line: Data) -> [String: JSONValue]? {
        // Tool results (most of the file's bytes) never need decoding.
        guard line.range(of: assistantMarker) != nil, let record = try? JSONCoding.decode(Data(line)),
            record["type"]?.stringValue == "assistant", let message = record["message"],
            let id = message["id"]?.stringValue, id.utf8.count <= 256, let usage = message["usage"],
            usage.objectValue != nil,
            let stop = message["stop_reason"], stop != .null,
            message["model"]?.stringValue != "<synthetic>" // an error Claude Code wrote itself, no model call
        else { return nil }
        return [
            "id": .string(id), "model": message["model"] ?? .null,
            "input_tokens": usage["input_tokens"] ?? .null, "output_tokens": usage["output_tokens"] ?? .null,
            "cache_read_tokens": usage["cache_read_input_tokens"] ?? .null,
            "cache_write_tokens": usage["cache_creation_input_tokens"] ?? .null,
            "output_partial": false, "cost": .null, "cost_source": "claude-code",
            "created": record["timestamp"] ?? .null,
            "basis": "engine-transcript"
        ]
    }
}
