// The router's contract with apps, against an in-memory fake engine that
// follows a script: permission decisions and how they're traced, per-turn usage
// in prompt results, live and read trace access with per-app scoping,
// Agneta's own steering and instructions methods, and disconnect reasons. Fast
// and exact; the real-engine paths are in RouterIntegrationTests and
// AppScenarioTests.
import Foundation
import Testing
import os

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
/// Claude Code's adapter with Goose's export and import, which the fake engine answers: what a fork of a Claude Code
/// task would send it, should Claude Code's fork be wired.
struct ForkableClaudeCode: EngineAdapter {
    let base = ClaudeCodeAdapter(
        executable: URL(filePath: "/usr/bin/false"),
        cli: InstalledCLI(path: URL(filePath: "/usr/bin/false"), version: "2", source: "path"))
    let goose = GooseAdapter(executable: URL(filePath: "/usr/bin/false"))
    var id: String { base.id }
    var displayName: String { base.displayName }
    var capabilities: EngineCapabilities { base.capabilities }
    func launch(_ context: EngineLaunchContext) throws -> EngineLaunch { try base.launch(context) }
    func newSession(cwd: URL, servers: [JSONValue], policy: SessionPolicy, title: JSONValue?, instructions: String?)
        -> JSONValue
    { base.newSession(cwd: cwd, servers: servers, policy: policy, title: title, instructions: instructions) }
    func loadSession(_ engineSession: String, cwd: URL, servers: [JSONValue], policy: SessionPolicy) -> JSONValue {
        base.loadSession(engineSession, cwd: cwd, servers: servers, policy: policy)
    }
    func loadSession(
        _ engineSession: String, cwd: URL, servers: [JSONValue], policy: SessionPolicy, instructions: String?
    ) -> JSONValue {
        base.loadSession(engineSession, cwd: cwd, servers: servers, policy: policy, instructions: instructions)
    }
    func prepareSession(_ engineSession: String) -> [EngineRequest] { base.prepareSession(engineSession) }
    func setInstructions(_ engineSession: String, text: String, appendKey: String?) -> EngineRequest? { nil }
    func steer(_ engineSession: String, run: String?, prompt: JSONValue) -> EngineRequest? { nil }
    func steerResult(_ result: JSONValue) -> (accepted: Bool, run: String?) { (false, nil) }
    func activeRun(in update: JSONValue) -> String?? { nil }
    func toolIdentity(in update: JSONValue) -> (tool: String?, server: String?, message: String?) {
        base.toolIdentity(in: update)
    }
    func exportSession(_ engineSession: String) -> EngineRequest? { goose.exportSession(engineSession) }
    func importSession(_ exported: JSONValue) -> EngineRequest? { goose.importSession(exported) }
    func importedSession(_ result: JSONValue) -> String? { goose.importedSession(result) }
    func ledger(stateRoot: URL, engineSession: String) -> (any UsageLedger)? { nil }
    func appToolsUpfront(_ policy: SessionPolicy, kind: AccountKind?) -> Bool? {
        base.appToolsUpfront(policy, kind: kind)
    }
}

/// An engine with only plain ACP: no steering, fork or instructions between turns.
/// A plain engine, standing in for one of Agneta's (Goose by default) so a provider supports it.
struct PlainAdapter: EngineAdapter {
    let base = GooseAdapter(executable: URL(filePath: "/usr/bin/false"))
    var stateFormat = "plain/1"
    var id = "goose"
    var displayName: String { "Plain" }
    var capabilities: EngineCapabilities {
        EngineCapabilities(steer: false, fork: false, instructionsBetweenTurns: false, processPerSession: true)
    }
    func launch(_ context: EngineLaunchContext) throws -> EngineLaunch { try base.launch(context) }
    func newSession(cwd: URL, servers: [JSONValue], policy: SessionPolicy, title: JSONValue?, instructions: String?)
        -> JSONValue
    { ["cwd": .string(cwd.path(percentEncoded: false)), "mcpServers": .array(servers)] }
    func loadSession(_ engineSession: String, cwd: URL, servers: [JSONValue], policy: SessionPolicy) -> JSONValue {
        ["sessionId": .string(engineSession)]
    }
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
    private(set) var permissionAnswers: [String: JSONValue] = [:]
    private(set) var steers: [JSONValue] = []
    private(set) var instructions: [JSONValue] = []
    /// Every notification the engines received, by method.
    private(set) var notifications: [String] = []
    /// How engines answer `session/close`: normally, with an error, or never.
    enum Close { case answer, fail, hang }
    private(set) var closeRequests = 0
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
    private var onOpen: (@Sendable () async -> Void)?
    func beforeOpeningReply(_ action: @escaping @Sendable () async -> Void) { onOpen = action }
    /// Whether engines export and import conversations (Goose's fork). Off by default: tests that need a fork to fail
    /// (one that isn't counted, AppLimitsContractTests) rely on an engine that can't export.
    private var exports = false
    func exporting(_ on: Bool) { exports = on }
    /// Every engine stops reading: Agneta's writes to it wait forever.
    func wedge() async { for gate in gates { await gate.close() } }
    /// Slow turns waiting to be steered or cancelled, by engine session, each also woken after 3 s.
    private var steerWaiters: [UUID: (session: String, continuation: CheckedContinuation<Void, Never>)] = [:]
    /// Engine sessions whose running turn was cancelled. Per session, as in a real engine: a cancel for one session
    /// never ends another's turn.
    private var cancelled: Set<String> = []

    /// The engine each open was for.
    private(set) var askedEngines: [String] = []
    /// The policy each open was for.
    private(set) var askedPolicies: [SessionPolicy] = []
    /// The params of every `session/new` and `session/load` the engines got, in order.
    private(set) var opening: [(method: String, params: JSONValue)] = []
    /// Each engine session's MCP servers, from its latest `session/new` or `session/load`.
    private(set) var servers: [String: [JSONValue]] = [:]
    /// Every prompt's content blocks as the engine got them, in order.
    private(set) var prompts: [[JSONValue]] = []
    /// The last `session/prompt`'s params as the engine got them.
    private(set) var lastPromptParams: JSONValue?
    /// What the result tool answered each `result` script's calls, in order: (text, isError), or nil when unreachable.
    private(set) var resultAnswers: [(text: String, isError: Bool)?] = []
    /// What the engine was asked to set (`session/set_config_option`): config id = value, in order.
    private(set) var configSets: [String] = []
    /// The model and effort it offers, and what's current, as a real engine lists them (Router+Settings).
    private var current = ["model": "m1", "effort": "low"]
    func configOptions() -> JSONValue {
        [
            [
                "id": "model", "category": "model", "type": "select", "currentValue": .string(current["model"]!),
                "options": [["value": "m1", "name": "Model One"], ["value": "m2", "name": "Model Two"]]
            ],
            [
                "id": "effort", "category": "thought_level", "type": "select",
                "currentValue": .string(current["effort"]!),
                "options": [
                    ["group": "levels", "options": [["value": "low", "name": "Low"], ["value": "high", "name": "High"]]]
                ]
            ]
        ]
    }

    func open(
        account: String, engine adapter: any EngineAdapter, policy: SessionPolicy, mcpPorts: [Int], key: String?,
        session: EngineSessionSpec?
    ) async throws -> EngineLease {
        opened += 1
        askedEngines.append(adapter.id)
        askedPolicies.append(policy)
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
        await engine.handle(notifications: { [weak self] method, params in
            await self?.noted(method)
            if method == "session/cancel", let session = params?["sessionId"]?.stringValue {
                await self?.cancel(session)
            }
        })
        // Speaks Goose's dialect, so Goose's adapter describes it.
        // App-only sessions get the shared key, as the real supervisor gives them.
        return EngineLease(
            key: key
                ?? (policy.tools == .appOnly
                    ? EngineKeys.shared(account: account, engine: adapter.id) : "\(account)/fake-\(n)"),
            peer: agneta, pid: getpid(), dedicated: true, engine: adapter, startMs: 12.5,
            engineInfo: ["name": "fake", "version": "1"])
    }

    func release(_ lease: EngineLease) async { released += 1 }

    private func answer(_ engine: RPCPeer, n: Int, method: String, params: JSONValue?) async -> Result<
        JSONValue, RPCError
    > {
        let session = params?["sessionId"] ?? .string("e\(n)")
        func update(_ update: JSONValue) async {
            try? await engine.notify("session/update", ["sessionId": session, "update": update])
        }
        if method == "session/new" || method == "session/load" {
            opening.append((method, params ?? .null))
            await onOpen?()
        }
        if method == "session/new" { servers["e\(n)"] = params?["mcpServers"]?.arrayValue ?? [] }
        if method == "session/load", let id = params?["sessionId"]?.stringValue {
            servers[id] = params?["mcpServers"]?.arrayValue ?? []
        }
        switch method {
        case "session/new":
            // As real engines may: an update for the new session before the answer that names it.
            try? await engine.notify(
                "session/update",
                [
                    "sessionId": .string("e\(n)"),
                    "update": ["sessionUpdate": "available_commands_update", "availableCommands": [["name": "review"]]]
                ])
            current = ["model": "m1", "effort": "low"]
            return .success([
                "sessionId": .string("e\(n)"), "models": ["currentModelId": "fake-model"],
                "configOptions": configOptions()
            ])
        case "_goose/unstable/session/system-prompt/set":
            instructions.append(params ?? .null)
            return .success([:])
        case "_goose/unstable/session/steer":
            steers.append(params ?? .null)
            if let session = params?["sessionId"]?.stringValue { wakeAll(session) }
            return .success(["runId": params?["expectedRunId"] ?? .null])
        case "session/prompt":
            let text = params?["prompt"]?.arrayValue?.first?["text"]?.stringValue ?? ""
            prompts.append(params?["prompt"]?.arrayValue ?? [])
            lastPromptParams = params
            cancelled.remove(session.stringValue ?? "") // a cancel belongs to the turn it arrived in
            if text.hasPrefix("result ") {
                // "result <json>": {"calls": [{"tool": "submit_x", "arguments": {…}, "ask": true}], "stopReason": "…"}.
                // Each call is announced as Goose does, its permission asked when "ask", then made over real HTTP to
                // the agneta-result server this session was given, as an engine's MCP client would.
                let script = (try? JSONCoding.decode(Data(text.dropFirst("result ".count).utf8))) ?? [:]
                for (i, call) in (script["calls"]?.arrayValue ?? []).enumerated() {
                    let tool = call["tool"]?.stringValue ?? ""
                    let callID = JSONValue.string("result-\(prompts.count)-\(i)")
                    let goose: JSONValue = [
                        "toolCall": ["extensionName": "agneta-result", "toolName": .string("agneta-result__" + tool)]
                    ]
                    await update([
                        "sessionUpdate": "tool_call", "toolCallId": callID, "title": .string(tool), "kind": "other",
                        "status": "pending", "_meta": ["goose": goose]
                    ])
                    if call["ask"] == true {
                        permissionAnswers[tool] =
                            (try? await engine.request(
                                "session/request_permission",
                                [
                                    "sessionId": session,
                                    "toolCall": ["toolCallId": callID, "kind": "other", "title": .string(tool)],
                                    "options": [
                                        ["kind": "allow_once", "optionId": "allow", "name": "Allow"],
                                        ["kind": "reject_once", "optionId": "reject", "name": "Reject"]
                                    ]
                                ])) ?? .null
                    }
                    let server = servers[session.stringValue ?? ""]?.first { $0["name"] == "agneta-result" }
                    resultAnswers.append(
                        await Self.callResultTool(server, tool: tool, arguments: call["arguments"] ?? [:]))
                    await update(["sessionUpdate": "tool_call_update", "toolCallId": callID, "status": "completed"])
                }
                // What the engine does after the calls: never finish ("deaf"), take a while ("wait"), or fail ("error").
                switch script["then"]?.stringValue {
                case "deaf"?: try? await Task.sleep(for: .seconds(60))
                case "wait"?: try? await Task.sleep(for: .milliseconds(1500))
                case "error"?: return .failure(RPCError(code: RPCError.internalError, message: "boom"))
                default: break
                }
                let stop = script["stopReason"]?.stringValue ?? "end_turn"
                return .success([
                    "stopReason": .string(cancelled.contains(session.stringValue ?? "") ? "cancelled" : stop),
                    "usage": ["inputTokens": 5, "outputTokens": 1]
                ])
            }
            if text.hasPrefix("permission ") {
                let kind = String(text.dropFirst("permission ".count))
                await update([
                    "sessionUpdate": "tool_call", "toolCallId": .string("call-\(kind)"),
                    "title": .string("\(kind) tool"), "kind": .string(kind), "status": "pending"
                ])
                let answer = try? await engine.request(
                    "session/request_permission",
                    [
                        "sessionId": session,
                        "toolCall": [
                            "toolCallId": .string("call-\(kind)"), "kind": .string(kind),
                            "title": .string("\(kind) tool")
                        ],
                        "options": [
                            ["kind": "allow_once", "optionId": "allow", "name": "Allow"],
                            ["kind": "reject_once", "optionId": "reject", "name": "Reject"]
                        ]
                    ])
                permissionAnswers[kind] = answer ?? .null
                await update([
                    "sessionUpdate": "tool_call_update", "toolCallId": .string("call-\(kind)"), "status": "completed"
                ])
            } else if text.hasPrefix("ask ") {
                // "ask <label> <json>": a permission request with this tool call (and request _meta, under "_meta"),
                // after a tool_call update for the same call when the JSON has "announce".
                let rest = text.dropFirst("ask ".count)
                let label = String(rest.prefix { $0 != " " })
                let spec = (try? JSONCoding.decode(Data(rest.drop { $0 != " " }.utf8))) ?? [:]
                if let announced = spec["announce"] { await update(announced) }
                var request: JSONValue = [
                    "sessionId": session, "toolCall": spec["toolCall"] ?? [:],
                    "options": [
                        ["kind": "allow_once", "optionId": "allow", "name": "Allow"],
                        ["kind": "reject_once", "optionId": "reject", "name": "Reject"]
                    ]
                ]
                if let meta = spec["_meta"] { request = request.setting("_meta", to: meta) }
                permissionAnswers[label] = (try? await engine.request("session/request_permission", request)) ?? .null
            } else if text == "deaf" {
                // Ignores cancel and never finishes on its own: stuck in a tool, as far as Agneta can tell.
                try? await Task.sleep(for: .seconds(60))
            } else if text == "stubborn" {
                // Ignores cancel: finishes on its own after a while.
                try? await Task.sleep(for: .milliseconds(1500))
            } else if text == "auth" {
                return .failure(RPCError(code: -32000, message: "Authentication required"))
            } else if text == "ratelimit" {
                return .failure(
                    RPCError(
                        code: RPCError.internalError, message: RateLimitTests.goose, data: ["reason": "turn_failed"]))
            } else if text == "slow" {
                await update(["sessionUpdate": "session_info_update", "_meta": ["goose": ["activeRunId": "run-7"]]])
                await waitForSteer(session.stringValue ?? "", upTo: .seconds(3))
            } else {
                await update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "hi"]])
            }
            return .success([
                "stopReason": cancelled.contains(session.stringValue ?? "") ? "cancelled" : "end_turn",
                "usage": ["inputTokens": 5, "outputTokens": 1]
            ])
        case "session/set_config_option":
            if let id = params?["configId"]?.stringValue, let value = params?["value"]?.stringValue {
                configSets.append("\(id)=\(value)")
                current[id] = value
            }
            return .success(["configOptions": configOptions()])
        case "session/set_mode":
            return .success([:])
        case "session/load":
            try? await Task.sleep(for: loadDelay)
            return .success(["models": ["currentModelId": "fake-model"], "configOptions": []])
        case "_goose/unstable/session/export" where exports:
            return .success(["data": ["copied": session]])
        case "_goose/unstable/session/import" where exports:
            return .success(["sessionId": .string("e\(n)-imported"), "messageCount": 2])
        case "session/close":
            closeRequests += 1
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

    /// A `tools/call` to a result server entry (ACP's HTTP form), as an engine's MCP client sends it.
    static func callResultTool(_ server: JSONValue?, tool: String, arguments: JSONValue) async -> (
        text: String, isError: Bool
    )? {
        guard let server, let url = server["url"]?.stringValue.flatMap(URL.init(string:)) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for header in server["headers"]?.arrayValue ?? [] {
            if let name = header["name"]?.stringValue, let value = header["value"]?.stringValue {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        let message: JSONValue = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": .string(tool), "arguments": arguments]
        ]
        request.httpBody = try? JSONCoding.encode(message)
        guard let (data, _) = try? await URLSession(configuration: .ephemeral).data(for: request),
            let reply = try? JSONCoding.decode(data), let result = reply["result"]
        else { return nil }
        return (result["content"]?.arrayValue?.first?["text"]?.stringValue ?? "", result["isError"] == true)
    }

    private func cancel(_ session: String) {
        cancelled.insert(session)
        wakeAll(session)
    }

    /// Waits until this session's turn is steered or cancelled, or `upTo` has passed, whichever comes first. (A task
    /// group would wait for the steer it can't cancel.)
    private func waitForSteer(_ session: String, upTo limit: Duration) async {
        let id = UUID()
        await withCheckedContinuation { continuation in
            steerWaiters[id] = (session, continuation)
            Task { [weak self] in
                try? await Task.sleep(for: limit)
                await self?.wake(id)
            }
        }
    }

    private func wake(_ id: UUID) { steerWaiters.removeValue(forKey: id)?.continuation.resume() }

    /// Wakes the session's waiting turns, and no other session's.
    private func wakeAll(_ session: String) {
        for (id, waiter) in steerWaiters where waiter.session == session {
            steerWaiters[id] = nil
            waiter.continuation.resume()
        }
    }
}

/// Ports: 474xx belong to the integration and scenario suites (some computed, e.g. 47452 + 5 for OpenCode);
/// contract tests added later take 476xx, the sandbox tests 477xx.
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
        static func start(
            port: UInt16, concurrency: Router.Concurrency = .init(), appWorkspaces: Bool = false,
            commit: Router.Commit? = nil,
            clock: TestClock? = nil, calendar: Calendar = .autoupdatingCurrent, reach: ToolReach.Lookup = .system,
            approve: Router.Approve? = nil
        ) async throws -> Stack {
            let root = FileManager.default.temporaryDirectory.appending(
                path: "agneta-contract-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory
            ).realFileURL
            try FileManager.default.createDirectory(at: root.appending(path: "work"), withIntermediateDirectories: true)
            let traces = Traces(folder: root.appending(path: "Traces", directoryHint: .isDirectory))
            let engines = FakeEngines()
            let router = Router(
                context: PolicyContext(
                    userHome: FileManager.default.homeDirectoryForCurrentUser,
                    agnetaRoots: [root.appending(path: "agneta")],
                    appWorkspaces: appWorkspaces ? root.appending(path: "apps", directoryHint: .isDirectory) : nil),
                engines: engines, traces: traces, concurrency: concurrency, commit: commit,
                now: { clock?.now ?? Date() }, calendar: calendar, reach: reach
            ) { request in
                PairingCodes.shared.add(request.code)
                return await approve?(request) ?? Router.PairingAnswer(accounts: ["brokered", "native"], remember: true)
            }
            await router.add(account: "brokered", label: "API", kind: .openAIKey, billing: "api-key")
            await router.add(
                account: "native", label: "Claude", runner: .native, kind: .claude, billing: "subscription")
            // Goose only, as a fresh Agneta has; the fake engine speaks its dialect.
            await router.setCatalog(EngineCatalog(ready: [GooseAdapter(executable: URL(filePath: "/usr/bin/false"))]))
            let server = try WebSocketServer(port: port)
            try await server.start()
            Task { for await connection in server.connections { Task { await router.serve(connection) } } }
            AppClient.register(scope: root.appending(path: "work", directoryHint: .isDirectory), port: port)
            return Stack(root: root, engines: engines, traces: traces, router: router, server: server, port: port)
        }

        /// `sandbox`: the app's ask, or nil for the grant's (full power by default).
        func session(
            _ app: AppClient, account: String, approval: String = "never-ask", tools: String = "app-only",
            network: String = "none",
            sandbox: String? = nil, meta: [String: JSONValue] = [:]
        ) async throws -> String {
            var policy: JSONValue = [
                "tools": .string(tools), "network": .string(network), "approval": .string(approval)
            ]
            if let sandbox { policy = policy.setting("sandbox", to: .string(sandbox)) }
            var fullMeta: [String: JSONValue] = [SessionPolicy.key: policy, "agneta": ["account": .string(account)]]
            fullMeta.merge(meta) { _, new in new }
            let result = try await app.request(
                "session/new",
                [
                    "cwd": .string(root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                    "_meta": .object(fullMeta)
                ])
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
        // A native runner on a provider whose engine can be contained (an Anthropic key here; Goose on a Claude plan
        // can't be), so a contained session's built-in tools are judged by the policy.
        let stack = try await Stack.start(
            port: 47441,
            approve: { _ in Router.PairingAnswer(accounts: ["brokered", "native", "nativeKey"], remember: true) })
        defer { stack.stop() }
        await stack.router.add(
            account: "nativeKey", label: "Key", runner: Router.ToolRunner.native, kind: AccountKind.anthropicKey,
            billing: "api-key")
        let app = AppClient(port: stack.port)
        defer { app.close() }
        app.answerPermissions(with: "allow")
        try await app.pairAndInitialize("Contract")

        // A contained session's engine runs its own tools: with no network, its shell is refused before it runs.
        let native = try await stack.session(app, account: "nativeKey", tools: "workspace", sandbox: "contained")
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

        let decisions = try stack.records(native).filter { $0["type"]?.stringValue == "permission" }.map {
            $0["decision"]?.stringValue
        }
        #expect(decisions == ["refused-by-policy", "allowed-by-policy"])
        let asked = try #require(try stack.records(asking).first { $0["type"]?.stringValue == "permission" })
        #expect(asked["decision"]?.stringValue == "asked-app" && asked["toolKind"]?.stringValue == "read")
    }

    static let goose = GooseAdapter(executable: URL(filePath: "/usr/bin/false"))
    static let opencode = OpenCodeAdapter(executable: URL(filePath: "/usr/bin/false"))

    /// An app picks the provider and engine of each task, among what its grant allows and the provider supports; one
    /// that names no engine runs on the provider's default. `agneta/access` (and `initialize`) says what it may use;
    /// anything else is refused with that. A task from a shared engine resumes there only without built-in tools.
    @Test func aTaskRunsOnAnEngineItsProviderSupports() async throws {
        let stack = try await Stack.start(port: 47645)
        defer { stack.stop() }
        await stack.router.setCatalog(
            EngineCatalog([
                .init(ready: Self.goose), .init(ready: Self.opencode),
                .init(id: "codex", name: "Codex", state: .unavailable("Install Codex"))
            ]))
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Contract")
        // Read as the typed report, so what the router sends is what Swift clients decode.
        let access = try AccessReport(json: try await app.request("agneta/access", [:]))
        let brokered = try #require(access.providers.first { $0.id == "brokered" })
        #expect(
            brokered.engines == ["goose", "opencode"] && brokered.defaultEngine == "goose"
                && brokered.kind == "openai-key") // Codex isn't here
        #expect(
            Dictionary(uniqueKeysWithValues: access.engines.map { ($0.id, $0.state) }) == [
                "goose": "ready", "opencode": "ready", "codex": "unavailable"
            ])
        #expect(
            access.engines.first { $0.id == "codex" }?.reason == "Install Codex"
                && access.engines.first { $0.id == "goose" }?.capabilities?.fork == true)
        #expect(access.allowedEngines == .all)

        func meta(_ account: String, _ engine: String) -> [String: JSONValue] {
            ["agneta": ["account": .string(account), "engine": .string(engine)]]
        }
        _ = try await stack.session(app, account: "brokered", meta: meta("brokered", "opencode"))
        #expect(await stack.engines.askedEngines.last == "opencode")
        _ = try await stack.session(app, account: "brokered")
        #expect(await stack.engines.askedEngines.last == "goose") // the provider's default
        for (account, engine) in [
            ("native", "opencode"), ("brokered", "codex"), ("brokered", "claude-code"), ("brokered", "nonsense")
        ] {
            do {
                _ = try await stack.session(app, account: account, meta: meta(account, engine))
                Issue.record("\(account) ran on \(engine)")
            } catch let error as RPCError {
                #expect(
                    error.code == RPCError.invalidParams && error.data?["agneta"]?["access"]?["providers"] != nil,
                    "\(error.message)")
            }
        }

        // A task from a shared engine resumes only without built-in tools, like any shared task: built-ins there would
        // run outside the broker's confinement.
        let shared = try await stack.session(app, account: "brokered")
        _ = try await app.request("session/close", ["sessionId": .string(shared)])
        do {
            _ = try await app.request(
                "session/load",
                [
                    "sessionId": .string(shared),
                    "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)),
                    "mcpServers": [],
                    "_meta": [SessionPolicy.key: ["tools": "workspace", "network": "none", "approval": "never-ask"]]
                ])
            Issue.record("a shared task resumed with built-in tools")
        } catch let error as RPCError {
            #expect(error.message.contains("without built-in tools"), "\(error.message)")
        }
    }

    /// The grant's engines are a list the user may narrow (Advanced): a task may run only on those, its default is the
    /// provider's when allowed, else the first allowed; resuming needs the saving engine still allowed. Narrowing the
    /// grant stops what no longer fits and tells the app; Remove Access while the change is saved wins.
    @Test func theGrantLimitsTheEnginesAnAppMayPick() async throws {
        let saved = SavedGrants()
        let stack = try await Stack.start(
            port: 47652, commit: { hash, grant, replacing in await saved.commit(hash, grant, replacing: replacing) }
        ) { _ in
            Router.PairingAnswer(accounts: ["brokered"], engines: .only(["opencode"]), remember: true)
        }
        defer { stack.stop() }
        await stack.router.setCatalog(EngineCatalog(ready: [Self.goose, Self.opencode]))
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Picky")
        let grant = try #require(await saved.last)
        #expect(grant.engines == .only(["opencode"]) && grant.accounts == ["brokered"])

        let initialize = try await app.request(
            "initialize", ["protocolVersion": 1, "_meta": ["agneta": ["token": .string(app.token ?? "")]]])
        let access = initialize["_meta"]?["agneta"]?["access"]
        #expect(access?["providers"]?.arrayValue?.first?["engines"]?.arrayValue == ["opencode"])
        #expect(access?["engines"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == ["opencode"])

        let task = try await stack.session(app, account: "brokered")
        #expect(await stack.engines.askedEngines.last == "opencode") // the provider's default (Goose) isn't allowed
        do {
            _ = try await stack.session(
                app, account: "brokered", meta: ["agneta": ["account": "brokered", "engine": "goose"]])
            Issue.record("ran on an engine the grant doesn't allow")
        } catch let error as RPCError {
            #expect(error.code == RPCError.invalidParams && error.message.contains("isn't allowed"), "\(error.message)")
        }

        // Narrowed to Goose: the OpenCode task stops, the app hears its access changed, and the grant is saved.
        try await stack.router.setAccess(
            grant: grant.id, accounts: ["brokered"], engines: .only(["goose"]), sandbox: .default)
        #expect(await saved.last?.engines == .only(["goose"]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.notifications("agneta/sessionStopped").contains { $0["sessionId"]?.stringValue == task })
        let changed = app.notifications("agneta/accessChanged").last
        #expect(changed?["access"]?["providers"]?.arrayValue?.first?["engines"]?.arrayValue == ["goose"])
        do {
            _ = try await app.request(
                "session/load",
                [
                    "sessionId": .string(task),
                    "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": []
                ])
            Issue.record("resumed on an engine the grant no longer allows")
        } catch let error as RPCError {
            #expect(error.message.contains("isn't allowed"), "\(error.message)")
        }

        // Remove Access while the change is being saved: the grant stays removed.
        await saved.revoking(stack.router, grant.id)
        try await stack.router.setAccess(grant: grant.id, accounts: ["brokered"], engines: .all, sandbox: .default)
        #expect(await !stack.router.hasGrant(grant.id))
    }

    /// An app that pairs again with Always Allow replaces its earlier access: the old token stops working, and a
    /// connection still on it is cut off. An unverified app is only a name, so its new grant is a fresh one (its own
    /// workspace, none of the earlier tasks) and the earlier one is removed with the saving. (A verified app keeps its
    /// grant id; what it was just allowed reaches its other connections as a Settings change does.) Allow Once leaves
    /// it alone, and the app learns from pairing whether to keep its token.
    @Test func pairingAgainReplacesAnAppsAccess() async throws {
        let saved = SavedGrants()
        let answers = Answers([
            Router.PairingAnswer(accounts: ["brokered"], remember: true),
            Router.PairingAnswer(accounts: ["brokered", "native"], remember: true),
            Router.PairingAnswer(accounts: ["native"], remember: false)
        ])
        let stack = try await Stack.start(
            port: 47655, commit: { hash, grant, replacing in await saved.commit(hash, grant, replacing: replacing) }
        ) { _ in await answers.next() }
        defer { stack.stop() }
        func pair() async throws -> (token: String, result: JSONValue) {
            let app = AppClient(port: stack.port)
            defer { app.close() }
            let result = try await app.request("agneta/pair", ["name": "Again"])
            return (try #require(result["token"]?.stringValue), result)
        }
        let first = try await pair()
        let grant = try #require(await saved.last)
        #expect(first.result["remembered"]?.boolValue == true)
        let still = AppClient(port: stack.port)
        defer { still.close() }
        _ = try await still.request(
            "initialize", ["protocolVersion": 1, "_meta": ["agneta": ["token": .string(first.token)]]])

        let second = try await pair()
        let renewed = try #require(await saved.last)
        #expect(renewed.id != grant.id && renewed.accounts == ["brokered", "native"] && renewed.app == grant.app)
        #expect(await saved.replaced == grant.id)
        #expect(!(await stack.router.hasGrant(grant.id)))
        do {
            _ = try await still.request(
                "session/new", ["cwd": "/tmp", "mcpServers": [], "_meta": ["agneta": ["account": "brokered"]]])
            Issue.record("a connection on the replaced grant kept working")
        } catch {}
        let app = AppClient(port: stack.port)
        defer { app.close() }
        do {
            _ = try await app.request(
                "initialize", ["protocolVersion": 1, "_meta": ["agneta": ["token": .string(first.token)]]])
            Issue.record("the replaced token still works")
        } catch let error as RPCError {
            #expect(error.code == -32001)
        }
        _ = try await app.request(
            "initialize", ["protocolVersion": 1, "_meta": ["agneta": ["token": .string(second.token)]]])

        // Allow Once is a grant of its own, for that connection, and says so.
        let once = try await pair()
        #expect(once.result["remembered"]?.boolValue == false)
        #expect(await saved.last?.id == renewed.id) // the remembered one wasn't touched
    }

    /// A connection without a grant is anything on this Mac, so it gets little: a few at a time, small messages, and
    /// not for ever. A refused one is closed, which the app sees as its requests failing.
    @Test func connectionsWithoutAGrantAreBounded() async throws {
        let stack = try await Stack.start(
            port: 47671, concurrency: .init(unpaired: 2, unpairedFrame: 1024, unpairedFor: .milliseconds(500)))
        defer { stack.stop() }
        func refused(_ app: AppClient, _ params: JSONValue = ["protocolVersion": 1]) async -> Bool {
            do { _ = try await app.request("initialize", params); return false } catch let error as RPCError {
                return error.code != -32001
            } catch { return true }
        }
        let big = AppClient(port: stack.port)
        defer { big.close() }
        #expect(await refused(big, ["protocolVersion": 1, "padding": .string(String(repeating: "x", count: 4096))]))
        // The closed one counts until its connection has wound down.
        big.close()
        try await Task.sleep(for: .milliseconds(200))

        // One at a time: connections made together are accepted in any order.
        let first = AppClient(port: stack.port)
        defer { first.close() }
        #expect(!(await refused(first)))
        let second = AppClient(port: stack.port)
        defer { second.close() }
        #expect(!(await refused(second)))
        let third = AppClient(port: stack.port)
        defer { third.close() }
        #expect(await refused(third))

        try await Task.sleep(for: .milliseconds(800))
        #expect(await refused(first)) // never paired: closed once its time was up
    }

    /// A provider's default model and effort are set on each new session, by category, before the app sees it, and
    /// the app sees them as current; a value the engine doesn't offer is left alone, other providers aren't touched,
    /// and asking an engine what it offers sends no prompt and reports what it saw.
    @Test func aProvidersDefaultsApplyToNewSessions() async throws {
        let stack = try await Stack.start(port: 47694)
        defer { stack.stop() }
        let seen = SeenOptions()
        await stack.router.observe {
            if case .settingsSeen(let account, _, let options) = $0 { Task { await seen.add(account, options) } }
        }
        await stack.router.setDefaults(account: "brokered", model: "m2", effort: "high")
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Defaults")
        let result = try await app.request(
            "session/new",
            [
                "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                "_meta": [
                    SessionPolicy.key: ["tools": "app-only", "network": "none", "approval": "never-ask"],
                    "agneta": ["account": "brokered"]
                ]
            ])
        #expect(await stack.engines.configSets == ["model=m2", "effort=high"])
        let current = result["configOptions"]?.arrayValue?.map { $0["currentValue"]?.stringValue ?? "" }
        #expect(current == ["m2", "high"])

        // Nothing the engine doesn't offer, and nothing already current, is set.
        await stack.router.setDefaults(account: "brokered", model: "gone", effort: "low")
        _ = try await stack.session(app, account: "brokered")
        #expect(await stack.engines.configSets == ["model=m2", "effort=high"])

        let probed = try await stack.router.probeSettings(account: "brokered", engine: "goose")
        #expect(probed.arrayValue?.count == 2)
        try await Task.sleep(for: .milliseconds(50))
        let reported = await seen.accounts
        #expect(reported.count >= 3 && reported.allSatisfy { $0 == "brokered" })
        // Reported as the engine set them, before the defaults: Settings names the engine's own choice.
        #expect(await seen.current.first == ["m1", "low"])
    }

    /// While the engine a session needs is downloading, the app hears that, with the progress, instead of that
    /// Agneta lacks the engine; one that downloads but hasn't started is asked for (`engineWanted`); once it's ready,
    /// the session opens. A new catalog that changes what the app may do reaches it as `agneta/accessChanged`.
    @Test func aSessionWaitingOnADownloadSaysSo() async throws {
        let wanted = Wanted()
        let stack = try await Stack.start(port: 47648)
        defer { stack.stop() }
        await stack.router.observe { if case .engineWanted(let engine) = $0 { Task { await wanted.add(engine) } } }
        await stack.router.setCatalog(
            EngineCatalog([
                .init(ready: Self.goose), .init(id: "opencode", name: "OpenCode", state: .downloadable(size: 40))
            ]))
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Patient")
        let asking: [String: JSONValue] = ["agneta": ["account": "brokered", "engine": "opencode"]]
        do {
            _ = try await stack.session(app, account: "brokered", meta: asking)
            Issue.record("a session opened before its engine was downloaded")
        } catch let error as RPCError {
            #expect(
                error.code == -32015
                    && error.data?["agneta"]?["engineDownloading"]?["engine"]?.stringValue == "opencode")
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await wanted.engines == ["opencode"])

        await stack.router.setCatalog(
            EngineCatalog([
                .init(ready: Self.goose),
                .init(id: "opencode", name: "OpenCode", state: .downloading(received: 10, total: 40))
            ]))
        do {
            _ = try await stack.session(app, account: "brokered", meta: asking)
            Issue.record("a session opened while its engine was downloading")
        } catch let error as RPCError {
            #expect(error.code == -32015 && error.data?["agneta"]?["engineDownloading"]?["received"]?.intValue == 10)
        }
        await stack.router.setCatalog(EngineCatalog(ready: [Self.goose, Self.opencode]))
        _ = try await stack.session(app, account: "brokered", meta: asking)
        try await Task.sleep(for: .milliseconds(50))
        let states = app.notifications("agneta/accessChanged").compactMap {
            $0["access"]?["engines"]?.arrayValue?.first { $0["id"]?.stringValue == "opencode" }?["state"]?.stringValue
        }
        #expect(states == ["downloading", "ready"])
    }

    @Test func promptResultsCarryTheTurnsUsage() async throws {
        let stack = try await Stack.start(port: 47442)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Contract")
        let initialize = try await app.request(
            "initialize", ["protocolVersion": 1, "_meta": ["agneta": ["token": .string(app.token ?? "")]]])
        let extensions = Set(initialize["_meta"]?["agneta"]?["extensions"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        #expect(
            extensions.isSuperset(of: [
                "agneta/usage", "agneta/trace", "agneta/steer", "agneta/instructions", "agneta/result"
            ]))

        let session = try await stack.session(app, account: "native")
        let result = try await app.prompt(session, "hello")
        let usage = try #require(result["_meta"]?["agneta/usage"])
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
        let session = try await stack.session(app, account: "brokered", meta: ["agneta/trace": ["live": true]])
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
            let page = try await app.request(
                "agneta/trace/read", ["sessionId": .string(session), "after": .int(after), "limit": 5])
            read += page["records"]?.arrayValue ?? []
            pages += 1
            if page["complete"]?.boolValue == true { break }
            after = try #require(page["next"]?.intValue)
        }
        #expect(pages > 1)
        #expect(read == live)
        // The trace's own delivery isn't recorded in it.
        #expect(
            try !stack.records(session).contains {
                $0["msg"]?["method"]?.stringValue?.hasPrefix("agneta/trace") == true
            })
        // Raw frames on request.
        let raw = try await app.request(
            "agneta/trace/read", ["sessionId": .string(session), "types": ["acp"], "limit": 1000])
        #expect((raw["records"]?.arrayValue ?? []).count > 0)
        // Another app can't read it, nor can anyone escape the folder.
        await #expect(throws: RPCError.self) {
            _ = try await other.request("agneta/trace/read", ["sessionId": .string(session)])
        }
        await #expect(throws: RPCError.self) {
            _ = try await app.request("agneta/trace/read", ["sessionId": "../agneta"])
        }
    }

    @Test func steeringAndInstructionsUseAgnetasOwnMethods() async throws {
        let stack = try await Stack.start(port: 47444)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Contract")
        let session = try await stack.session(app, account: "brokered")

        // Nothing to steer between turns.
        await #expect(throws: RPCError.self) {
            _ = try await app.request(
                "agneta/steer", ["sessionId": .string(session), "prompt": [["type": "text", "text": "x"]]])
        }
        let turn = Task { try await app.prompt(session, "slow") }
        try await Task.sleep(for: .milliseconds(200))
        let steered = try await app.request(
            "agneta/steer", ["sessionId": .string(session), "prompt": [["type": "text", "text": "also fjords"]]])
        #expect(steered["delivery"]?.stringValue == "accepted" && steered["runId"]?.stringValue == "run-7")
        _ = try await turn.value
        let steer = try #require(await stack.engines.steers.first)
        #expect(steer["expectedRunId"]?.stringValue == "run-7")

        _ = try await app.request(
            "agneta/instructions/set", ["sessionId": .string(session), "text": "Be brief.", "mode": "append"])
        #expect(await stack.engines.instructions.last?["text"]?.stringValue == "Be brief.")
        #expect(await stack.engines.instructions.last?["mode"]?.stringValue == "append")
        #expect(await stack.engines.instructions.last?["key"]?.stringValue == "app")
        _ = try await app.request("agneta/instructions/set", ["sessionId": .string(session), "text": "All new."])
        #expect(await stack.engines.instructions.last?["mode"]?.stringValue == "set")

        let records = try stack.records(session)
        let steers = records.filter { $0["event"]?.stringValue == "steer" }.map { $0["delivery"]?.stringValue }
        #expect(steers == ["rejected", "accepted"])
        #expect(
            records.contains {
                $0["type"]?.stringValue == "config" && $0["method"]?.stringValue == "agneta/instructions/set"
            })
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
        let created = try await app.request(
            "session/new",
            [
                "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                "_meta": [
                    SessionPolicy.key: ["tools": "app-only", "approval": "never-ask", "limits": ["maxSeconds": 1]],
                    "agneta": ["account": "brokered"]
                ]
            ])
        let session = try #require(created["sessionId"]?.stringValue)
        let started = ContinuousClock.now
        let result = try await app.prompt(session, "slow")
        #expect(ContinuousClock.now - started < .milliseconds(2_500))
        #expect(result["stopReason"]?.stringValue == "cancelled")
        #expect(result["_meta"]?["agneta/limit"]?["limit"]?.stringValue == "maxSeconds")
        #expect(
            try stack.records(session).contains {
                $0["event"]?.stringValue == "limit" && $0["limit"]?.stringValue == "maxSeconds"
            })
        // The next turn starts clean.
        let next = try await app.prompt(session, "hello")
        #expect(next["_meta"]?["agneta/limit"] == nil)
    }

    /// A limit holds even when the engine ignores the cancel: after the grace the session ends, which stops a
    /// dedicated engine, and the prompt comes back stopped by that limit, marked as having ended the session.
    @Test func aLimitTheEngineIgnoresEndsTheSession() async throws {
        let stack = try await Stack.start(port: 47647, concurrency: .init(limitGrace: .milliseconds(300)))
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Deaf")
        let created = try await app.request(
            "session/new",
            [
                "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                "_meta": [
                    SessionPolicy.key: ["tools": "app-only", "approval": "never-ask", "limits": ["maxSeconds": 1]],
                    "agneta": ["account": "brokered"]
                ]
            ])
        let session = try #require(created["sessionId"]?.stringValue)
        let started = ContinuousClock.now
        let result = try await app.prompt(session, "deaf")
        #expect(ContinuousClock.now - started < .seconds(4))
        #expect(result["stopReason"]?.stringValue == "cancelled")
        #expect(result["_meta"]?["agneta/limit"]?["limit"]?.stringValue == "maxSeconds")
        #expect(result["_meta"]?["agneta/limit"]?["sessionEnded"]?.boolValue == true)
        await #expect(throws: RPCError.self) { _ = try await app.prompt(session, "hello") }
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

        let first = Task { try await app.prompt(a1, "slow") } // runs: brokered 1/1
        try await Task.sleep(for: .milliseconds(150))
        let second = Task { try await app.prompt(a2, "hello") } // waits: brokered is full
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
        _ = try await app.request(
            "agneta/steer", ["sessionId": .string(a1), "prompt": [["type": "text", "text": "finish"]]])
        #expect(try await first.value["stopReason"]?.stringValue == "end_turn")
        #expect(try await third.value["stopReason"]?.stringValue == "end_turn")

        let queued = try stack.records(a2).compactMap { $0["event"]?.stringValue }.filter {
            $0.hasPrefix("queue") || $0 == "dequeued"
        }
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
        #expect(
            try stack.records(session).contains { $0["kind"]?.stringValue == "rate-limited" && $0["resetsAt"] != .null }
        )
    }

    @Test func pausingDuringAnOpeningReplyPreventsPublication() async throws {
        let stack = try await Stack.start(port: 47685)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Pause during open")
        let source = try await stack.session(app, account: "brokered", tools: "workspace")
        _ = try await app.request("session/close", ["sessionId": .string(source)])
        let params: JSONValue = ["sessionId": .string(source), "mcpServers": []]
        await stack.engines.exporting(true)
        await stack.engines.beforeOpeningReply { [weak router = stack.router] in
            await router?.setPaused("brokered", true)
        }
        for method in ["session/new", "session/load", "agneta/fork"] {
            await stack.router.setPaused("brokered", false)
            do {
                if method == "session/new" {
                    _ = try await stack.session(app, account: "brokered")
                } else {
                    _ = try await app.request(method, params)
                }
                Issue.record("\(method) finished opening after Pause")
            } catch let error as RPCError {
                #expect(error.code == -32013)
                #expect(error.data?["agneta"]?["paused"] == "brokered")
            }
            #expect(await stack.router.infos.isEmpty)
            #expect(await stack.router.sessions.isEmpty)
        }
        let opened = await stack.engines.opened
        #expect(await stack.engines.released == opened)
        #expect(await stack.engines.closeRequests == 4) // the original and all three refused sessions
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

        let initialize = try await app.request(
            "initialize", ["protocolVersion": 1, "_meta": ["agneta": ["token": .string(app.token ?? "")]]])
        let listed = initialize["_meta"]?["agneta"]?["access"]?["providers"]?.arrayValue?.first {
            $0["id"]?.stringValue == "brokered"
        }
        #expect(listed?["paused"]?.boolValue == true)
        func expectPaused(_ what: String, _ work: () async throws -> Void) async {
            do {
                try await work()
                Issue.record("\(what) went ahead on a paused account")
            } catch let error as RPCError {
                #expect(
                    error.code == -32013 && error.data?["agneta"]?["paused"]?.stringValue == "brokered",
                    "\(what): \(error.message)")
            } catch {
                Issue.record("\(what): \(error)")
            }
        }
        let cwd = JSONValue.string(stack.root.appending(path: "work").path(percentEncoded: false))
        await expectPaused("the queued turn") { _ = try await queued.value }
        await expectPaused("a new turn") { _ = try await app.prompt(idle, "hello") }
        await expectPaused("a new session") { _ = try await stack.session(app, account: "brokered") }
        await expectPaused("a load") {
            _ = try await app.request("session/load", ["sessionId": .string(closed), "cwd": cwd, "mcpServers": []])
        }
        await expectPaused("a fork") {
            _ = try await app.request("agneta/fork", ["sessionId": .string(closed), "mcpServers": []])
        }
        #expect(try await turn.value["stopReason"]?.stringValue == "end_turn")
        #expect(try stack.records(idle).contains { $0["event"]?.stringValue == "queue-paused" })

        await stack.router.setPaused("brokered", false)
        #expect(try await app.prompt(idle, "hello")["stopReason"]?.stringValue == "end_turn")
        _ = try await stack.session(app, account: "brokered")
    }

    /// A saved task continues on the engine that saved it, in a format that engine still reads. When its provider's
    /// engine changes, it still resumes there; when that engine stores sessions differently now, load and fork are
    /// refused, naming the engine that saved it.
    @Test func aTaskContinuesOnlyOnTheEngineThatSavedIt() async throws {
        let stack = try await Stack.start(port: 47615)
        defer { stack.stop() }
        await stack.router.setCatalog(EngineCatalog(ready: [PlainAdapter(), Self.opencode]))
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Mover")
        let session = try await stack.session(app, account: "brokered")
        _ = try await app.request("session/close", ["sessionId": .string(session)])
        let params: JSONValue = [
            "sessionId": .string(session),
            "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": []
        ]
        // The provider's default is now OpenCode: the task still resumes, on the engine that saved it.
        await stack.router.setCatalog(
            EngineCatalog(
                ready: [PlainAdapter(), Self.opencode], defaults: ProviderEngines(selected: [.openAIKey: "opencode"])))
        #expect(try await app.request("session/load", params)["_meta"]?["agneta"]?["resumed"]?.boolValue == true)
        #expect(await stack.engines.askedEngines.last == "goose")
        _ = try await app.request("session/close", ["sessionId": .string(session)])
        // That engine stores sessions differently now: refused, naming it.
        await stack.router.setCatalog(EngineCatalog(ready: [PlainAdapter(stateFormat: "plain/2"), Self.opencode]))
        for method in ["session/load", "agneta/fork"] {
            do {
                _ = try await app.request(method, params)
                Issue.record("\(method) went ahead on plain/2")
            } catch let error as RPCError {
                #expect(
                    error.code == RPCError.invalidParams
                        && error.data?["agneta"]?["stateChanged"]?["saved"]?.stringValue == "plain/1",
                    "\(method): \(error.message)")
            }
        }
        await stack.router.setCatalog(EngineCatalog(ready: [PlainAdapter(), Self.opencode]))
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
        // The Claude plan ("native") runs on a plain engine standing in for Claude Code; the API key on Goose.
        await stack.router.setCatalog(EngineCatalog(ready: [Self.goose, PlainAdapter(id: "claude-code")]))
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Features")
        let initialize = try await app.request(
            "initialize", ["protocolVersion": 1, "_meta": ["agneta": ["token": .string(app.token ?? "")]]])
        let access = initialize["_meta"]?["agneta"]?["access"]
        let listed = access?["engines"]?.arrayValue?.first { $0["id"]?.stringValue == "claude-code" }
        #expect(
            listed?["capabilities"]?["engine"]?.stringValue == "claude-code"
                && listed?["capabilities"]?["steer"]?.boolValue == false)

        let rich = try await app.request(
            "session/new",
            [
                "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                "_meta": ["agneta": ["account": "brokered"]]
            ])
        #expect(rich["_meta"]?["agneta"]?["capabilities"]?["steer"]?.boolValue == true)
        let plain = try await app.request(
            "session/new",
            [
                "cwd": .string(stack.root.appending(path: "work").path(percentEncoded: false)), "mcpServers": [],
                "_meta": ["agneta": ["account": "native"], "agneta/instructions": ["text": "set at launch"]]
            ])
        let session = try #require(plain["sessionId"]?.stringValue)
        #expect(plain["_meta"]?["agneta"]?["capabilities"]?["fork"]?.boolValue == false)
        for (method, params) in [
            ("agneta/steer", ["prompt": [["type": "text", "text": "x"]]]), ("agneta/instructions/set", ["text": "new"]),
            ("agneta/fork", ["mcpServers": []])
        ] as [(String, JSONValue)] {
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
        for method in [
            "_goose/unstable/session/steer", "_goose/unstable/session/extensions/add", "session/list", "session/fork"
        ] {
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
        _ = try await app.request(
            "agneta/steer", ["sessionId": .string(session), "prompt": [["type": "text", "text": "go on"]]])
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
            _ = try await again.request(
                "initialize",
                [
                    "protocolVersion": 1, "clientCapabilities": [:],
                    "_meta": ["agneta": ["token": .string(try #require(app.token))]]
                ])
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
        await #expect(throws: (any Error).self) {
            _ = try await unpaired.request("session/new", ["cwd": "/tmp", "mcpServers": []])
        } // not paired: refused, still connected
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
            Task {
                await work(); if once.take() { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds)); if once.take() { continuation.resume(returning: false) }
            }
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
        let load = Task {
            try? await app.request("session/load", ["sessionId": .string(session), "cwd": cwd, "mcpServers": []])
        }
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
        _ = try await app.request(
            "agneta/steer", ["sessionId": .string(session), "prompt": [["type": "text", "text": "done"]]])
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
        for _ in 0..<40 where app.notifications("agneta/sessionStopped").isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        let stopped = app.notifications("agneta/sessionStopped")
        #expect(
            stopped.count == 1 && stopped.first?["stoppedBy"]?.stringValue == "engine"
                && stopped.first?["sessionId"]?.stringValue == session)
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
        let stack = try await Stack.start(
            port: 47609,
            approve: { request in
                asked.add(request.id.uuidString)
                try? await Task.sleep(for: .seconds(3600)) // the user never answers
                return nil
            })
        defer { stack.stop() }
        let withdrawn = Recorder()
        await stack.router.observe { event in if case .pairingWithdrawn(let id) = event { withdrawn.add(id.uuidString) }
        }
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
        _ = try await app.request(
            "agneta/steer", ["sessionId": .string(session), "prompt": [["type": "text", "text": "finish"]]])
        #expect(try await first.value["stopReason"]?.stringValue == "end_turn")
        #expect(try await app.prompt(session, "hello")["stopReason"]?.stringValue == "end_turn")
    }

    /// `agneta/appTools` reaches the engine as its own configuration (Claude Code: tool search off, no ToolSearch) and
    /// is reported in the reply; a load or fork that sends none keeps the original's, and a fork's own load keeps the
    /// fork's. Without it nothing changes, and anything but `{"load": "always" | "engine"}` is refused.
    @Test func appToolsLoadUpFrontWhenAsked() async throws {
        let stack = try await Stack.start(port: 47640)
        defer { stack.stop() }
        await stack.engines.exporting(true)
        let claude = ClaudeCodeAdapter(
            executable: URL(filePath: "/usr/bin/false"),
            cli: InstalledCLI(path: URL(filePath: "/usr/bin/false"), version: "2", source: "path"))
        await stack.router.setCatalog(EngineCatalog(ready: [Self.goose, claude]))
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Tools")
        let cwd = JSONValue.string(stack.root.appending(path: "work").path(percentEncoded: false))
        let always: JSONValue = ["load": "always"]
        func open(_ account: String, _ appTools: JSONValue?) async throws -> JSONValue {
            var meta: JSONValue = [
                SessionPolicy.key: ["tools": "app-only", "approval": "never-ask"],
                "agneta": ["account": .string(account)]
            ]
            if let appTools { meta = meta.setting(AppToolsLoad.key, to: appTools) }
            return try await app.request("session/new", ["cwd": cwd, "mcpServers": [], "_meta": meta])
        }
        func lastOptions() async -> JSONValue? {
            await stack.engines.opening.last?.params["_meta"]?["claudeCode"]?["options"]
        }

        // Claude Code's own behaviour unless asked: deferred behind ToolSearch.
        let plain = try await open("native", nil)
        #expect(plain["_meta"]?["agneta"]?["appTools"] == ["load": "engine", "upfront": false])
        var options = await lastOptions()
        #expect(options?["tools"] == ["ToolSearch"] && options?["env"] == nil)

        // Asked for: tool search off, ToolSearch gone, and the same on a load that sends no `_meta`.
        let upfront = try await open("native", always)
        let session = try #require(upfront["sessionId"]?.stringValue)
        #expect(upfront["_meta"]?["agneta"]?["appTools"] == ["load": "always", "upfront": true])
        options = await lastOptions()
        #expect(options?["tools"] == [] && options?["env"] == ["ENABLE_TOOL_SEARCH": "false"])
        _ = try await app.request("session/close", ["sessionId": .string(session)])
        let loaded = try await app.request(
            "session/load", ["sessionId": .string(session), "cwd": cwd, "mcpServers": []])
        #expect(loaded["_meta"]?["agneta"]?["appTools"]?["load"] == "always")
        #expect(await stack.engines.opening.last?.method == "session/load")
        #expect(await lastOptions()?["env"] == ["ENABLE_TOOL_SEARCH": "false"])
        // A load's own `_meta` wins, and an explicit null is the engine's default.
        for value: JSONValue in [["load": "engine"], .null] {
            _ = try await app.request("session/close", ["sessionId": .string(session)])
            let reloaded = try await app.request(
                "session/load",
                ["sessionId": .string(session), "cwd": cwd, "mcpServers": [], "_meta": [AppToolsLoad.key: value]])
            #expect(reloaded["_meta"]?["agneta"]?["appTools"] == ["load": "engine", "upfront": false], "\(value)")
            options = await lastOptions()
            #expect(options?["tools"] == ["ToolSearch"] && options?["env"] == nil, "\(value)")
        }

        // A fork keeps the original's, and so does a later load of the fork; Goose has its tools up front anyway.
        let original = try #require(try await open("brokered", always)["sessionId"]?.stringValue)
        let fork = try await app.request("agneta/fork", ["sessionId": .string(original), "mcpServers": []])
        let forked = try #require(fork["sessionId"]?.stringValue)
        #expect(fork["_meta"]?["agneta"]?["appTools"] == ["load": "always", "upfront": true])
        #expect(await stack.engines.askedPolicies.last?.appTools == .always)
        _ = try await app.request("session/close", ["sessionId": .string(forked)])
        _ = try await app.request("session/load", ["sessionId": .string(forked), "cwd": cwd, "mcpServers": []])
        #expect(await stack.engines.askedPolicies.last?.appTools == .always)
        // Its own `_meta` wins.
        let own = try await app.request(
            "agneta/fork",
            ["sessionId": .string(original), "mcpServers": [], "_meta": [AppToolsLoad.key: ["load": "engine"]]])
        #expect(own["_meta"]?["agneta"]?["appTools"]?["load"] == "engine")

        // Refused on every path, naming the extension.
        for value: JSONValue in ["always", ["load": "sometimes"], ["load": 1], ["load": "always", "defer": false]] {
            for (method, params) in [
                ("session/new", ["cwd": cwd, "mcpServers": [], "_meta": ["agneta": ["account": "native"]]]),
                ("session/load", ["sessionId": .string(session), "cwd": cwd, "mcpServers": []]),
                ("agneta/fork", ["sessionId": .string(original), "mcpServers": []])
            ] as [(String, JSONValue)] {
                _ = try? await app.request("session/close", ["sessionId": .string(session)])
                let sent = params.setting("_meta", to: (params["_meta"] ?? [:]).setting(AppToolsLoad.key, to: value))
                do {
                    _ = try await app.request(method, sent)
                    Issue.record("\(method) took \(value)")
                } catch let error as RPCError {
                    #expect(
                        error.code == RPCError.invalidParams
                            && error.data?["agneta"]?["unenforceable"] == [.string(AppToolsLoad.key)],
                        "\(method) \(value): \(error.message)")
                }
            }
        }
    }

    /// A task's `meta` record is on disk when `session/new` replies, so a fork or load sent at once finds the task
    /// (it was written on the trace's queue, and a slow CI runner answered "Unknown session", 2026-11-21).
    @Test func aNewTasksRecordIsThereWhenItsReplyIs() async throws {
        let stack = try await Stack.start(port: 47731)
        defer { stack.stop() }
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("At once")
        for _ in 0..<5 {
            let session = try await stack.session(app, account: "brokered")
            #expect(stack.traces.meta(task: session) != nil, "no meta record for \(session) when its reply came")
        }
    }

    /// `builtins` in the policy narrow the engine's own tools: Claude Code gets exactly the kept groups' tools, the reply
    /// and the trace say what the session has, and a load or fork keeps the narrowing with the policy. An engine that
    /// can't honour it (Goose without skills, Codex without edit under workspace tools) and an unknown group are refused,
    /// naming the field; without it nothing changes.
    @Test func builtinsNarrowTheEnginesOwnTools() async throws {
        let stack = try await Stack.start(port: 47730)
        defer { stack.stop() }
        let cli = InstalledCLI(path: URL(filePath: "/usr/bin/false"), version: "2", source: "path")
        let claude = ClaudeCodeAdapter(executable: URL(filePath: "/usr/bin/false"), cli: cli)
        let codex = CodexAdapter(node: URL(filePath: "/usr/bin/false"), script: URL(filePath: "/x/index.js"), cli: cli)
        await stack.router.setCatalog(EngineCatalog(ready: [Self.goose, claude, codex]))
        await stack.engines.exporting(true)
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Narrow")
        let cwd = JSONValue.string(stack.root.appending(path: "work").path(percentEncoded: false))
        func open(_ account: String, _ builtins: JSONValue?, engine: String? = nil) async throws -> JSONValue {
            var policy: JSONValue = ["tools": "workspace", "approval": "never-ask", "sandbox": "contained"]
            if let builtins { policy = policy.setting("builtins", to: builtins) }
            var agneta: JSONValue = ["account": .string(account)]
            if let engine { agneta = agneta.setting("engine", to: .string(engine)) }
            return try await app.request(
                "session/new", ["cwd": cwd, "mcpServers": [], "_meta": [SessionPolicy.key: policy, "agneta": agneta]])
        }
        func lastOptions() async -> JSONValue? {
            await stack.engines.opening.last?.params["_meta"]?["claudeCode"]?["options"]
        }
        func refused(_ account: String, _ builtins: JSONValue, engine: String? = nil) async -> RPCError? {
            do {
                _ = try await open(account, builtins, engine: engine)
                return nil
            } catch let error as RPCError { return error } catch { return nil }
        }

        // Without it: Claude Code's contained set, reported.
        let plain = try await open("native", nil)
        #expect(plain["_meta"]?["agneta"]?["builtins"] == ["read", "edit", "execute", "subagents"])
        #expect(await lastOptions()?["tools"]?.arrayValue?.contains("Agent") == true)

        // The clean-room set: no subagents, the same on a load that sends no policy, and in the trace.
        let narrowed = try await open("native", ["read", "edit", "execute"])
        let session = try #require(narrowed["sessionId"]?.stringValue)
        #expect(narrowed["_meta"]?["agneta"]?["builtins"] == ["read", "edit", "execute"])
        #expect(
            await lastOptions()?["tools"]
                == ["Read", "Glob", "Grep", "Edit", "Write", "NotebookEdit", "ToolSearch", "Bash", "TaskStop"])
        #expect(await lastOptions()?["disallowedTools"]?.arrayValue?.contains("Agent") == true)
        let meta = try await stack.meta(session)
        #expect(meta["policy"]?["builtins"] == ["read", "edit", "execute"])
        #expect(meta["policy"]?["builtinsOffered"] == ["read", "edit", "execute"])
        _ = try await app.request("session/close", ["sessionId": .string(session)])
        let loaded = try await app.request(
            "session/load", ["sessionId": .string(session), "cwd": cwd, "mcpServers": []])
        #expect(loaded["_meta"]?["agneta"]?["builtins"] == ["read", "edit", "execute"])
        #expect(await stack.engines.askedPolicies.last?.builtins == [.read, .edit, .execute])
        #expect(await lastOptions()?["tools"]?.arrayValue?.contains("Agent") == false)

        // A fork reads (its policy is the original's with read tools), still narrowed.
        let goose = try #require(try await open("brokered", ["read", "execute", "skills"])["sessionId"]?.stringValue)
        let fork = try await app.request("agneta/fork", ["sessionId": .string(goose), "mcpServers": []])
        #expect(fork["_meta"]?["agneta"]?["builtins"] == ["read", "execute", "skills"])
        #expect(await stack.engines.askedPolicies.last?.builtins == [.read, .execute, .skills])
        #expect(await stack.engines.askedPolicies.last?.tools == .read)

        // Refused where the engine would still offer a tool left out, and for anything but known groups.
        for (account, builtins, engine) in [
            ("brokered", ["read", "edit", "execute"] as JSONValue, nil as String?),
            ("brokered", ["read", "execute"], "codex"), ("native", ["web", "network"], nil), ("native", "read", nil)
        ] {
            let error = await refused(account, builtins, engine: engine)
            #expect(error?.code == RPCError.invalidParams, "\(builtins) on \(engine ?? account)")
            #expect(
                error?.data?["agneta"]?["unenforceable"] == ["builtins"], "\(builtins): \(error?.message ?? "taken")")
        }
        let onCodex = try await open("brokered", ["read", "edit", "execute"], engine: "codex")
        #expect(onCodex["_meta"]?["agneta"]?["builtins"] == ["read", "edit", "execute"])
    }

    /// A fork's engine gets Claude Code's options for the fork's `agneta/appTools`: the original's, or its own.
    @Test func aForkOfAClaudeCodeTaskKeepsItsAppToolsOptions() async throws {
        let stack = try await Stack.start(port: 47642)
        defer { stack.stop() }
        await stack.engines.exporting(true)
        await stack.router.setCatalog(EngineCatalog(ready: [Self.goose, ForkableClaudeCode()]))
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Forks")
        let original = try await stack.session(
            app, account: "native", meta: [AppToolsLoad.key: ["load": "always"]])
        func lastOptions() async -> JSONValue? {
            await stack.engines.opening.last?.params["_meta"]?["claudeCode"]?["options"]
        }
        _ = try await app.request("agneta/fork", ["sessionId": .string(original), "mcpServers": []])
        #expect(await stack.engines.opening.last?.method == "session/load")
        #expect(await lastOptions()?["env"] == ["ENABLE_TOOL_SEARCH": "false"])
        #expect(await lastOptions()?["tools"]?.arrayValue?.contains("ToolSearch") == false)
        _ = try await app.request(
            "agneta/fork",
            ["sessionId": .string(original), "mcpServers": [], "_meta": [AppToolsLoad.key: ["load": "engine"]]])
        #expect(await lastOptions()?["env"] == nil)
        #expect(await lastOptions()?["tools"]?.arrayValue?.contains("ToolSearch") == true)
    }

    /// Modes that stop asking are refused where Agneta gates calls from the questions.
    @Test func modesThatSkipPermissionsAreRefused() async throws {
        let stack = try await Stack.start(port: 47437)
        defer { stack.stop() }
        let claude = ClaudeCodeAdapter(
            executable: URL(filePath: "/usr/bin/false"),
            cli: InstalledCLI(path: URL(filePath: "/usr/bin/false"), version: "2", source: "path"))
        await stack.router.setCatalog(EngineCatalog(ready: [Self.goose, claude]))
        let app = AppClient(port: stack.port)
        defer { app.close() }
        try await app.pairAndInitialize("Modes")
        let session = try await stack.session(app, account: "native")
        for (method, params) in [
            ("session/set_mode", ["modeId": "bypassPermissions"]),
            ("session/set_config_option", ["configId": "mode", "value": "acceptEdits"])
        ] as [(String, JSONValue)] {
            do {
                _ = try await app.request(method, params.setting("sessionId", to: .string(session)))
                Issue.record("\(method) was let through")
            } catch let error as RPCError {
                #expect(
                    error.code == RPCError.invalidParams && error.data?["agneta"]?["unenforceable"] != nil, "\(method)")
            }
        }
        // Model changes and safe modes still reach the engine (the fake one doesn't know them: methodNotFound).
        do {
            _ = try await app.request(
                "session/set_config_option", ["sessionId": .string(session), "configId": "mode", "value": "plan"])
        } catch let error as RPCError {
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
            _ = try await app.request(
                "session/load",
                [
                    "sessionId": .string(session), "cwd": cwd, "mcpServers": [],
                    "_meta": [SessionPolicy.key: ["tools": "workspace", "approval": "never-ask"]]
                ])
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
        #expect(
            records.contains {
                $0["event"]?.stringValue == "stop" && $0["by"]?.stringValue == "app"
                    && $0["reason"]?.stringValue == "disconnected"
            })
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

/// Every check of a shared engine goes through one test of the key, old key shape included.
@Suite struct EngineKeyTests {
    @Test func sharedKeysAreRecognisedInEveryShape() {
        #expect(EngineKeys.shared(account: "acct", engine: "goose") == "acct/shared-goose")
        #expect(
            EngineKeys.isShared("acct/shared-goose") && EngineKeys.isShared("acct/shared-opencode")
                && !EngineKeys.isShared("acct/shared"))
        #expect(
            !EngineKeys.isShared("acct/1f0c-shared") && !EngineKeys.isShared("acct/0e9b2c")
                && !EngineKeys.isShared("shared-acct/abc"))
    }
}

/// Grants the router saves, in order; `revoking` removes the grant while the next one is being saved.
actor SavedGrants {
    private(set) var last: Router.Grant?
    /// The earlier grant the last save removed, if any.
    private(set) var replaced: String?
    private var revoke: (Router, String)?
    func commit(_ hash: String, _ grant: Router.Grant, replacing: String? = nil) async {
        last = grant
        replaced = replacing
        if let (router, id) = revoke {
            revoke = nil
            await router.revoke(grant: id)
        }
    }
    func revoking(_ router: Router, _ id: String) { revoke = (router, id) }
}

/// What the router reported engines offering, by account.
actor SeenOptions {
    private(set) var accounts: [String] = []
    /// Each report's current values, in order.
    private(set) var current: [[String]] = []
    func add(_ account: String, _ options: JSONValue) {
        accounts.append(account)
        current.append(options.arrayValue?.map { $0["currentValue"]?.stringValue ?? "" } ?? [])
    }
}

/// Engines the router asked the host for.
actor Wanted {
    private(set) var engines: [String] = []
    func add(_ engine: String) { engines.append(engine) }
}

/// Pairing answers given in turn.
actor Answers {
    private var answers: [Router.PairingAnswer]
    init(_ answers: [Router.PairingAnswer]) { self.answers = answers }
    func next() -> Router.PairingAnswer? { answers.isEmpty ? nil : answers.removeFirst() }
}
