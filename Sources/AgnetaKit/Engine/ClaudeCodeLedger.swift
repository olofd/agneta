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
    static let chunk = 4 << 20
    static let maxLine = 16 << 20
    static let maxSubagents = 256
    private let lock = NSLock()
    private var folder: String? // the project folder holding the session's transcript, once found
    private var files: [String: (offset: Int64, partial: Data, discarding: Bool)] = [:] // by path below the folder
    private var reported: Set<String> = []
    private var skipWhenFound = false

    /// Nil for a session id that isn't a UUID, as Claude Code's are: it becomes a file name.
    init?(config: URL, session: String, preferredFolder: String? = nil) {
        guard UUID(uuidString: session) != nil else { return nil }
        self.config = config
        self.session = session
        self.preferredFolder = preferredFolder
    }

    var completesStreamRows: Bool { true }

    // MARK: Opening without following links

    private static func openFolder(_ name: String, in parent: Int32) -> Int32? {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        return fd >= 0 ? fd : nil
    }

    private func openProjects() -> Int32? {
        let path = config.appending(path: "projects").path(percentEncoded: false)
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        return fd >= 0 ? fd : nil
    }

    /// The size of a regular file in a folder, without following a link; nil for anything else.
    private static func regularSize(_ name: String, in folder: Int32) -> Int64? {
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return Int64(info.st_size)
    }

    private static func names(in folder: Int32) -> [String] {
        let copy = dup(folder)
        guard copy >= 0 else { return [] }
        guard let directory = fdopendir(copy) else {
            close(copy)
            return []
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    /// The folder holding `<session>.jsonl`: the preferred one, else any. Found once.
    private func locate(_ projects: Int32) -> String? {
        if let folder { return folder }
        for name in [preferredFolder].compactMap({ $0 }) + Self.names(in: projects) {
            guard let fd = Self.openFolder(name, in: projects) else { continue }
            defer { close(fd) }
            if Self.regularSize("\(session).jsonl", in: fd) != nil {
                folder = name
                return name
            }
        }
        return nil
    }

    /// Each transcript (the session's, then its subagents'), as its path below the project folder, the open folder
    /// holding it, its name there and its size. Links and anything not a regular file are left out.
    private func transcripts(_ projects: Int32, _ folder: String, _ body: (String, Int32, String, Int64) -> Void) {
        guard let own = Self.openFolder(folder, in: projects) else { return }
        defer { close(own) }
        let file = "\(session).jsonl"
        if let size = Self.regularSize(file, in: own) { body(file, own, file, size) }
        guard let sessionFolder = Self.openFolder(session, in: own) else { return }
        defer { close(sessionFolder) }
        guard let subagents = Self.openFolder("subagents", in: sessionFolder) else { return }
        defer { close(subagents) }
        for name in Self.names(in: subagents).filter({ $0.hasSuffix(".jsonl") }).prefix(Self.maxSubagents) {
            if let size = Self.regularSize(name, in: subagents) { body("subagents/\(name)", subagents, name, size) }
        }
    }

    /// Up to `chunk` new bytes of a regular file from `offset`; nil when it's no longer one. Never blocks: the file
    /// is checked again once open, and opened non-blocking in case it was swapped for a FIFO in between.
    private static func readNew(_ name: String, in folder: Int32, from offset: Int64) -> Data? {
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let count = Int(min(Int64(info.st_size) - offset, Int64(chunk)))
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
            guard let projects = openProjects() else {
                skipWhenFound = true
                return true
            }
            defer { close(projects) }
            guard let folder = locate(projects) else {
                skipWhenFound = true
                return true
            }
            transcripts(projects, folder) { path, _, _, size in files[path] = (size, Data(), false) }
            return true
        }
    }

    func read() -> (messages: [[String: JSONValue]], usage: [[String: JSONValue]], problem: String?) {
        lock.withLock {
            guard let projects = openProjects() else { return ([], [], nil) }
            defer { close(projects) }
            guard let folder = locate(projects) else { return ([], [], nil) }
            if skipWhenFound {
                skipWhenFound = false
                transcripts(projects, folder) { path, _, _, size in files[path] = (size, Data(), false) }
                return ([], [], nil)
            }
            var usage: [[String: JSONValue]] = []
            transcripts(projects, folder) { path, holder, name, size in
                var state = files[path] ?? (0, Data(), false)
                if size < state.offset { state = (0, Data(), false) } // replaced: read again (ids are reported once)
                guard size > state.offset, let data = Self.readNew(name, in: holder, from: state.offset) else { return }
                state.offset += Int64(data.count)
                state.partial.append(data)
                var start = state.partial.startIndex
                while let newline = state.partial[start...].firstIndex(of: UInt8(ascii: "\n")) {
                    if !state.discarding, let row = Self.call(state.partial[start..<newline]),
                        let id = row["id"]?.stringValue, reported.insert(id).inserted
                    {
                        usage.append(row)
                    }
                    state.discarding = false
                    start = state.partial.index(after: newline)
                }
                state.partial.removeSubrange(state.partial.startIndex..<start)
                if state.partial.count > Self.maxLine { // a line too long to be a call's: dropped up to its end
                    state.partial = Data()
                    state.discarding = true
                }
                files[path] = state
            }
            return ([], usage, nil)
        }
    }

    private static let assistantMarker = Data(#""type":"assistant""#.utf8)

    /// One transcript line as a final call's usage row, or nil.
    static func call(_ line: Data) -> [String: JSONValue]? {
        // Tool results (most of the file's bytes) never need decoding.
        guard line.range(of: assistantMarker) != nil, let record = try? JSONCoding.decode(Data(line)),
            record["type"]?.stringValue == "assistant", let message = record["message"],
            let id = message["id"]?.stringValue, let usage = message["usage"], usage.objectValue != nil,
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
