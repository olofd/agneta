// Claude Code's per-call usage, from its own session transcript (measured on Claude Code 2.1.326 through
// claude-agent-acp 0.107.2): `$CLAUDE_CONFIG_DIR/projects/<cwd, non-alphanumerics as "-">/<session>.jsonl`, and a
// subagent's calls in `<session>/subagents/agent-<id>.jsonl` beside it. Each assistant message's content blocks are
// one line each, all with the message's id and its final usage and stop reason, written together about 100 ms
// after the call ends: during the turn for every call but the last, whose lines land 10–25 ms after the prompt's
// result. A line without a stop reason (a call cut off) holds the stream's opening count, so it isn't final and is
// left alone. Read incrementally from where the last read stopped, only lines that can be assistant messages decoded.
import Foundation

final class ClaudeCodeTranscriptLedger: UsageLedger, @unchecked Sendable {
    let config: URL
    let session: String
    private let lock = NSLock()
    private var folder: URL? // the project folder holding the session's transcript
    private var files: [URL: (offset: UInt64, partial: Data)] = [:]
    private var reported: Set<String> = []

    init(config: URL, session: String) {
        self.config = config
        self.session = session
    }

    var completesStreamRows: Bool { true }

    private func locate() -> URL? {
        let projects = config.appending(path: "projects", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.first {
            FileManager.default.fileExists(atPath: $0.appending(path: "\(session).jsonl").path(percentEncoded: false))
        }
    }

    /// The session's transcript, then its subagents' (new ones appear while it runs).
    private func transcripts(in folder: URL) -> [URL] {
        let subagents = folder.appending(path: "\(session)/subagents", directoryHint: .isDirectory)
        let theirs = ((try? FileManager.default.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return [folder.appending(path: "\(session).jsonl")] + theirs
    }

    func read() -> (messages: [[String: JSONValue]], usage: [[String: JSONValue]], problem: String?) {
        lock.withLock {
            if folder == nil { folder = locate() }
            guard let folder else { return ([], [], nil) }
            var usage: [[String: JSONValue]] = []
            for file in transcripts(in: folder) {
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                defer { try? handle.close() }
                var state = files[file] ?? (0, Data())
                try? handle.seek(toOffset: state.offset)
                let data = handle.readDataToEndOfFile()
                state.offset += UInt64(data.count)
                state.partial.append(data)
                var start = state.partial.startIndex
                while let newline = state.partial[start...].firstIndex(of: UInt8(ascii: "\n")) {
                    if let row = Self.call(state.partial[start..<newline]), let id = row["id"]?.stringValue,
                        reported.insert(id).inserted
                    {
                        usage.append(row)
                    }
                    start = state.partial.index(after: newline)
                }
                state.partial.removeSubrange(state.partial.startIndex..<start)
                files[file] = state
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
            "output_partial": false, "cost": .null, "cost_source": "claude-code", "created": record["timestamp"] ?? .null,
            "basis": "engine-transcript"
        ]
    }
}
