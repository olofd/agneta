// Engine homes of dedicated sessions (`Engines/<account>-<id>`): each holds that
// session's engine state, its conversation included, which `session/load` needs.
// So they live exactly as long as the task's history: removed with it, with the
// account at sign-out, and swept when nothing refers to them any more. Engines
// whose state is the account's (Claude Code, Codex) keep a task's conversation in
// the account's folder instead: those files go with the task too.
import Foundation

/// Lease keys: `<account>/<id>` for a dedicated engine, `<account>/shared-<engine>` for an account's shared one. Every
/// check of "is this a shared engine" goes through `isShared`, so a new key shape can't slip past one of them.
public enum EngineKeys {
    /// The shared engine of an account for one engine: one process per account and engine, never two on one state.
    public static func shared(account: String, engine: String) -> String { "\(account)/shared-\(engine)" }

    /// Whether a key names a shared engine.
    public static func isShared(_ key: String) -> Bool {
        key.split(separator: "/").last?.hasPrefix("shared-") == true
    }
}

public enum EngineHomes {
    public static func folder(root: URL) -> URL { root.appending(path: "Engines", directoryHint: .isDirectory) }

    /// The home of the engine with this lease key (`account/id` → `Engines/account-id`).
    public static func home(root: URL, key: String) -> URL {
        folder(root: root).appending(path: key.replacingOccurrences(of: "/", with: "-"), directoryHint: .isDirectory)
    }

    /// Removes the engine homes of these tasks, and their conversations kept in an account's folder, read from their
    /// traces' `meta` (call before deleting the traces).
    public static func remove(tasks: [String], traces: Traces, root: URL, keepingConversationsOf kept: Set<String> = [])
    {
        for task in tasks {
            guard let engine = traces.meta(task: task)?["engine"] else { continue }
            if !kept.contains(engine["id"]?.stringValue ?? "") {
                for file in conversation(engine: engine, root: root) { try? FileManager.default.removeItem(at: file) }
            }
            guard engine["dedicated"]?.boolValue == true, let key = engine["key"]?.stringValue, !key.contains("..")
            else { continue }
            try? FileManager.default.removeItem(at: home(root: root, key: key))
        }
    }

    /// A task's conversation as its engine keeps it in the account's folder (its state root, inside Agneta's data):
    /// Claude Code's transcript, Codex's rollout. Other engines keep theirs in the engine home.
    static func conversation(engine: JSONValue, root: URL) -> [URL] {
        guard let session = engine["session"]?.stringValue, !session.isEmpty,
            session.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
            let path = engine["stateRoot"]?.stringValue
        else { return [] }
        let state = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        guard state.isInside(root.standardizedFileURL),
            state.path(percentEncoded: false) != root.standardizedFileURL.path(percentEncoded: false)
        else { return [] }
        switch engine["id"]?.stringValue {
        case "claude-code": return ClaudeCodeAdapter.transcripts(config: state, session: session)
        case "codex": return CodexAdapter.rollouts(codexHome: state, session: session)
        default: return []
        }
    }

    /// Removes every engine home of an account (sign-out).
    public static func remove(account: String, root: URL) {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: folder(root: root).path(percentEncoded: false))) ?? []
        for name in names where name.hasPrefix(account + "-") {
            try? FileManager.default.removeItem(
                at: folder(root: root).appending(path: name, directoryHint: .isDirectory))
        }
    }

    /// Removes homes no trace refers to and untouched since `before` (left by a crash, or by
    /// builds before traces). Homes of engines running now are in `keep`.
    @discardableResult
    public static func sweep(root: URL, traces: Traces, before: Date, keep: Set<String>) -> [String] {
        let base = folder(root: root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path(percentEncoded: false))) ?? []
        var referenced: Set<String> = keep.map { $0.replacingOccurrences(of: "/", with: "-") }.reduce(into: []) {
            $0.insert($1)
        }
        // No candidate is known to be an orphan until every retained trace has been accounted for.
        guard
            let traceNames = try? FileManager.default.contentsOfDirectory(
                atPath: traces.folder.path(percentEncoded: false))
        else { return [] }
        for name in traceNames where name.hasSuffix(".jsonl") {
            guard let key = traces.meta(task: String(name.dropLast(6)))?["engine"]?["key"]?.stringValue
            else { return [] }
            referenced.insert(key.replacingOccurrences(of: "/", with: "-"))
        }
        var removed: [String] = []
        for name in names where !referenced.contains(name) {
            let url = base.appending(path: name, directoryHint: .isDirectory)
            guard
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                modified < before
            else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed.append(name) }
        }
        return removed
    }
}
