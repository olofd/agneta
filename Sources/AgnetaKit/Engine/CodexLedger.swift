// Codex's per-call usage, from its own session file
// `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<time>-<session id>.jsonl` (measured on
// Codex 0.167.0): one `token_usage_record` per model call, with its response id
// and usage; the turn's model in `turn_context`. Codex counts cached tokens
// inside input_tokens, so input here is the uncached part, as other engines report it.
// Read incrementally from where the last read stopped.
import Foundation

final class CodexRolloutLedger: UsageLedger, @unchecked Sendable {
    let codexHome: URL
    let session: String
    private let lock = NSLock()
    private var file: URL?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var models: [String: String] = [:] // turn id → model
    private var plan: JSONValue? // the plan's limits, from the latest token_count

    init(codexHome: URL, session: String) {
        self.codexHome = codexHome
        self.session = session
    }

    private func locate() -> URL? {
        let sessions = codexHome.appending(path: "sessions", directoryHint: .isDirectory)
        guard let walker = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.lastPathComponent.hasPrefix("rollout-") && url.lastPathComponent.hasSuffix("\(session).jsonl") {
            return url
        }
        return nil
    }

    func read() -> (messages: [[String: JSONValue]], usage: [[String: JSONValue]], problem: String?) {
        lock.withLock {
            if file == nil { file = locate() }
            guard let file, let handle = try? FileHandle(forReadingFrom: file) else { return ([], [], nil) }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            let data = handle.readDataToEndOfFile()
            offset += UInt64(data.count)
            partial.append(data)
            var usage: [[String: JSONValue]] = []
            while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
                let line = partial[partial.startIndex..<newline]
                partial.removeSubrange(partial.startIndex...newline)
                guard let record = try? JSONCoding.decode(Data(line)), let payload = record["payload"] else { continue }
                switch record["type"]?.stringValue {
                case "event_msg" where payload["type"]?.stringValue == "token_count":
                    // The plan's own limits (ChatGPT): used percent, window and reset per limit.
                    if let limits = payload["rate_limits"], limits != .null {
                        plan = limits
                        if !usage.isEmpty { usage[usage.count - 1]["plan"] = limits }
                    }
                case "turn_context":
                    if let turn = payload["turn_id"]?.stringValue, let model = payload["model"]?.stringValue { models[turn] = model }
                case "token_usage_record":
                    guard let tokens = payload["usage"] else { continue }
                    let input = tokens["input_tokens"]?.intValue, cached = tokens["cached_input_tokens"]?.intValue ?? 0
                    usage.append([
                        "id": payload["response_id"] ?? .null,
                        "model": payload["turn_id"]?.stringValue.flatMap { models[$0] }.map(JSONValue.string) ?? .null,
                        "input_tokens": input.map { .int($0 - cached) } ?? .null, "output_tokens": tokens["output_tokens"] ?? .null,
                        "cache_read_tokens": .int(cached), "cache_write_tokens": tokens["cache_write_input_tokens"] ?? .null,
                        "reasoning_tokens": tokens["reasoning_output_tokens"] ?? .null,
                        "cost": .null, "cost_source": "codex", "created": record["timestamp"] ?? .null,
                        "plan": plan ?? .null,
                    ])
                default: break
                }
            }
            return ([], usage, nil)
        }
    }
}
