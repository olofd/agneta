// Deleting a task from history deletes its conversation. A dedicated engine's home goes whole, and Claude Code's and
// Codex's files in the account folder are removed (EngineHomes). A shared engine keeps every task of an account in
// its own storage, so it's asked to delete the task's session (ACP `session/delete`), started if it isn't running,
// and then to clear what its storage still holds of it (`EngineAdapter.sessionsDeleted`).
import Foundation

extension Router {
    /// A task's conversation in an account's shared engine, read from its trace before the trace goes.
    public struct SharedConversation: Sendable, Hashable {
        public var account: String
        public var engine: String
        public var session: String
    }

    /// What deleting conversations did: how many the engines deleted, and why any weren't, or their storage kept a trace.
    public struct ConversationDeletion: Sendable {
        public var deleted = 0
        public var problems: [String] = []
    }

    /// The shared engine's conversation of a task, from its trace's `meta`; nil for a task on its own engine.
    public static func sharedConversation(_ meta: JSONValue) -> SharedConversation? {
        guard let engine = meta["engine"], engine["dedicated"]?.boolValue == false,
              let id = engine["id"]?.stringValue, let session = engine["session"]?.stringValue, !session.isEmpty,
              let account = meta["account"]?["id"]?.stringValue,
              engine["key"]?.stringValue == EngineKeys.shared(account: account, engine: id) else { return nil }
        return SharedConversation(account: account, engine: id, session: session)
    }

    /// Asks each account's shared engine to delete these conversations, starting it where it isn't running (it then
    /// stays, as after any task). An engine without `session/delete`, a provider signed out meanwhile (its engine
    /// state went with it) or an engine that fails is reported, never retried behind the user's back.
    public func deleteConversations(_ conversations: [SharedConversation]) async -> ConversationDeletion {
        var outcome = ConversationDeletion()
        let groups = Dictionary(grouping: Set(conversations)) { [$0.account, $0.engine] }
        for (pair, group) in groups {
            let (account, engine) = (pair[0], pair[1])
            guard accounts[account] != nil else { continue } // signed out: the engine's state is gone already
            guard let adapter = catalog.adapter(engine) else {
                outcome.problems.append("\(group.count) on \(engine): that engine isn't here")
                continue
            }
            let policy: SessionPolicy
            do { policy = try ownPolicy("forget") } catch {
                outcome.problems.append("\(group.count) on \(adapter.displayName): \(error)")
                continue
            }
            let plan = Plan(account: account, engine: adapter, policy: policy, servers: [], instructions: nil)
            let lease: EngineLease
            switch await launch(plan, key: EngineKeys.shared(account: account, engine: engine)) {
            case .success(let started): lease = started
            case .failure(let error):
                outcome.problems.append("\(group.count) on \(adapter.displayName): \(error.message)")
                continue
            }
            var deleted = 0
            for conversation in group {
                do {
                    _ = try await lease.peer.request("session/delete", ["sessionId": .string(conversation.session)])
                    deletedSessions[Self.process(lease), default: []].insert(conversation.session)
                    deleted += 1
                } catch let error as RPCError where error.code == RPCError.methodNotFound {
                    outcome.problems.append("\(adapter.displayName) can't delete a session")
                    break
                } catch {
                    outcome.problems.append("\(adapter.displayName) didn't delete a session: \(error)")
                }
            }
            if deleted > 0, let root = lease.stateRoot, let problem = lease.engine.sessionsDeleted(stateRoot: root) {
                outcome.problems.append("\(adapter.displayName)'s storage: \(problem)")
            }
            outcome.deleted += deleted
            await engines.release(lease)
        }
        return outcome
    }

    /// An engine process, for `deletedSessions`: its lease key and pid, since a new process starts with none deleted.
    static func process(_ lease: EngineLease) -> String { "\(lease.key)#\(lease.pid)" }

    /// A new engine session (`session/new`, or a fork's import), asked for again while the engine hands back one this
    /// process deleted. Measured on goose-acp 1.59.2: a new session takes the highest id left plus one, so deleting the
    /// newest frees its id for the next, and an id once closed fails as "Session not found" for the rest of the
    /// process. The unused session holds nothing of a task (no prompt, no instructions) and goes with the engine's state.
    func freshSession(_ lease: EngineLease, _ request: EngineRequest, id: (JSONValue) -> String?) async throws -> (id: String, result: JSONValue) {
        let deleted = deletedSessions[Self.process(lease)] ?? []
        for _ in 0...deleted.count {
            let result = try await lease.peer.request(request.method, request.params)
            guard let created = id(result) else { throw RPCError(code: RPCError.internalError, message: "The engine didn't create a session") }
            guard deleted.contains(created) else { return (created, result) }
        }
        throw RPCError(code: RPCError.internalError, message: "The engine only offered sessions it had deleted")
    }

    /// A session policy with no tools, in an empty folder of Agneta's own (nothing is written there), for engines
    /// Agneta asks something without a task: what they offer, or to delete a session.
    func ownPolicy(_ name: String) throws -> SessionPolicy {
        let root = context.appWorkspaces ?? FileManager.default.temporaryDirectory
        let folder = root.appending(path: ".agneta-\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var policy = SessionPolicy.fallback(workspace: folder.realFileURL)
        policy.tools = .appOnly
        return policy
    }
}
