// The router's contract with apps, against an in-memory fake engine that
// follows a script: permission decisions and how they're traced, per-turn usage
// in prompt results, live and read trace access with per-app scoping,
// Agneta's own steering and instructions methods, and disconnect reasons. Fast
// and exact; the real-engine paths are in RouterIntegrationTests and
// AppScenarioTests.
import Foundation
import Testing
@testable import AgnetaKit

/// Codes the approval closure saw (nil for a verified app).
final class PairingCodes: @unchecked Sendable {
    static let shared = PairingCodes()
    private let lock = NSLock()
    private var codes: [String?] = []
    func add(_ code: String?) { lock.withLock { codes.append(code) } }
    var all: [String?] { lock.withLock { codes } }
}

/// Holds writes while closed, as a full pipe to an engine that stopped reading would.
actor Gate {
    private var closed = false
    func close() { closed = true }
    func pass() async { while closed { try? await Task.sleep(for: .seconds(3600)) } }
}

/// Two RPC peers wired back to back in memory. With a gate, the first one's writes wait at it.
func peerPair(gate: Gate? = nil) -> (RPCPeer, RPCPeer) {
    let (a, b, _) = endablePeerPair(gate: gate)
    return (a, b)
}

/// The same, with a way to end the first peer's input, as an engine process exiting would.
func endablePeerPair(gate: Gate? = nil) -> (RPCPeer, RPCPeer, @Sendable () -> Void) {
    let (toA, intoA) = AsyncThrowingStream<Data, Error>.makeStream()
    let (toB, intoB) = AsyncThrowingStream<Data, Error>.makeStream()
    let a = RPCPeer { data in
        await gate?.pass()
        intoB.yield(data)
    }
    let b = RPCPeer { data in intoA.yield(data) }
    Task { await a.run(toA) }
    Task { await b.run(toB) }
    return (a, b, { intoA.finish() })
}

/// An engine that follows its prompts: "permission <kind>" asks Agneta about a tool of that
/// kind, "slow" runs until steered (or 3 s), anything else replies with text.
/// An engine with only plain ACP: no steering, fork or instructions between turns.
struct PlainAdapter: EngineAdapter {
    let base = GooseAdapter(executable: URL(filePath: "/usr/bin/false"))
    var stateFormat = "plain/1"
    var id: String { "plain" }
    var displayName: String { "Plain" }
    var capabilities: EngineCapabilities { EngineCapabilities(steer: false, fork: false, instructionsBetweenTurns: false, processPerSession: true) }
    func launch(_ context: EngineLaunchContext) throws -> EngineLaunch { try base.launch(context) }
    func newSession(cwd: URL, servers: [JSONValue], policy: SessionPolicy, title: JSONValue?, instructions: String?) -> JSONValue { ["cwd": .string(cwd.path(percentEncoded: false)), "mcpServers": .array(servers)] }
    func loadSession(_ engineSession: String, cwd: URL, servers: [JSONValue], policy: SessionPolicy) -> JSONValue { ["sessionId": .string(engineSession)] }
    func setInstructions(_ engineSession: String, text: String, appendKey: String?) -> EngineRequest? { nil }
    func steer(_ engineSession: String, run: String?, prompt: JSONValue) -> EngineRequest? { nil }
    func steerResult(_ result: JSONValue) -> (accepted: Bool, run: String?) { (false, nil) }
    func activeRun(in update: JSONValue) -> String?? { base.activeRun(in: update) }
    func toolIdentity(in update: JSONValue) -> (tool: String?, server: String?, message: String?) { (nil, nil, nil) }
    func exportSession(_ engineSession: String) -> EngineRequest? { nil }
    func importSession(_ exported: JSONValue) -> EngineRequest? { nil }
    func importedSession(_ result: JSONValue) -> String? { nil }
    func ledger(stateRoot: URL, engineSession: String) -> (any UsageLedger)? { nil }
}

actor FakeEngines: EngineSource {
    /// The engine each account's leases report (default: Goose's dialect).
    var adapters: [String: any EngineAdapter] = [:]
    func use(_ adapter: any EngineAdapter, for account: String) { adapters[account] = adapter }

    private(set) var permissionAnswers: [String: JSONValue] = [:]
    private(set) var steers: [JSONValue] = []
    private(set) var instructions: [JSONValue] = []
    /// Every notification the engines received, by method.
    private(set) var notifications: [String] = []
    /// How engines answer `session/close`: normally, with an error, or never.
    enum Close { case answer, fail, hang }
    var close = Close.answer
    func closing(_ mode: Close) { close = mode }
    private var gates: [Gate] = []
    private var ends: [@Sendable () -> Void] = []
    /// Every engine exits: Agneta's connections to them end.
    func crash() { ends.forEach { $0() } }
    /// How long `session/load` takes.
    var loadDelay: Duration = .zero
    /// How long an engine takes to start.
    var openDelay: Duration = .zero
    func starting(takes delay: Duration) { openDelay = delay }
    /// Engines started, and leases let go of: equal once nothing holds an engine.
    private(set) var opened = 0
    private(set) var released = 0
    func loading(takes delay: Duration) { loadDelay = delay }
    /// Every engine stops reading: Agneta's writes to it wait forever.
    func wedge() async { for gate in gates { await gate.close() } }
    private var steered: CheckedContinuation<Void, Never>?
    private var cancelled = false

    func open(account: String, policy: SessionPolicy, mcpPorts: [Int], key: String?, session: EngineSessionSpec?) async throws -> EngineLease {
        opened += 1
        if openDelay > .zero { try? await Task.sleep(for: openDelay) }
        let gate = Gate()
        gates.append(gate)
        let (agneta, engine, end) = endablePeerPair(gate: gate)
        ends.append(end)
        let n = opened
        await engine.handle(requests: { [weak self] method, params in
            guard let self else { return .failure(RPCError(code: RPCError.internalError, message: "gone")) }
            return await self.answer(engine, n: n, method: method, params: params)
        })
        await engine.handle(notifications: { [weak self] method, _ in
            await self?.noted(method)
            if method == "session/cancel" { await self?.cancel() }
        })
        // Speaks Goose's dialect, so Goose's adapter describes it.
        // App-only sessions get the shared key, as the real supervisor gives them.
        return EngineLease(key: key ?? (policy.tools == .appOnly ? "\(account)/shared" : "\(account)/fake-\(n)"), peer: agneta, pid: getpid(), dedicated: true, engine: adapters[account] ?? GooseAdapter(executable: URL(filePath: "/usr/bin/false")), startMs: 12.5,
                           engineInfo: ["name": "fake", "version": "1"])
    }

    func release(_ lease: EngineLease) async { released += 1 }

    private func answer(_ engine: RPCPeer, n: Int, method: String, params: JSONValue?) async -> Result<JSONValue, RPCError> {
        let session = params?["sessionId"] ?? .string("e\(n)")
        func update(_ update: JSONValue) async { try? await engine.notify("session/update", ["sessionId": session, "update": update]) }
        switch method {
        case "session/new":
            // As real engines may: an update for the new session before the answer that names it.
            try? await engine.notify("session/update", ["sessionId": .string("e\(n)"), "update": ["sessionUpdate": "available_commands_update", "availableCommands": [["name": "review"]]]])
            return .success(["sessionId": .string("e\(n)"), "models": ["currentModelId": "fake-model"], "configOptions": []])
        case "_goose/unstable/session/system-prompt/set":
            instructions.append(params ?? .null)
            return .success([:])
        case "_goose/unstable/session/steer":
            steers.append(params ?? .null)
            steered?.resume()
            steered = nil
            return .success(["runId": params?["expectedRunId"] ?? .null])
        case "session/prompt":
            let text = params?["prompt"]?.arrayValue?.first?["text"]?.stringValue ?? ""
            cancelled = false // a cancel belongs to the turn it arrived in
            if text.hasPrefix("permission ") {
                let kind = String(text.dropFirst("permission ".count))
                await update(["sessionUpdate": "tool_call", "toolCallId": .string("call-\(kind)"), "title": .string("\(kind) tool"), "kind": .string(kind), "status": "pending"])
                let answer = try? await engine.request("session/request_permission", [
                    "sessionId": session, "toolCall": ["toolCallId": .string("call-\(kind)"), "kind": .string(kind), "title": .string("\(kind) tool")],
                    "options": [["kind": "allow_once", "optionId": "allow", "name": "Allow"], ["kind": "reject_once", "optionId": "reject", "name": "Reject"]],
                ])
                permissionAnswers[kind] = answer ?? .null
                await update(["sessionUpdate": "tool_call_update", "toolCallId": .string("call-\(kind)"), "status": "completed"])
            } else if text.hasPrefix("ask ") {
                // "ask <label> <json>": a permission request with this tool call (and request _meta, under "_meta"),
                // after a tool_call update for the same call when the JSON has "announce".
                let rest = text.dropFirst("ask ".count)
                let label = String(rest.prefix { $0 != " " })
                let spec = (try? JSONCoding.decode(Data(rest.drop { $0 != " " }.utf8))) ?? [:]
                if let announced = spec["announce"] { await update(announced) }
                var request: JSONValue = ["sessionId": session, "toolCall": spec["toolCall"] ?? [:],
                                          "options": [["kind": "allow_once", "optionId": "allow", "name": "Allow"], ["kind": "reject_once", "optionId": "reject", "name": "Reject"]]]
                if let meta = spec["_meta"] { request = request.setting("_meta", to: meta) }
                permissionAnswers[label] = (try? await engine.request("session/request_permission", request)) ?? .null
            } else if text == "stubborn" {
                // Ignores cancel: finishes on its own after a while.
                try? await Task.sleep(for: .milliseconds(1500))
            } else if text == "auth" {
                return .failure(RPCError(code: -32000, message: "Authentication required"))
            } else if text == "ratelimit" {
                return .failure(RPCError(code: RPCError.internalError, message: RateLimitTests.goose, data: ["reason": "turn_failed"]))
            } else if text == "slow" {
                await update(["sessionUpdate": "session_info_update", "_meta": ["goose": ["activeRunId": "run-7"]]])
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.waitForSteer() }
                    group.addTask { try? await Task.sleep(for: .seconds(3)) }
                    await group.next()
                    group.cancelAll()
                }
            } else {
                await update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "hi"]])
            }
            return .success(["stopReason": cancelled ? "cancelled" : "end_turn", "usage": ["inputTokens": 5, "outputTokens": 1]])
        case "session/set_mode", "session/set_config_option":
            return .success([:])
        case "session/load":
            try? await Task.sleep(for: loadDelay)
            return .success(["models": ["currentModelId": "fake-model"], "configOptions": []])
        case "session/close":
            switch close {
            case .answer: return .success([:])
            case .fail: return .failure(RPCError(code: RPCError.internalError, message: "close failed"))
            case .hang:
                try? await Task.sleep(for: .seconds(3600))
                return .success([:])
            }
        default:
            return .failure(RPCError(code: RPCError.methodNotFound, message: method))
        }
    }

    private func noted(_ method: String) { notifications.append(method) }

    private func cancel() {
        cancelled = true
        steered?.resume()
        steered = nil
    }

    private func waitForSteer() async {
        await withCheckedContinuation { steered = $0 }
    }
}

/// Ports: 474xx belong to the integration and scenario suites (some computed, e.g. 47452 + 5 for OpenCode);
/// contract tests added later take 476xx.
@Suite(.serialized) struct RouterContractTests {
    struct Stack {
        let root: URL
        let engines: FakeEngines
        let traces: Traces
        let router: Router
        let server: WebSocketServer
        let port: UInt16

        /// `approve` replaces the default (allow both accounts at once).
        /// `appWorkspaces`: give each paired app a workspace of its own, as the app does. `commit` saves grants.
        static func start(port: UInt16, concurrency: Router.Concurrency = .init(), appWorkspaces: Bool = false, commit: Router.Commit? = nil,
                          approve: Router.Approve? = nil) async throws -> Stack {
            let root = FileManager.default.temporaryDirectory.appending(path: "agneta-contract-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory).realFileURL
            try FileManager.default.createDirectory(at: root.appending(path: "work"), withIntermediateDirectories: true)
            let traces = Traces(folder: root.appending(path: "Traces", directoryHint: .isDirectory))
            let engines = FakeEngines()
            let router = Router(context: PolicyContext(userHome: FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [root.appending(path: "agneta")],
                                                       appWorkspaces: appWorkspaces ? root.appending(path: "apps", directoryHint: .isDirectory) : nil),
                                engines: engines, traces: traces, concurrency: concurrency, commit: commit) { request in
                PairingCodes.shared.add(request.code)
                return await approve?(request) ?? Router.PairingAnswer(accounts: ["brokered", "native"], remember: true)
            }
            await router.add(account: "brokered", label: "API", kind: "openai-key", billing: "api-key")
            await router.add(account: "native", label: "Claude", runner: .native, kind: "claude", billing: "subscription")
            let server = try WebSocketServer(port: port)
            try await server.start()
            Task { for await connection in server.connections { Task { await router.serve(connection) } } }
            AppClient.register(scope: root.appending(path: "work", directoryHint: .isDirectory), port: port)
            return Stack(root: root, engines: engines, traces: traces, router: router, server: server, port: port)
        }

        init(root: URL, engines: FakeEngines, traces: Traces, router: Router, server: WebSocketServer, port: UInt16) {
            self.root = root
            self.engines = engines
            self.traces = traces
            self.router = router
            self.server = server
            self.port = port
        }

        func session(_ app: AppClient, account: String, approval: String = "never-ask", tools: String = "app-only", network: String = "none",
                     meta: [String: JSONValue] = [:]) async throws -> String {
            var fullMeta: [String: JSONValue] = [SessionPolicy.key: ["tools": .string(tools), "network": .string(network), "approval": .string(approval)],
                                                 "agneta": ["account": .string(account)]]
            fullMeta.merge(meta) { _, new in new }
            let result = try await app.request("session/new", ["cwd": .string(root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [], "_meta": .object(fullMeta)])
            return try #require(result["sessionId"]?.stringValue)
        }

        /// The task's meta record, once the trace writer (which writes off the caller's thread) has put it on disk.
        func meta(_ task: String) async throws -> JSONValue {
            for _ in 0..<250 {
                if let meta = traces.meta(task: task) { return meta }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw RPCError(code: RPCError.internalError, message: "no meta record for \(task) after 5 s")
        }

        func records(_ task: String) throws -> [JSONValue] {
            try traces.text(of: task).split(separator: "\n").map { try JSONCoding.decode(Data($0.utf8)) }
        }

        func stop() {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func permissionDecisionsFollowThePolicyAndAreTraced() async throws {
        let stack = try await Stack.start(port: 47441)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        app.answerPermissions(with: "allow")
        try await app.pairAndInitialize("Contract")

        // Claude Code runs its own tools: with no network, its shell is refused before it runs.
        let native = try await stack.session(app, account: "native", tools: "workspace")
        _ = try await app.prompt(native, "permission execute")
        // The policy is the permission for everything else.
        _ = try await app.prompt(native, "permission edit")
        // An app that wants to decide is asked.
        let asking = try await stack.session(app, account: "brokered", approval: "ask-app")
        _ = try await app.prompt(asking, "permission read")

        #expect(await stack.engines.permissionAnswers["execute"]?["outcome"]?["optionId"]?.stringValue == "reject")
        #expect(await stack.engines.permissionAnswers["edit"]?["outcome"]?["optionId"]?.stringValue == "allow")
        #expect(await stack.engines.permissionAnswers["read"]?["outcome"]?["optionId"]?.stringValue == "allow")
        #expect(app.permissionRequests == 1)

        let decisions = try stack.records(native).filter { $0["type"]?.stringValue == "permission" }.map { $0["decision"]?.stringValue }
        #expect(decisions == ["refused-by-policy", "allowed-by-policy"])
        let asked = try #require(try stack.records(asking).first { $0["type"]?.stringValue == "permission" })
        #expect(asked["decision"]?.stringValue == "asked-app" && asked["toolKind"]?.stringValue == "read")
    }

    @Test func promptResultsCarryTheTurnsUsage() async throws {
        let stack = try await Stack.start(port: 47442)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Contract")
        let initialize = try await app.request("initialize", ["protocolVersion": 1, "_meta": ["agneta": ["token": .string(app.token ?? "")]]])
        let extensions = Set(initialize["_meta"]?["agneta"]?["extensions"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        #expect(extensions.isSuperset(of: ["agneta/usage@1", "agneta/trace@1", "agneta/steer@1", "agneta/instructions@1"]))

        let session = try await stack.session(app, account: "native")
        let result = try await app.prompt(session, "hello")
        let usage = try #require(result["_meta"]?["agneta/usage@1"])
        #expect(usage["billing"]?.stringValue == "subscription" && usage["costKind"]?.stringValue == "plan-equivalent")
        #expect(usage["modelCalls"]?.intValue == 0) // the fake engine has no ledger: zero calls seen, not a guess
        #expect(usage["cost"] == .null && usage["basis"]?.stringValue == "engine-ledger")
        #expect(usage["msToFirstToken"] != .null)
        #expect(result["usage"]?["inputTokens"]?.intValue == 5) // the engine's own turn usage is untouched
    }

    @Test func appsReadTheirOwnTracesLiveAndAfterwards() async throws {
        let stack = try await Stack.start(port: 47443)
        defer { stack.stop() }
        let app = AppClient(port: stack.port), other = AppClient(port: stack.port)
        defer { app.close(); other.close() }
        try await app.pairAndInitialize("Owner")
        try await other.pairAndInitialize("Other")
        let session = try await stack.session(app, account: "brokered", meta: ["agneta/trace@1": ["live": true]])
        _ = try await app.prompt(session, "hello")
        _ = try await app.prompt(session, "permission read")
        _ = try await app.request("session/close", ["sessionId": .string(session)])
        try await Task.sleep(for: .milliseconds(400))

        let live = app.traceRecords(session)
        #expect(live.first?["type"]?.stringValue == "meta" && live.last?["type"]?.stringValue == "end")
        #expect(!live.contains { $0["type"]?.stringValue == "acp" }) // raw frames only when asked
        let seqs = live.compactMap { $0["seq"]?.intValue }
        #expect(seqs == seqs.sorted() && Set(seqs).count == seqs.count)

        // Read afterwards, in pages, gives the same records.
        var read: [JSONValue] = []
        var after: Int64 = 0
        var pages = 0
        while true {
            let page = try await app.request("agneta/trace/read", ["sessionId": .string(session), "after": .int(after), "limit": 5])
            read += page["records"]?.arrayValue ?? []
            pages += 1
            if page["complete"]?.boolValue == true { break }
            after = try #require(page["next"]?.intValue)
        }
        #expect(pages > 1)
        #expect(read == live)
        // The trace's own delivery isn't recorded in it.
        #expect(try !stack.records(session).contains { $0["msg"]?["method"]?.stringValue?.hasPrefix("agneta/trace") == true })
        // Raw frames on request.
        let raw = try await app.request("agneta/trace/read", ["sessionId": .string(session), "types": ["acp"], "limit": 1000])
        #expect((raw["records"]?.arrayValue ?? []).count > 0)
        // Another app can't read it, nor can anyone escape the folder.
        await #expect(throws: RPCError.self) { _ = try await other.request("agneta/trace/read", ["sessionId": .string(session)]) }
        await #expect(throws: RPCError.self) { _ = try await app.request("agneta/trace/read", ["sessionId": "../agneta"]) }
    }

    @Test func steeringAndInstructionsUseAgnetasOwnMethods() async throws {
        let stack = try await Stack.start(port: 47444)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Contract")
        let session = try await stack.session(app, account: "brokered")

        // Nothing to steer between turns.
        await #expect(throws: RPCError.self) { _ = try await app.request("agneta/steer", ["sessionId": .string(session), "prompt": [["type": "text", "text": "x"]]]) }
        let turn = Task { try await app.prompt(session, "slow") }
        try await Task.sleep(for: .milliseconds(200))
        let steered = try await app.request("agneta/steer", ["sessionId": .string(session), "prompt": [["type": "text", "text": "also fjords"]]])
        #expect(steered["delivery"]?.stringValue == "accepted" && steered["runId"]?.stringValue == "run-7")
        _ = try await turn.value
        let steer = try #require(await stack.engines.steers.first)
        #expect(steer["expectedRunId"]?.stringValue == "run-7")

        _ = try await app.request("agneta/instructions/set", ["sessionId": .string(session), "text": "Be brief.", "mode": "append"])
        #expect(await stack.engines.instructions.last?["text"]?.stringValue == "Be brief.")
        #expect(await stack.engines.instructions.last?["mode"]?.stringValue == "append")
        #expect(await stack.engines.instructions.last?["key"]?.stringValue == "app")
        _ = try await app.request("agneta/instructions/set", ["sessionId": .string(session), "text": "All new."])
        #expect(await stack.engines.instructions.last?["mode"]?.stringValue == "set")

        let records = try stack.records(session)
        let steers = records.filter { $0["event"]?.stringValue == "steer" }.map { $0["delivery"]?.stringValue }
        #expect(steers == ["rejected", "accepted"])
        #expect(records.contains { $0["type"]?.stringValue == "config" && $0["method"]?.stringValue == "agneta/instructions/set" })
    }

    @Test func limitsStopATurnAndSayWhich() async throws {
        let limits = SessionPolicy.Limits(maxTurns: 3, maxSeconds: 60, maxCostUSD: 0.5)
        #expect(limits.breached(seconds: 10, modelCalls: 3, cost: 0.5) == nil)
        #expect(limits.breached(seconds: 61, modelCalls: 0, cost: 0)?.limit == "maxSeconds")
        #expect(limits.breached(seconds: 1, modelCalls: 4, cost: 0)?.limit == "maxTurns")
        #expect(limits.breached(seconds: 1, modelCalls: 1, cost: 0.51)?.limit == "maxCostUSD")

        let stack = try await Stack.start(port: 47446)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Limited")
        let created = try await app.request("session/new", [
            "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
            "_meta": [SessionPolicy.key: ["tools": "app-only", "approval": "never-ask", "limits": ["maxSeconds": 1]], "agneta": ["account": "brokered"]],
        ])
        let session = try #require(created["sessionId"]?.stringValue)
        let started = ContinuousClock.now
        let result = try await app.prompt(session, "slow")
        #expect(ContinuousClock.now - started < .milliseconds(2_500))
        #expect(result["stopReason"]?.stringValue == "cancelled")
        #expect(result["_meta"]?["agneta/limit@1"]?["limit"]?.stringValue == "maxSeconds")
        #expect(try stack.records(session).contains { $0["event"]?.stringValue == "limit" && $0["limit"]?.stringValue == "maxSeconds" })
        // The next turn starts clean.
        let next = try await app.prompt(session, "hello")
        #expect(next["_meta"]?["agneta/limit@1"] == nil)
    }

    /// turns beyond the limits wait in order, the app is told, cancel takes a waiting
    /// turn out, and a full queue is a clear error.
    @Test func turnsBeyondTheLimitsWaitInOrder() async throws {
        let stack = try await Stack.start(port: 47447, concurrency: .init(global: 2, perAccount: 1, queue: 1))
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Busy")
        let a1 = try await stack.session(app, account: "brokered")
        let a2 = try await stack.session(app, account: "brokered")
        let a3 = try await stack.session(app, account: "brokered")
        let b1 = try await stack.session(app, account: "native")

        let first = Task { try await app.prompt(a1, "slow") }        // runs: brokered 1/1
        try await Task.sleep(for: .milliseconds(150))
        let second = Task { try await app.prompt(a2, "hello") }      // waits: brokered is full
        try await Task.sleep(for: .milliseconds(150))
        #expect(app.notifications("agneta/queued").map { $0["sessionId"]?.stringValue } == [a2])
        // Another account still has room.
        let other = try await app.prompt(b1, "hello")
        #expect(other["stopReason"]?.stringValue == "end_turn")
        // The queue holds one: a third waiting turn is refused.
        await #expect(throws: RPCError.self) { _ = try await app.prompt(a3, "hello") }
        // Cancel takes the waiting turn out at once; the running one is untouched.
        app.notify("session/cancel", ["sessionId": .string(a2)])
        #expect(try await second.value["stopReason"]?.stringValue == "cancelled")
        // When the running turn ends, the next waiting one runs.
        let third = Task { try await app.prompt(a3, "hello") }
        try await Task.sleep(for: .milliseconds(150))
        _ = try await app.request("agneta/steer", ["sessionId": .string(a1), "prompt": [["type": "text", "text": "finish"]]])
        #expect(try await first.value["stopReason"]?.stringValue == "end_turn")
        #expect(try await third.value["stopReason"]?.stringValue == "end_turn")

        let queued = try stack.records(a2).compactMap { $0["event"]?.stringValue }.filter { $0.hasPrefix("queue") || $0 == "dequeued" }
        #expect(queued == ["queued", "queue-cancelled"])
        #expect(try stack.records(a3).contains { $0["event"]?.stringValue == "dequeued" })
    }

    @Test func providerLimitsReachTheAppWithTheirResetTime() async throws {
        let stack = try await Stack.start(port: 47448)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Limited")
        let session = try await stack.session(app, account: "brokered")
        do {
            _ = try await app.prompt(session, "ratelimit")
            Issue.record("expected the turn to fail")
        } catch let error as RPCError {
            let limited = try #require(error.data?["agneta"]?["rateLimited"])
            #expect(limited["account"]?.stringValue == "brokered")
            #expect(limited["resetsAt"]?.stringValue != nil)
            #expect(error.data?["reason"]?.stringValue == "turn_failed") // the engine's own data is kept
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.notifications("agneta/rateLimited").first?["sessionId"]?.stringValue == session)
        #expect(try stack.records(session).contains { $0["kind"]?.stringValue == "rate-limited" && $0["resetsAt"] != .null })
    }

    /// Pausing starts nothing new on the account: no session opens by any path, no turn begins, and a turn waiting
    /// in the queue is refused. The turn already running finishes, and idle sessions stay open for later.
    @Test func aPausedAccountStartsNothingNew() async throws {
        let stack = try await Stack.start(port: 47449, concurrency: .init(global: 8, perAccount: 1, queue: 32))
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Paused")
        let running = try await stack.session(app, account: "brokered")
        let idle = try await stack.session(app, account: "brokered")
        let closed = try await stack.session(app, account: "brokered")
        _ = try await app.request("session/close", ["sessionId": .string(closed)])
        let turn = Task { try await app.prompt(running, "stubborn") }
        try await Task.sleep(for: .milliseconds(200))
        let queued = Task { try await app.prompt(idle, "hello") }
        try await Task.sleep(for: .milliseconds(200))
        await stack.router.setPaused("brokered", true)

        let initialize = try await app.request("initialize", ["protocolVersion": 1, "_meta": ["agneta": ["token": .string(app.token ?? "")]]])
        let listed = initialize["_meta"]?["agneta"]?["accounts"]?.arrayValue?.first { $0["id"]?.stringValue == "brokered" }
        #expect(listed?["paused"]?.boolValue == true)
        func expectPaused(_ what: String, _ work: () async throws -> Void) async {
            do {
                try await work()
                Issue.record("\(what) went ahead on a paused account")
            } catch let error as RPCError {
                #expect(error.code == -32013 && error.data?["agneta"]?["paused"]?.stringValue == "brokered", "\(what): \(error.message)")
            } catch {
                Issue.record("\(what): \(error)")
            }
        }
        let cwd = JSONValue.string(stack.root.appending(path: "work").path(percentEncoded: false))
        await expectPaused("the queued turn") { _ = try await queued.value }
        await expectPaused("a new turn") { _ = try await app.prompt(idle, "hello") }
        await expectPaused("a new session") { _ = try await stack.session(app, account: "brokered") }
        await expectPaused("a load") { _ = try await app.request("session/load", ["sessionId": .string(closed), "cwd": cwd, "mcpServers": []]) }
        await expectPaused("a fork") { _ = try await app.request("agneta/fork", ["sessionId": .string(closed), "mcpServers": []]) }
        #expect(try await turn.value["stopReason"]?.stringValue == "end_turn")
        #expect(try stack.records(idle).contains { $0["event"]?.stringValue == "queue-paused" })

        await stack.router.setPaused("brokered", false)
        #expect(try await app.prompt(idle, "hello")["stopReason"]?.stringValue == "end_turn")
        _ = try await stack.session(app, account: "brokered")
    }

    /// A saved task continues only on the engine that saved it, in a format that engine still reads: once the
    /// account has moved to another engine, or the engine to another state format, load and fork are refused,
    /// naming the engine that saved it. Back on that engine, the task resumes.
    @Test func aTaskContinuesOnlyOnTheEngineThatSavedIt() async throws {
        let stack = try await Stack.start(port: 47615)
        defer { stack.stop() }
        await stack.engines.use(PlainAdapter(), for: "brokered")
        await stack.router.add(account: "brokered", label: "API", kind: "openai-key", billing: "api-key", engine: PlainAdapter())
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Mover")
        let session = try await stack.session(app, account: "brokered")
        _ = try await app.request("session/close", ["sessionId": .string(session)])
        let params: JSONValue = ["sessionId": .string(session), "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": []]
        let moves: [any EngineAdapter] = [GooseAdapter(executable: URL(filePath: "/usr/bin/false")), PlainAdapter(stateFormat: "plain/2")]
        for engine in moves {
            await stack.router.add(account: "brokered", label: "API", kind: "openai-key", billing: "api-key", engine: engine)
            for method in ["session/load", "agneta/fork"] {
                do {
                    _ = try await app.request(method, params)
                    Issue.record("\(method) went ahead on \(engine.stateFormat)")
                } catch let error as RPCError {
                    #expect(error.code == RPCError.invalidParams && error.data?["agneta"]?["engineChanged"]?["saved"]?.stringValue == "plain",
                            "\(method) on \(engine.stateFormat): \(error.message)")
                }
            }
        }
        await stack.router.add(account: "brokered", label: "API", kind: "openai-key", billing: "api-key", engine: PlainAdapter())
        #expect(try await app.request("session/load", params)["_meta"]?["agneta"]?["resumed"]?.boolValue == true)
    }

    /// An app Agneta can't verify is sent a code before the user is asked, and the approval sees the same one.
    @Test func unverifiedAppsGetTheCodeTheUserCompares() async throws {
        let stack = try await Stack.start(port: 47450)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Coded")
        let sent = app.notifications("agneta/pairingCode").first?["code"]?.stringValue
        if let sent {
            #expect(sent.count == 6 && sent.allSatisfy(\.isNumber))
            #expect(PairingCodes.shared.all.contains(sent))
        } else {
            // A verified test runner gets no code, and the approval none either.
            #expect(PairingCodes.shared.all.contains(nil))
        }
    }

    /// Features are per engine: a session says what its engine can do, and asking for more is a clear error.
    @Test func sessionsAdvertiseTheirEnginesFeatures() async throws {
        let stack = try await Stack.start(port: 47440)
        defer { stack.stop() }
        await stack.engines.use(PlainAdapter(), for: "native")
        await stack.router.add(account: "native", label: "Claude", runner: .native, kind: "claude", billing: "subscription", engine: PlainAdapter())
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Features")
        let initialize = try await app.request("initialize", ["protocolVersion": 1, "_meta": ["agneta": ["token": .string(app.token ?? "")]]])
        let listed = initialize["_meta"]?["agneta"]?["accounts"]?.arrayValue?.first { $0["id"]?.stringValue == "native" }
        #expect(listed?["capabilities"]?["engine"]?.stringValue == "plain" && listed?["capabilities"]?["steer"]?.boolValue == false)

        let rich = try await app.request("session/new", ["cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                                                         "_meta": ["agneta": ["account": "brokered"]]])
        #expect(rich["_meta"]?["agneta"]?["capabilities"]?["steer"]?.boolValue == true)
        let plain = try await app.request("session/new", ["cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                                                          "_meta": ["agneta": ["account": "native"], "agneta/instructions": ["text": "set at launch"]]])
        let session = try #require(plain["sessionId"]?.stringValue)
        #expect(plain["_meta"]?["agneta"]?["capabilities"]?["fork"]?.boolValue == false)
        for (method, params) in [("agneta/steer", ["prompt": [["type": "text", "text": "x"]]]), ("agneta/instructions/set", ["text": "new"]), ("agneta/fork", ["mcpServers": []])] as [(String, JSONValue)] {
            do {
                _ = try await app.request(method, params.setting("sessionId", to: .string(session)))
                Issue.record("\(method) should be refused")
            } catch let error as RPCError {
                #expect(error.code == -32014, "\(method)")
                #expect(error.message.hasPrefix("Plain can't"), "\(method)")
            }
        }
        // The plain engine's instructions went in at launch, not as a request.
        #expect(await stack.engines.instructions.isEmpty)
    }

    /// An engine's "sign in first" becomes Agneta's: the app learns which account, in words and in data.
    @Test func engineSignInErrorsPointToAgneta() async throws {
        #expect(Router.isAuthRequired(RPCError(code: -32000, message: "Authentication required")))
        #expect(Router.isAuthRequired(RPCError(code: -32603, message: "You are not logged in. Please log in.")))
        #expect(!Router.isAuthRequired(RPCError(code: -32603, message: "The engine stopped")))
        let stack = try await Stack.start(port: 47439)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Signed out")
        let session = try await stack.session(app, account: "brokered")
        do {
            _ = try await app.prompt(session, "auth")
            Issue.record("expected the turn to fail")
        } catch let error as RPCError {
            #expect(error.data?["agneta"]?["needsSignIn"]?.stringValue == "brokered")
            #expect(error.message == "API needs you to sign in again in Agneta")
        }
        // The next turn is unaffected once the engine is happy again.
        #expect(try await app.prompt(session, "hello")["stopReason"]?.stringValue == "end_turn")
    }

    /// An app reaches only Agneta's methods. An engine's own method (here Goose's steering, which the fake
    /// engine answers) is refused before it reaches the engine, and so is any notification but cancel:
    /// engine methods would bypass the checks made when the session started.
    @Test func enginesOwnMethodsAreRefused() async throws {
        let stack = try await Stack.start(port: 47601)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Reacher")
        let session = try await stack.session(app, account: "brokered")
        for method in ["_goose/unstable/session/steer", "_goose/unstable/session/extensions/add", "session/list", "session/fork"] {
            do {
                _ = try await app.request(method, ["sessionId": .string(session), "prompt": [], "mcpServers": []])
                Issue.record("\(method) reached the engine")
            } catch let error as RPCError {
                #expect(error.code == RPCError.methodNotFound && error.message.hasPrefix("Agneta"), "\(method)")
            }
        }
        #expect(await stack.engines.steers.isEmpty)
        app.notify("session/update", ["sessionId": .string(session), "update": ["sessionUpdate": "plan"]])
        app.notify("_goose/unstable/anything", ["sessionId": .string(session)])
        app.notify("session/cancel", ["sessionId": .string(session)])
        try await Task.sleep(for: .milliseconds(200))
        #expect(await stack.engines.notifications == ["session/cancel"])
        // Agneta's own steering still reaches the engine through its adapter.
        let turn = Task { try await app.prompt(session, "slow") }
        try await Task.sleep(for: .milliseconds(200))
        _ = try await app.request("agneta/steer", ["sessionId": .string(session), "prompt": [["type": "text", "text": "go on"]]])
        _ = try await turn.value
        #expect(await stack.engines.steers.count == 1)
    }

    /// Remove Access ends the app's sessions and closes its connection: nothing more runs on it, and its
    /// token no longer pairs a new connection.
    @Test func removingAccessCutsOffTheConnectedApp() async throws {
        let stack = try await Stack.start(port: 47602)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Revoked")
        let session = try await stack.session(app, account: "brokered")
        let grant = try #require(try await stack.meta(session)["app"]?["grant"]?.stringValue)
        await stack.router.revoke(grant: grant)
        await #expect(throws: (any Error).self) { _ = try await stack.session(app, account: "brokered") }
        await #expect(throws: (any Error).self) { _ = try await app.prompt(session, "hello") }
        // The token is gone too: a new connection can't initialize with it.
        let again = AppClient(port: stack.port)
        defer { again.close() }
        do {
            _ = try await again.request("initialize", ["protocolVersion": 1, "clientCapabilities": [:], "_meta": ["agneta": ["token": .string(try #require(app.token))]]])
            Issue.record("a removed token initialized")
        } catch let error as RPCError {
            #expect(error.code == -32001)
        }
    }

    /// Reset's shutdown closes every app connection, paired or not, and the router answers nothing more.
    @Test func shutdownClosesEveryConnection() async throws {
        let stack = try await Stack.start(port: 47603)
        defer { stack.stop() }
        let paired = AppClient(port: stack.port)
        defer { paired.close() }
        try await paired.pairAndInitialize("Paired")
        _ = try await stack.session(paired, account: "brokered")
        let unpaired = AppClient(port: stack.port)
        defer { unpaired.close() }
        await #expect(throws: (any Error).self) { _ = try await unpaired.request("session/new", ["cwd": "/tmp", "mcpServers": []]) } // not paired: refused, still connected
        await stack.router.shutdown()
        await #expect(throws: (any Error).self) { _ = try await stack.session(paired, account: "brokered") }
        await #expect(throws: (any Error).self) { _ = try await unpaired.request("agneta/pair", ["name": "Late"]) }
        let late = AppClient(port: stack.port)
        defer { late.close() }
        await #expect(throws: (any Error).self) { _ = try await late.request("agneta/pair", ["name": "Later"]) }
    }

    /// Runs `work`, giving up after `seconds`: true if it finished in time.
    static func within(_ seconds: Double, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let once = OnceFlag()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task { await work(); if once.take() { continuation.resume(returning: true) } }
            Task { try? await Task.sleep(for: .seconds(seconds)); if once.take() { continuation.resume(returning: false) } }
        }
    }

    /// Close ends the session whatever the engine does: answers with an error, or never answers.
    @Test func closeEndsTheSessionEvenWhenTheEngineFailsOrHangs() async throws {
        let stack = try await Stack.start(port: 47604)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Closer")
        for mode in [FakeEngines.Close.fail, .hang] {
            await stack.engines.closing(mode)
            let session = try await stack.session(app, account: "brokered")
            let started = ContinuousClock.now
            _ = try await app.request("session/close", ["sessionId": .string(session)])
            #expect(ContinuousClock.now - started < .seconds(8), "\(mode)")
            do {
                _ = try await app.prompt(session, "hello")
                Issue.record("the session outlived close (\(mode))")
            } catch let error as RPCError {
                #expect(error.code == RPCError.invalidParams)
            }
        }
    }

    /// Stop and a disconnect finish within the bound even when the engine has stopped reading.
    @Test func stopAndDisconnectAreBoundedWithAWedgedEngine() async throws {
        let stack = try await Stack.start(port: 47605)
        defer { stack.stop() }
        let ended = Recorder()
        await stack.router.observe { event in if case .sessionEnded(let id, _) = event { ended.add(id) } }
        let app = AppClient(port: stack.port)
        try await app.pairAndInitialize("Wedged")
        let stopped = try await stack.session(app, account: "brokered", tools: "workspace")
        let dropped = try await stack.session(app, account: "brokered", tools: "workspace")
        await stack.engines.wedge()
        let router = stack.router
        #expect(await Self.within(8) { await router.stop(stopped) }, "Stop waited on a wedged engine")
        app.close()
        for _ in 0..<80 where !ended.all.contains(dropped) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(ended.all.contains(stopped) && ended.all.contains(dropped), "a disconnect waited on a wedged engine")
    }

    /// A load cut short (here by the app disconnecting while the engine replays) leaves no task behind: nothing
    /// announces it as started after it ended.
    @Test func aLoadCutShortLeavesNoTask() async throws {
        let stack = try await Stack.start(port: 47606)
        defer { stack.stop() }
        let events = Recorder()
        await stack.router.observe { event in
            switch event {
            case .sessionStarted(let info): events.add("started \(info.id)")
            case .sessionEnded(let id, _): events.add("ended \(id)")
            default: break
            }
        }
        let app = AppClient(port: stack.port)
        try await app.pairAndInitialize("Loader")
        let session = try await stack.session(app, account: "brokered")
        _ = try await app.request("session/close", ["sessionId": .string(session)])
        await stack.engines.loading(takes: .seconds(1))
        let cwd = JSONValue.string(stack.root.appending(path: "work").path(percentEncoded: false))
        let load = Task { try? await app.request("session/load", ["sessionId": .string(session), "cwd": cwd, "mcpServers": []]) }
        try await Task.sleep(for: .milliseconds(300))
        app.close()
        _ = await load.value
        try await Task.sleep(for: .milliseconds(1500))
        #expect(events.all == ["started \(session)", "ended \(session)"], "\(events.all)")
    }

    /// A prompt that outlives its session (closed, then reopened under the same id) doesn't free the new
    /// session's turn slot when it finally returns.
    @Test func aStalePromptDoesntFreeTheReopenedSessionsTurn() async throws {
        let stack = try await Stack.start(port: 47607)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Reopener")
        let session = try await stack.session(app, account: "brokered")
        let stale = Task { try? await app.prompt(session, "stubborn") }
        try await Task.sleep(for: .milliseconds(200))
        _ = try await app.request("session/close", ["sessionId": .string(session)])
        let cwd = JSONValue.string(stack.root.appending(path: "work").path(percentEncoded: false))
        _ = try await app.request("session/load", ["sessionId": .string(session), "cwd": cwd, "mcpServers": []])
        let running = Task { try await app.prompt(session, "slow") }
        _ = await stale.value
        try await Task.sleep(for: .milliseconds(100))
        do {
            _ = try await app.prompt(session, "hello")
            Issue.record("the stale prompt freed the running turn's slot")
        } catch let error as RPCError {
            #expect(error.code == -32011)
        }
        _ = try await app.request("agneta/steer", ["sessionId": .string(session), "prompt": [["type": "text", "text": "done"]]])
        _ = try await running.value
    }

    /// An engine that exits on its own ends its sessions: the app hears why, and the session is gone rather than
    /// failing every later prompt.
    @Test func aDeadEngineEndsItsSessions() async throws {
        let stack = try await Stack.start(port: 47608)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Crashed")
        let session = try await stack.session(app, account: "brokered")
        await stack.engines.crash()
        for _ in 0..<40 where app.notifications("agneta/sessionStopped").isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let stopped = app.notifications("agneta/sessionStopped")
        #expect(stopped.count == 1 && stopped.first?["stoppedBy"]?.stringValue == "engine" && stopped.first?["sessionId"]?.stringValue == session)
        do {
            _ = try await app.prompt(session, "hello")
            Issue.record("the session outlived its engine")
        } catch let error as RPCError {
            #expect(error.code == RPCError.invalidParams)
        }
    }

    /// An app that goes away while the user is still deciding withdraws its request, so the approval window
    /// stops asking about it.
    @Test func aDisconnectWithdrawsAWaitingPairingRequest() async throws {
        let asked = Recorder()
        let stack = try await Stack.start(port: 47609, approve: { request in
            asked.add(request.id.uuidString)
            try? await Task.sleep(for: .seconds(3600)) // the user never answers
            return nil
        })
        defer { stack.stop() }
        let withdrawn = Recorder()
        await stack.router.observe { event in if case .pairingWithdrawn(let id) = event { withdrawn.add(id.uuidString) } }
        let app = AppClient(port: stack.port)
        let pairing = Task { try? await app.request("agneta/pair", ["name": "Impatient"]) }
        for _ in 0..<40 where asked.all.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        app.close()
        _ = await pairing.value
        for _ in 0..<40 where withdrawn.all.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(asked.all.count == 1 && withdrawn.all == asked.all)
    }

    /// A prompt while one runs is refused, not run alongside.
    @Test func aSecondPromptWhileATurnRunsIsRefused() async throws {
        let stack = try await Stack.start(port: 47438)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Busy")
        let session = try await stack.session(app, account: "brokered")
        let first = Task { try await app.prompt(session, "slow") }
        try await Task.sleep(for: .milliseconds(200))
        do {
            _ = try await app.prompt(session, "hello")
            Issue.record("a second prompt ran alongside")
        } catch let error as RPCError {
            #expect(error.code == -32011)
        }
        _ = try await app.request("agneta/steer", ["sessionId": .string(session), "prompt": [["type": "text", "text": "finish"]]])
        #expect(try await first.value["stopReason"]?.stringValue == "end_turn")
        #expect(try await app.prompt(session, "hello")["stopReason"]?.stringValue == "end_turn")
    }

    /// Modes that stop asking are refused where Agneta gates calls from the questions.
    @Test func modesThatSkipPermissionsAreRefused() async throws {
        let stack = try await Stack.start(port: 47437)
        defer { stack.stop() }
        let claude = ClaudeCodeAdapter(executable: URL(filePath: "/usr/bin/false"), cli: InstalledCLI(path: URL(filePath: "/usr/bin/false"), version: "2", source: "path"))
        await stack.engines.use(claude, for: "native")
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Modes")
        let session = try await stack.session(app, account: "native")
        for (method, params) in [("session/set_mode", ["modeId": "bypassPermissions"]), ("session/set_config_option", ["configId": "mode", "value": "acceptEdits"])] as [(String, JSONValue)] {
            do {
                _ = try await app.request(method, params.setting("sessionId", to: .string(session)))
                Issue.record("\(method) was let through")
            } catch let error as RPCError {
                #expect(error.code == RPCError.invalidParams && error.data?["agneta"]?["unenforceable"] != nil, "\(method)")
            }
        }
        // Model changes and safe modes still reach the engine (the fake one doesn't know them: methodNotFound).
        do { _ = try await app.request("session/set_config_option", ["sessionId": .string(session), "configId": "mode", "value": "plan"]) } catch let error as RPCError {
            #expect(error.code != RPCError.invalidParams)
        }
    }

    /// A task that ran on the shared engine can't come back with built-in tools.
    @Test func sharedEngineTasksResumeWithoutBuiltIns() async throws {
        let stack = try await Stack.start(port: 47436)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Resumer")
        let session = try await stack.session(app, account: "brokered")
        _ = try await app.request("session/close", ["sessionId": .string(session)])
        try await Task.sleep(for: .milliseconds(200))
        let cwd = JSONValue.string(stack.root.appending(path: "work").path(percentEncoded: false))
        do {
            _ = try await app.request("session/load", ["sessionId": .string(session), "cwd": cwd, "mcpServers": [],
                                                       "_meta": [SessionPolicy.key: ["tools": "workspace", "approval": "never-ask"]]])
            Issue.record("built-ins were enabled on the shared engine")
        } catch let error as RPCError {
            #expect(error.data?["agneta"]?["unenforceable"]?.arrayValue?.first?.stringValue == "tools")
        }
    }

    @Test func aDisconnectEndsTheTraceWithItsReason() async throws {
        let stack = try await Stack.start(port: 47445)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        try await app.pairAndInitialize("Leaver")
        let session = try await stack.session(app, account: "brokered")
        _ = try await app.prompt(session, "hello")
        app.close()
        try await Task.sleep(for: .milliseconds(400))
        let records = try stack.records(session)
        #expect(records.contains { $0["event"]?.stringValue == "stop" && $0["by"]?.stringValue == "app" && $0["reason"]?.stringValue == "disconnected" })
        #expect(records.last?["type"]?.stringValue == "end")
        #expect(records.first?["engine"]?["startMs"] != nil)
    }
}

/// Strings collected from callbacks on any thread.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}
