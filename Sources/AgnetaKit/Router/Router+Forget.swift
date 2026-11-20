// Deleting a task from history deletes its conversation. A dedicated engine's home goes whole, and Claude Code's and
// Codex's files in the account folder are removed (EngineHomes). A shared engine keeps every task of an account in
// its own storage, so it's asked to delete the task's session (ACP `session/delete`), started if it isn't running,
// and then to clear what its storage still holds of it (`EngineAdapter.sessionsDeleted`). The runtime keeps the
// conversations still to delete (AgnetaRuntime, `pendingConversations`) until they are, storage included: a session the
// engine deleted while its storage couldn't be cleared stays queued, and only the clearing is tried again.
import Foundation

extension Router {
    /// A task's conversation in an account's shared engine, read from its trace before the trace goes.
    public struct SharedConversation: Sendable, Hashable, Codable {
        public var account: String
        public var engine: String
        public var session: String
        /// The engine deleted the session already, and only what its storage still holds of it is left to clear (nil:
        /// not deleted yet).
        public var deleted: Bool? = nil
    }

    /// What deleting conversations did: how many the engines deleted, and why any weren't, or their storage kept a trace.
    public struct ConversationDeletion: Sendable {
        public var deleted = 0
        public var problems: [String] = []
        /// Conversations nothing more can be done for: deleted with their storage cleared, or on an engine that can't
        /// delete one. The rest are worth asking again (the engine wasn't here, failed or didn't answer, or their
        /// provider isn't served yet).
        public var done: Set<SharedConversation> = []
        /// Of those asked, the ones the engine has deleted (now or before) whose storage couldn't be cleared: asked
        /// again, `deleted`, only the clearing is tried.
        public var uncleared: Set<SharedConversation> = []
    }

    /// How long a shared engine has to answer `session/delete`: one that doesn't (stuck, or busy past it) can't hold up
    /// the pass, and with it every later one; the conversation stays queued.
    static let deleteWithin: Duration = .seconds(10)

    /// The shared engine's conversation of a task, from its trace's `meta`; nil for a task on its own engine.
    public static func sharedConversation(_ meta: JSONValue) -> SharedConversation? {
        guard let engine = meta["engine"], engine["dedicated"]?.boolValue == false,
            let id = engine["id"]?.stringValue, let session = engine["session"]?.stringValue, !session.isEmpty,
            let account = meta["account"]?["id"]?.stringValue,
            engine["key"]?.stringValue == EngineKeys.shared(account: account, engine: id)
        else { return nil }
        return SharedConversation(account: account, engine: id, session: session)
    }

    /// Asks each account's shared engine to delete these conversations, starting it where it isn't running (it then
    /// stays, as after any task). An engine without `session/delete`, one that fails or doesn't answer within
    /// `deleteWithin`, and a storage that can't be cleared are reported; a provider not served (not yet, at launch, or
    /// signed out: its engine state went with it) is left for the runtime to decide.
    public func deleteConversations(_ conversations: [SharedConversation]) async -> ConversationDeletion {
        var outcome = ConversationDeletion()
        let groups = Dictionary(grouping: Set(conversations)) { [$0.account, $0.engine] }
        for (pair, group) in groups {
            let (account, engine) = (pair[0], pair[1])
            guard accounts[account] != nil else { continue }
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
            // Deleted now or before: what its storage still holds of them is cleared next. One whose rows its storage
            // no longer has is deleted already (an answer to an earlier ask that came too late), so isn't asked again.
            func gone(_ conversation: SharedConversation) -> Bool {
                lease.stateRoot.flatMap { lease.engine.sessionStored(stateRoot: $0, session: conversation.session) }
                    == false
            }
            var deleted = Set(group.filter { $0.deleted == true || gone($0) })
            for conversation in group.filter({ !deleted.contains($0) }) {
                // Asked is as good as deleted for a new session's id: one that answers late may still delete it.
                deletedSessions[Self.process(lease), default: []].insert(conversation.session)
                do {
                    let peer = lease.peer, params: JSONValue = ["sessionId": .string(conversation.session)]
                    _ = try await EngineSupervisor.within(Self.deleteWithin) {
                        try await peer.request("session/delete", params)
                    }
                    outcome.deleted += 1
                    deleted.insert(conversation)
                } catch let error as RPCError where error.code == RPCError.methodNotFound {
                    outcome.problems.append("\(adapter.displayName) can't delete a session")
                    // Asking again can't help; those it deleted before still have their storage cleared.
                    outcome.done.formUnion(group.filter { !deleted.contains($0) })
                    break
                } catch is EngineSupervisor.TimedOut {
                    // Stuck, or busy past the bound: the rest wait for the next pass rather than as long again each.
                    outcome.problems.append(
                        "\(adapter.displayName) didn't answer within \(Self.deleteWithin.components.seconds) s")
                    break
                } catch {
                    // Deleted meanwhile (an earlier ask's late answer): it says the session isn't there.
                    if gone(conversation) {
                        deleted.insert(conversation)
                    } else {
                        outcome.problems.append("\(adapter.displayName) didn't delete a session: \(error)")
                    }
                }
            }
            // A storage that couldn't be cleared (another connection held its log, say) still holds their words: they
            // stay queued until it is.
            if !deleted.isEmpty, let root = lease.stateRoot, let problem = lease.engine.sessionsDeleted(stateRoot: root)
            {
                outcome.problems.append("\(adapter.displayName)'s storage: \(problem)")
                outcome.uncleared.formUnion(deleted.subtracting(outcome.done))
            } else {
                outcome.done.formUnion(deleted)
            }
            await engines.release(lease)
        }
        return outcome
    }

    /// An engine process, for `deletedSessions`: its lease key and pid, since a new process starts with none deleted.
    static func process(_ lease: EngineLease) -> String { "\(lease.key)#\(lease.pid)" }

    /// A new engine session (`session/new`, or a fork's import), asked for again while the engine hands back one this
    /// process was asked to delete. Measured on goose-acp 1.59.2: a new session takes the highest id left plus one, so deleting the
    /// newest frees its id for the next, and an id once closed fails as "Session not found" for the rest of the
    /// process. The unused session holds nothing of a task (no prompt, no instructions) and goes with the engine's state.
    func freshSession(_ lease: EngineLease, _ request: EngineRequest, id: (JSONValue) -> String?) async throws -> (
        id: String, result: JSONValue
    ) {
        let deleted = deletedSessions[Self.process(lease)] ?? []
        for _ in 0...deleted.count {
            let result = try await lease.peer.request(request.method, request.params)
            guard let created = id(result) else {
                throw RPCError(code: RPCError.internalError, message: "The engine didn't create a session")
            }
            guard deleted.contains(created) else { return (created, result) }
        }
        throw RPCError(code: RPCError.internalError, message: "The engine only offered sessions it had deleted")
    }

    /// A session policy with no tools, in an empty folder of Agneta's own (nothing is written there), for engines
    /// Agneta asks something without a task: what they offer, or to delete a session.
    func ownPolicy(_ name: String) throws -> SessionPolicy {
        let root = context.appWorkspaces ?? FileManager.default.temporaryDirectory
        let folder = root.appending(path: ".agneta-\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var policy = SessionPolicy.fallback(workspace: folder.realFileURL)
        policy.tools = .appOnly
        return policy
    }
}
