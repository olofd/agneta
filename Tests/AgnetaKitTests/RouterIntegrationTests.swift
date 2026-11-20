// Two apps over the real WebSocket server, router and supervisor, with the
// pinned goose-acp and the fake model. Checks routing, isolation between apps,
// per-session engines for editing sessions, the tool broker, and steering.
import AgnetaFakes
import Foundation
import Testing

@testable import AgnetaKit

/// A minimal ACP client over URLSessionWebSocketTask, like an app's.
final class AppClient: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var nextID: Int64 = 1
    private var waiting: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    /// Set once the socket ends: later requests fail at once instead of waiting forever.
    private var closed = false
    private var updates: [String: [JSONValue]] = [:]
    private var traces: [String: [JSONValue]] = [:]
    private var permissionOption = "allow_once"
    private var permissionCount = 0
    private(set) var token: String?

    /// The option id this client picks when Agneta asks about a tool.
    func answerPermissions(with option: String) { lock.withLock { permissionOption = option } }
    var permissionRequests: Int { lock.withLock { permissionCount } }
    /// Other notifications from Agneta, e.g. `agneta/queued`, by method.
    func notifications(_ method: String) -> [JSONValue] { lock.withLock { others[method] ?? [] } }
    /// Every `session/update` the app got for a session, in order.
    func updates(_ session: String) -> [JSONValue] { lock.withLock { updates[session] ?? [] } }
    private var others: [String: [JSONValue]] = [:]

    /// Records received live over `agneta/trace`.
    func traceRecords(_ session: String) -> [JSONValue] { lock.withLock { traces[session] ?? [] } }
    var isClosed: Bool { lock.withLock { closed } }

    init(port: UInt16) {
        self.port = port
        task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/acp")!)
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self, case .success(.string(let text)) = result,
                let message = try? RPCMessage.parse(Data(text.utf8))
            else {
                self?.lock.withLock {
                    self?.closed = true
                    self?.waiting.values.forEach { $0.resume(throwing: RPCPeer.PeerError.closed("socket")) }
                    self?.waiting.removeAll()
                }
                return
            }
            switch message {
            case .response(.int(let id), let result):
                let continuation = self.lock.withLock { self.waiting.removeValue(forKey: id) }
                switch result {
                case .success(let value): continuation?.resume(returning: value)
                case .failure(let error): continuation?.resume(throwing: error)
                }
            case .notification("session/update", let params):
                if let id = params?["sessionId"]?.stringValue, let update = params?["update"] {
                    self.lock.withLock { self.updates[id, default: []].append(update) }
                }
            case .notification("agneta/trace", let params):
                if let id = params?["sessionId"]?.stringValue {
                    self.lock.withLock { self.traces[id, default: []] += params?["records"]?.arrayValue ?? [] }
                }
            case .notification(let method, let params) where method.hasPrefix("agneta/"):
                self.lock.withLock { self.others[method, default: []].append(params ?? .null) }
            case .request(let id, "session/request_permission", _):
                let option = self.lock.withLock {
                    self.permissionCount += 1; return self.permissionOption
                }
                let reply = RPCMessage.response(
                    id: id, result: .success(["outcome": ["outcome": "selected", "optionId": .string(option)]]))
                self.task.send(.string(String(decoding: try! reply.encoded(), as: UTF8.self))) { _ in }
            default: break
            }
            self.receive()
        }
    }

    /// No answer from Agneta within `answerWithin`: a test that would wait for ever fails instead, naming the request.
    /// Not an RPCError, so it never passes for a refusal a test expects.
    struct Unanswered: Error, CustomStringConvertible {
        let method: String
        var description: String { "Agneta didn't answer \(method) within \(Int(AppClient.answerWithin)) s" }
    }

    /// Twice the longest Agneta itself waits within a request (a minute, for an engine to start or a check of an app's
    /// sockets and ports).
    static let answerWithin: TimeInterval = 120

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let id = lock.withLock {
            defer { nextID += 1 }; return nextID
        }
        let data = try RPCMessage.request(id: .int(id), method: method, params: params).encoded()
        return try await withCheckedThrowingContinuation { continuation in
            let isClosed = lock.withLock { () -> Bool in
                if !closed { waiting[id] = continuation }
                return closed
            }
            guard !isClosed else { continuation.resume(throwing: RPCPeer.PeerError.closed("socket")); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.answerWithin) { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.waiting.removeValue(forKey: id) }?.resume(
                    throwing: Unanswered(method: method))
            }
            task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
                guard let error, let self else { return }
                self.lock.withLock { self.waiting.removeValue(forKey: id) }?.resume(throwing: error)
            }
        }
    }

    func notify(_ method: String, _ params: JSONValue) {
        let data = try! RPCMessage.notification(method: method, params: params).encoded()
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    func text(_ session: String) -> String {
        lock.withLock {
            (updates[session] ?? []).compactMap {
                $0["sessionUpdate"]?.stringValue == "agent_message_chunk" ? $0["content"]?["text"]?.stringValue : nil
            }.joined()
        }
    }

    func toolOutput(_ session: String) -> String {
        lock.withLock {
            (updates[session] ?? []).filter {
                $0["sessionUpdate"]?.stringValue == "tool_call_update" && $0["status"]?.stringValue == "completed"
            }
            .compactMap { $0["content"]?.arrayValue?.first?["content"]?["text"]?.stringValue }.joined()
        }
    }

    func activeRunID(_ session: String) -> String? {
        lock.withLock {
            (updates[session] ?? []).reversed().compactMap { $0["_meta"]?["goose"]?["activeRunId"]?.stringValue }.first
        }
    }

    /// The scope each test stack's apps ask for, by the stack's port: its own work folder, with workspace tools.
    nonisolated(unsafe) private static var scopes: [UInt16: JSONValue] = [:]
    private static let scopesLock = NSLock()
    static func register(scope folder: URL, port: UInt16) {
        scopesLock.withLock {
            scopes[port] = ["tools": "workspace", "folders": [.string(folder.realFileURL.path(percentEncoded: false))]]
        }
    }
    private let port: UInt16

    /// Pairs with the scope registered for this port (`scope` overrides it).
    func pairAndInitialize(_ name: String, scope: JSONValue? = nil) async throws {
        let scope = scope ?? Self.scopesLock.withLock { Self.scopes[port] } ?? .null
        let paired = try await request("agneta/pair", ["name": .string(name), "scope": scope])
        let token = try #require(paired["token"]?.stringValue)
        lock.withLock { self.token = token }
        _ = try await request(
            "initialize",
            ["protocolVersion": 1, "clientCapabilities": [:], "_meta": ["agneta": ["token": .string(token)]]])
    }

    /// `sandbox`: the app's ask, or nil for the grant's (full power by default).
    func newSession(cwd: URL, tools: String, account: String = "dev", sandbox: String? = nil) async throws -> String {
        var policy: JSONValue = ["tools": .string(tools), "network": "none", "approval": "never-ask"]
        if let sandbox { policy = policy.setting("sandbox", to: .string(sandbox)) }
        let result = try await request(
            "session/new",
            [
                "cwd": .string(cwd.path(percentEncoded: false)), "mcpServers": [],
                "_meta": [SessionPolicy.key: policy, "agneta": ["account": .string(account)]]
            ])
        return try #require(result["sessionId"]?.stringValue)
    }

    func prompt(_ session: String, _ text: String) async throws -> JSONValue {
        try await request(
            "session/prompt", ["sessionId": .string(session), "prompt": [["type": "text", "text": .string(text)]]])
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }
}

@Suite(
    .serialized,
    .enabled(if: GooseHarness.available && BuiltTools.shellBuilt, "run scripts/fetch-engines and swift build first"))
struct RouterIntegrationTests {
    struct Stack {
        let root: URL
        let model: FakeServer
        let runtime: AgnetaRuntime
        let server: WebSocketServer
        let port: UInt16
        var supervisor: EngineSupervisor { runtime.supervisor }
        var traces: Traces { runtime.traces }

        static func start(port: UInt16, modelPort: Int) async throws -> Stack {
            let root = FileManager.default.temporaryDirectory.appending(
                path: "agneta-router-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory
            ).realFileURL
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let model = try await FakeServer.model(port: modelPort, log: root.appending(path: "model.log"))
            // Anything failing from here (a port in use) stops the fake model: a leaked one holds its port for later runs.
            do {
                return try await assemble(root: root, model: model, port: port, modelPort: modelPort)
            } catch {
                model.stop()
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        private static func assemble(root: URL, model: FakeServer, port: UInt16, modelPort: Int) async throws -> Stack {
            let goose = GooseAdapter(executable: GooseHarness.goose)
            let opencode = OpenCodeAdapter(executable: GooseHarness.opencode)
            let fake = ProviderSetup(
                kind: .openAI, model: "gpt-4o", apiKey: "fake", baseURL: "http://127.0.0.1:\(modelPort)/v1")
            // The whole runtime, as the app runs it: records, grants and cleanup included.
            let runtime = try await AgnetaRuntime(
                .init(
                    store: AgnetaStore(root: root.appending(path: "agneta", directoryHint: .isDirectory)),
                    shellTool: BuiltTools.shell, engineLoopbackPorts: [modelPort])
            ) { _ in
                Router.PairingAnswer(accounts: ["dev", "oc"], remember: true)
            }
            // "dev" runs on Goose, "oc" on OpenCode, both against the same fake OpenAI model: "oc" is filed as an Anthropic
            // key only so its kind's default can be OpenCode while "dev"'s stays Goose.
            await runtime.setCatalog(
                EngineCatalog(
                    ready: [goose, opencode], defaults: ProviderEngines(selected: [.anthropicKey: "opencode"])))
            await runtime.serve(
                account: "dev", label: "Dev", provider: fake, runner: .brokered, kind: .openAIKey, billing: "api-key",
                paused: false)
            await runtime.serve(
                account: "oc", label: "Dev on OpenCode", provider: fake, runner: .brokered, kind: .anthropicKey,
                billing: "api-key", paused: false)
            let server = try WebSocketServer(port: port)
            try await server.start()
            let router = runtime.router
            Task { for await connection in server.connections { Task { await router.serve(connection) } } }
            AppClient.register(scope: root.appending(path: "projects", directoryHint: .isDirectory), port: port)
            return Stack(root: root, model: model, runtime: runtime, server: server, port: port)
        }

        func workspace(_ name: String) throws -> URL {
            let url = root.appending(path: "projects/\(name).example/Workspace", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        /// How history records a task an app ended, once it does (within 10 s): the router answers the app first, and
        /// its events reach the records one at a time after.
        func outcome(of task: String) async throws -> TaskOutcome {
            for _ in 0..<200 {
                if let outcome = await runtime.history().first(where: { $0.id == task })?.outcome { return outcome }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NotRecorded(task: task)
        }

        /// Not an RPCError: a test's own failure never passes for a refusal from Agneta.
        struct NotRecorded: Error, CustomStringConvertible {
            let task: String
            var description: String { "\(task) wasn't recorded as ended within 10 s" }
        }

        func stop() async {
            server.stop()
            await runtime.shutdown()
            model.stop()
            GooseHarness.discard(root)
        }
    }

    @Test func twoAppsTwoSessionsEachAreRoutedAndIsolated() async throws {
        let stack = try await Stack.start(port: 47421, modelPort: 47431)
        do {
            let a = AppClient(port: stack.port), b = AppClient(port: stack.port)
            try await a.pairAndInitialize("App A")
            try await b.pairAndInitialize("App B")
            let aChat = try await a.newSession(cwd: try stack.workspace("A"), tools: "app-only")
            // Contained, as the app asks: the grant's own default would be developer access.
            let aWork = try await a.newSession(cwd: try stack.workspace("A"), tools: "workspace", sandbox: "contained")
            let bChat = try await b.newSession(cwd: try stack.workspace("B"), tools: "app-only")
            let bWork = try await b.newSession(cwd: try stack.workspace("B"), tools: "workspace", sandbox: "contained")
            // One shared engine for the chats, one dedicated engine per editing session.
            #expect(await stack.supervisor.processCount == 3)

            async let r1 = a.prompt(aChat, "hello")
            async let r2 = b.prompt(bChat, "hello")
            async let r3 = a.prompt(
                aWork,
                #"CALL shell {"command": "echo made > made.txt; cat made.txt; /usr/bin/curl -s -o /dev/null --max-time 3 https://api.github.com && echo NET || echo no-network"}"#
            )
            async let r4 = b.prompt(bWork, #"CALL shell {"command": "ls ../../A.example/Workspace 2>&1 | head -1"}"#)
            let results = try await [r1, r2, r3, r4]
            #expect(results.allSatisfy { $0["stopReason"]?.stringValue == "end_turn" })
            #expect(a.text(aChat) == "Hello from the fake model.")
            #expect(b.text(bChat) == "Hello from the fake model.")
            #expect(a.toolOutput(aWork).trimmingCharacters(in: .whitespacesAndNewlines) == "made\nno-network")
            // B's editing session can't see A's project.
            #expect(b.toolOutput(bWork).contains("Operation not permitted"))
            // B can't reach A's session.
            await #expect(throws: RPCError.self) { _ = try await b.prompt(aChat, "hijack") }

            a.close()
            try await Task.sleep(for: .milliseconds(500))
            #expect(await stack.supervisor.processCount == 2) // A's dedicated engine stopped; the shared one stays
            b.close()
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }

    /// Deleting a task deletes its conversation in the account's shared engine too: Goose deletes the session
    /// (`session/delete`), and no file of its database still holds the conversation's words. The engine keeps
    /// serving afterwards.
    @Test func deletingATaskDeletesItsConversationInASharedEngine() async throws {
        let stack = try await Stack.start(port: 47425, modelPort: 47435)
        do {
            let app = AppClient(port: stack.port)
            try await app.pairAndInitialize("Forgetful")
            let words = "quokka-zanzibar-\(UUID().uuidString.prefix(6))"
            let session = try await app.newSession(cwd: try stack.workspace("F"), tools: "app-only")
            _ = try await app.prompt(session, "Please remember \(words)")
            let meta = try #require(stack.traces.meta(task: session))
            let conversation = try #require(Router.sharedConversation(meta))
            let sessions = URL(filePath: try #require(meta["engine"]?["stateRoot"]?.stringValue)).appending(
                path: "data/sessions")
            func holding() -> [String] {
                let names =
                    (try? FileManager.default.contentsOfDirectory(atPath: sessions.path(percentEncoded: false))) ?? []
                return names.filter {
                    (try? Data(contentsOf: sessions.appending(path: $0)))?.range(of: Data(words.utf8)) != nil
                }
            }
            #expect(!holding().isEmpty)
            _ = try await app.request("session/close", ["sessionId": .string(session)])
            #expect(try await stack.outcome(of: session) == .finished)

            let left = Recorder()
            await stack.runtime.observe { event in
                if case .conversationsLeft(let count, let problem) = event { left.add("\(count) \(problem ?? "")") }
            }
            await stack.runtime.clearHistory()
            #expect(stack.traces.meta(task: session) == nil)
            // Once the deletion is through (it can't wait on the engine for ever), its storage holds nothing of it, and
            // nothing is left queued to ask for again: Agneta cleared the files itself, never waiting for Goose to.
            await stack.runtime.conversationsSettled()
            #expect(left.all == ["0 "])
            #expect(holding().isEmpty)
            #expect(await stack.runtime.pendingConversations.isEmpty)
            // Asked again, its storage says it's gone: nothing to delete, nothing to ask Goose, and done.
            let again = await stack.runtime.router.deleteConversations([conversation])
            #expect(again.deleted == 0 && again.problems.isEmpty && again.done == [conversation])

            let next = try await app.newSession(cwd: try stack.workspace("F"), tools: "app-only")
            let reply = try await app.prompt(next, "hello")
            #expect(reply["stopReason"]?.stringValue == "end_turn")
            app.close()
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }

    /// D1's acceptance check (docs/DIAGNOSTICS.md): one task with a shell call, a second turn and a
    /// close leaves a trace whose events, model calls and timings match what happened.
    @Test func traceRecordsAWholeTask() async throws {
        let stack = try await Stack.start(port: 47423, modelPort: 47433)
        do {
            let app = AppClient(port: stack.port)
            try await app.pairAndInitialize("Tracer")
            let session = try await app.newSession(cwd: try stack.workspace("T"), tools: "workspace")
            let first = try await app.prompt(session, #"CALL shell {"command": "echo hi"}"#)
            #expect(first["stopReason"]?.stringValue == "end_turn")
            _ = try await app.prompt(session, "hello")
            _ = try await app.request("session/close", ["sessionId": .string(session)])
            try await Task.sleep(for: .milliseconds(300))

            let lines = try stack.traces.text(of: session).split(separator: "\n")
            let records = try lines.map { try JSONCoding.decode(Data($0.utf8)) }
            // Gapless, versioned, one task, starting with what shaped the run.
            #expect(records.map { $0["seq"]?.intValue } == (1...Int64(records.count)).map { $0 })
            #expect(records.allSatisfy { $0["v"]?.intValue == 1 && $0["task"]?.stringValue == session })
            #expect(records.first?["type"]?.stringValue == "meta")
            #expect(records.first?["account"]?["billing"]?.stringValue == "api-key")
            #expect(records.last?["type"]?.stringValue == "end")
            #expect(lines.first?.hasPrefix(#"{"v":1,"seq":1,"t":""#) == true)

            func events(_ kind: String) -> [JSONValue] {
                records.filter { $0["type"]?.stringValue == "event" && $0["kind"]?.stringValue == kind }
            }
            let call = try #require(events("tool-call").first)
            #expect(call["call"]?.stringValue == "c1")
            #expect(call["input"]?["command"]?.stringValue == "echo hi")
            #expect(call["turn"]?.intValue == 1)
            #expect(call["tool"]?.stringValue == "shell" && call["extension"]?.stringValue == "developer")
            let result = try #require(events("tool-result").first)
            #expect(result["call"]?.stringValue == "c1" && result["isError"]?.boolValue == false)
            // A whole number of milliseconds reads back as an integer.
            let ms: Double? =
                switch result["ms"] {
                case .double(let v)?: v;
                case .int(let v)?: Double(v);
                default: nil
                }
            #expect((ms ?? 0) > 0)

            // Per model call from Goose's ledger: the tool turn makes two calls, the plain one one.
            let turns = events("turn")
            #expect(turns.map { $0["n"]?.intValue } == [1, 2])
            #expect(turns.map { $0["modelCalls"]?.intValue } == [2, 1])
            #expect(turns.allSatisfy { $0["msToFirstToken"] != .null && $0["stopReason"]?.stringValue == "end_turn" })
            #expect(events("model-call").count == 3)
            #expect(
                events("model-call").allSatisfy {
                    $0["input"]?.intValue == 42 && $0["basis"]?.stringValue == "engine-ledger"
                })

            // Agneta's own decisions and the broker's exact run.
            let shell = try #require(records.first { $0["type"]?.stringValue == "shell" })
            #expect(
                shell["command"]?.stringValue == "echo hi" && shell["exit"]?.intValue == 0
                    && shell["stdoutBytes"]?.intValue == 3)
            #expect(
                records.contains {
                    $0["type"]?.stringValue == "permission" && $0["decision"]?.stringValue == "allowed-by-policy"
                })
            #expect(
                records.contains {
                    $0["type"]?.stringValue == "lifecycle" && $0["event"]?.stringValue == "stop"
                        && $0["reason"]?.stringValue == "closed"
                })

            // Both raw legs, and the context as the model saw it.
            let legs = Set(records.compactMap { $0["type"]?.stringValue == "acp" ? $0["leg"]?.stringValue : nil })
            #expect(legs == ["app→agneta", "agneta→app", "agneta→engine", "engine→agneta"])
            #expect(
                records.contains {
                    $0["type"]?.stringValue == "engine.message" && "\($0["content"] ?? .null)".contains("turn-context")
                })
            // AGNETA_TEST_KEEP=<folder> keeps the trace, e.g. to try agneta-diag on it.
            if let keep = ProcessInfo.processInfo.environment["AGNETA_TEST_KEEP"] {
                let target = URL(filePath: keep, directoryHint: .isDirectory).appending(
                    path: "Traces", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: target.appending(path: "\(session).jsonl"))
                try FileManager.default.copyItem(
                    at: stack.traces.file(for: session), to: target.appending(path: "\(session).jsonl"))
            }
            app.close()
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }

    /// Two sessions starting at once on one account share one engine, not two.
    @Test func concurrentStartsShareOneEngine() async throws {
        let stack = try await Stack.start(port: 47424, modelPort: 47434)
        do {
            let a = AppClient(port: stack.port), b = AppClient(port: stack.port)
            try await a.pairAndInitialize("A")
            try await b.pairAndInitialize("B")
            async let one = a.newSession(cwd: try stack.workspace("A"), tools: "app-only")
            async let two = b.newSession(cwd: try stack.workspace("B"), tools: "app-only")
            let sessions = try await [one, two]
            #expect(Set(sessions).count == 2)
            #expect(await stack.supervisor.processCount == 1)
            _ = try await a.prompt(sessions[0], "hello")
            _ = try await b.prompt(sessions[1], "hello")
            #expect(
                a.text(sessions[0]) == "Hello from the fake model."
                    && b.text(sessions[1]) == "Hello from the fake model.")
            a.close()
            b.close()
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }

    /// Quitting with a task open: the app's connection closes, and it is never told an engine stopped (which would
    /// read as a crash). Before the fix, stopping the engines first sent `stoppedBy: "engine"` to the still-connected
    /// app; the client library's integration test caught it as a race on CI.
    @Test func quittingHangsUpAppsBeforeEnginesStop() async throws {
        let stack = try await Stack.start(port: 47682, modelPort: 47683)
        do {
            let app = AppClient(port: stack.port)
            try await app.pairAndInitialize("App")
            _ = try await app.newSession(cwd: try stack.workspace("Quit"), tools: "workspace")
            #expect(await stack.supervisor.processCount == 1)
            await stack.runtime.stopAll()
            for _ in 0..<60 where !app.isClosed { try await Task.sleep(for: .milliseconds(50)) }
            #expect(app.isClosed)
            try await Task.sleep(for: .milliseconds(300))
            #expect(app.notifications("agneta/sessionStopped").isEmpty)
            #expect(await stack.supervisor.processCount == 0)
            #expect(await stack.runtime.history().first?.outcome == .stopped)
            app.close()
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }

    /// A real engine killed from outside: its session ends, the app hears why, and the supervisor retires the
    /// process instead of keeping a dead entry.
    @Test func aKilledEngineIsRetiredAndItsSessionEnds() async throws {
        let stack = try await Stack.start(port: 47610, modelPort: 47611)
        do {
            let app = AppClient(port: stack.port)
            try await app.pairAndInitialize("App")
            let session = try await app.newSession(cwd: try stack.workspace("Killed"), tools: "workspace")
            #expect(await stack.supervisor.processCount == 1)
            let meta = try #require(stack.traces.text(of: session).split(separator: "\n").first)
            let pid = try #require(try JSONCoding.decode(Data(meta.utf8))["engine"]?["pid"]?.intValue)
            kill(pid_t(pid), SIGKILL)
            for _ in 0..<60 where app.notifications("agneta/sessionStopped").isEmpty {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(app.notifications("agneta/sessionStopped").first?["stoppedBy"]?.stringValue == "engine")
            for _ in 0..<40 where await stack.supervisor.processCount > 0 {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(await stack.supervisor.processCount == 0)
            app.close()
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }

    @Test func steeringReachesARunningTurn() async throws {
        let stack = try await Stack.start(port: 47422, modelPort: 47432)
        do {
            let app = AppClient(port: stack.port)
            try await app.pairAndInitialize("App")
            let session = try await app.newSession(cwd: try stack.workspace("S"), tools: "app-only")
            let turn = Task { try await app.prompt(session, "answer slowly") }
            var runID: String?
            for _ in 0..<50 where runID == nil {
                try await Task.sleep(for: .milliseconds(50))
                runID = app.activeRunID(session)
            }
            let steered = try await app.request(
                "agneta/steer",
                [
                    "sessionId": .string(session), "prompt": [["type": "text", "text": "also mention fjords"]]
                ])
            #expect(steered["runId"]?.stringValue == runID)
            _ = try await turn.value
            app.close()
        } catch {
            await stack.stop()
            throw error
        }
        await stack.stop()
    }
}
