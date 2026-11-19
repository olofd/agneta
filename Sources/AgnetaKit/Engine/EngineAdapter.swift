// The engine boundary. Agneta speaks plain ACP to every engine;
// everything an engine does its own way lives behind one adapter per engine:
// how it starts and what its sandbox must allow, the shape of session/new and
// session/load, how instructions and steering are sent, where a turn's run id
// and a tool's identity are found, how a conversation is exported and imported,
// and where its per-call usage is recorded. Goose and OpenCode each implement it.
import Foundation

/// A request in an engine's own terms.
public struct EngineRequest: Sendable, Equatable {
    public var method: String
    public var params: JSONValue
    public init(_ method: String, _ params: JSONValue) {
        self.method = method
        self.params = params
    }
}

public struct EngineCapabilities: Sendable, Equatable {
    /// Steering adds input to a running turn.
    public var steer: Bool
    /// The engine can export a conversation and import it as a new session (fork).
    public var fork: Bool
    /// Instructions can change between turns.
    public var instructionsBetweenTurns: Bool
    /// The engine's configuration is per process, so every session gets its own, configured at launch.
    public var processPerSession: Bool
    /// Each model call's cost is known, so a cost limit can be enforced.
    public var reportsCost: Bool
    /// The engine runs its built-in tools itself, inside its sandbox, rather than through Agneta's broker: Agneta
    /// checks each call from its permission requests instead (Router.runner).
    public var runsOwnTools: Bool

    public init(steer: Bool, fork: Bool, instructionsBetweenTurns: Bool, processPerSession: Bool, reportsCost: Bool = true, runsOwnTools: Bool = false) {
        self.steer = steer
        self.fork = fork
        self.instructionsBetweenTurns = instructionsBetweenTurns
        self.processPerSession = processPerSession
        self.reportsCost = reportsCost
        self.runsOwnTools = runsOwnTools
    }
}

/// A provider, in Agneta's terms; each adapter maps it onto its engine's own configuration.
public struct ProviderSetup: Sendable {
    public enum Kind: String, Sendable {
        case openAI = "openai", anthropic, chatGPT = "chatgpt", claudeCode = "claude-code"
    }

    public var kind: Kind
    /// The model new sessions start with; nil means the provider's default.
    public var model: String?
    public var apiKey: String?
    /// An OpenAI-compatible endpoint instead of the provider's own (local models, tests).
    public var baseURL: String?
    /// For ChatGPT and Claude plans: where the account's sign-in lives.
    public var subscription: SubscriptionAccount?

    public init(kind: Kind, model: String? = nil, apiKey: String? = nil, baseURL: String? = nil, subscription: SubscriptionAccount? = nil) {
        self.kind = kind
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.subscription = subscription
    }

    /// Secrets in this setup, for masking in traces and logs.
    public var secrets: [String] { [apiKey].compactMap { $0 } }
}

/// What a session brings when its engine is configured at launch (process-per-session engines).
public struct EngineSessionSpec: Sendable {
    public var policy: SessionPolicy
    /// The app's MCP servers, as ACP `mcpServers` entries.
    public var servers: [JSONValue]
    public var instructions: String?
    public init(policy: SessionPolicy, servers: [JSONValue], instructions: String?) {
        self.policy = policy
        self.servers = servers
        self.instructions = instructions
    }
}

/// Everything an adapter needs to start its engine.
public struct EngineLaunchContext: Sendable {
    /// This engine process's home: all of its state lives under it.
    public var home: URL
    public var provider: ProviderSetup
    /// Agneta's shell for built-in shell tools (forwards to the tool broker), when the session may run commands.
    public var shell: URL?
    /// The session, for engines configured per process.
    public var session: EngineSessionSpec?
    /// Loopback ports the engine may reach (the app's tool servers, a local model).
    public var loopbackPorts: [Int]

    public init(home: URL, provider: ProviderSetup, shell: URL?, session: EngineSessionSpec?, loopbackPorts: [Int]) {
        self.home = home
        self.provider = provider
        self.shell = shell
        self.session = session
        self.loopbackPorts = loopbackPorts
    }
}

/// How to start an engine process, and what its sandbox must allow beyond its home.
public struct EngineLaunch: Sendable {
    public var executable: URL
    public var arguments: [String]
    /// The complete environment; nothing else is inherited.
    public var environment: [String: String]
    /// Folders the engine writes besides its home (rotating credentials).
    public var writable: [URL]
    /// Folders the engine reads besides its home (its own binary, runtimes).
    public var readable: [URL]
    /// The engine's state folder, where its sessions and per-call usage are kept.
    public var stateRoot: URL
    /// The engine runs a private server on loopback and must listen there.
    public var ownLoopbackServer = false
    /// Folders the engine may not read or write, and parts of them it may (a session's own share of an account folder).
    public var denied: [URL] = []
    public var exceptions: [URL] = []
    /// Never written, though inside a writable folder: files a shell would read on start (an engine home's dotfiles).
    public var readOnly: [URL] = []
    /// Folders the session's shell commands, run by Agneta's broker, write besides the policy's: an engine's own
    /// bookkeeping that its commands keep (Claude Code's current-folder file and background output).
    public var toolWritable: [URL] = []
    /// Folders made for this engine outside its home (a short temp folder), removed when it ends.
    public var temporary: [URL] = []
}

/// One engine's per-call usage, read from its own records. Rows use these keys: `row`, `created`,
/// `model`, `input_tokens`, `output_tokens`, `total_tokens`, `cache_read_tokens`, `cache_write_tokens`,
/// `cost`, `cost_source`, `is_compaction`, `output_partial` (the output count is the stream's opening one); messages:
/// `row`, `role`, `content`, `meta`, `messageId`, `created`. A row with `session_totals` (per model: `input`, `output`,
/// `cacheRead`, `cacheWrite`, `cost`, running totals for the session) gives the turn's ledger instead of the calls' sums.
public protocol UsageLedger: Sendable {
    /// Rows newer than those already read. `problem` is set once when the records can't be read.
    func read() -> (messages: [[String: JSONValue]], usage: [[String: JSONValue]], problem: String?)
}

extension EngineAdapter {
    public func prepareSession(_ engineSession: String) -> [EngineRequest] { [] }
    public func loadSession(_ engineSession: String, cwd: URL, servers: [JSONValue], policy: SessionPolicy, instructions: String?) -> JSONValue {
        loadSession(engineSession, cwd: cwd, servers: servers, policy: policy)
    }
    public func modelCall(fromNotification method: String, params: JSONValue?) -> [String: JSONValue]? { nil }
    public func permitsMode(_ mode: String) -> Bool { true }
    public var stateFormat: String { "\(id)/1" }
    public func permissionServer(_ params: JSONValue?, calls: [String: String]) -> String? {
        toolIdentity(in: params?["toolCall"] ?? .null).server ?? params?["toolCall"]?["toolCallId"]?.stringValue.flatMap { calls[$0] }
    }
    public var reservedToolServers: Set<String> { [] }
    public func brokersShell(_ policy: SessionPolicy) -> Bool { false }
    public func sessionsDeleted(stateRoot: URL) -> String? { nil }
}

public protocol EngineAdapter: Sendable {
    /// Short and stable: "goose", "opencode".
    var id: String { get }
    /// How the engine keeps its sessions on disk, as this adapter resumes them (default `<id>/1`). Saved with every
    /// task; an adapter changes it when an engine upgrade leaves saved sessions unreadable, so older tasks are
    /// refused instead of resumed wrong.
    var stateFormat: String { get }
    var displayName: String { get }
    var capabilities: EngineCapabilities { get }

    /// Prepares the home (credentials, configuration) and describes the process.
    func launch(_ context: EngineLaunchContext) throws -> EngineLaunch

    /// `session/new` parameters. Engines that take instructions only here (Claude Code) use `instructions`.
    func newSession(cwd: URL, servers: [JSONValue], policy: SessionPolicy, title: JSONValue?, instructions: String?) -> JSONValue
    /// `session/load` parameters, resuming `engineSession`.
    func loadSession(_ engineSession: String, cwd: URL, servers: [JSONValue], policy: SessionPolicy) -> JSONValue
    /// The same, with the session's instructions, for engines that take their options again on every load.
    func loadSession(_ engineSession: String, cwd: URL, servers: [JSONValue], policy: SessionPolicy, instructions: String?) -> JSONValue

    /// Sets a session's instructions (`appendKey` nil: replace them). Nil when the engine can't.
    func setInstructions(_ engineSession: String, text: String, appendKey: String?) -> EngineRequest?
    /// Requests right after a session opens or loads (e.g. selecting the session's agent).
    func prepareSession(_ engineSession: String) -> [EngineRequest]
    /// Adds input to the running turn. `run` is the engine's id for it, when the engine reports one
    /// (`activeRun(in:)`). Nil when the engine can't steer this turn.
    func steer(_ engineSession: String, run: String?, prompt: JSONValue) -> EngineRequest?
    /// Whether the engine took the steering input, and the turn it went to.
    func steerResult(_ result: JSONValue) -> (accepted: Bool, run: String?)
    /// The running turn's id from an update: `.some(id)` while a turn runs, `.some(nil)` when the update
    /// says none runs, nil when the update doesn't say.
    func activeRun(in update: JSONValue) -> String??

    /// The tool behind a tool_call update: its name, its server (as the app named it), the model response.
    func toolIdentity(in update: JSONValue) -> (tool: String?, server: String?, message: String?)

    /// Fork: export a session's conversation, import it as a new session, and read the new id.
    func exportSession(_ engineSession: String) -> EngineRequest?
    func importSession(_ exported: JSONValue) -> EngineRequest?
    func importedSession(_ result: JSONValue) -> String?

    /// The engine's own per-call usage records for a session, under its state root.
    func ledger(stateRoot: URL, engineSession: String) -> (any UsageLedger)?
    /// After the engine deleted sessions (`session/delete`): clears what its storage under the state root still holds
    /// of them. Nil when done, else why not.
    func sessionsDeleted(stateRoot: URL) -> String?
    /// Whether a session may switch to this mode: false for modes that skip permission requests.
    /// The MCP server a permission request's tool belongs to: from the request, or from `calls` (each call's server,
    /// from the engine's earlier updates) when it names only the call. Nil for the engine's own tools. Only what the
    /// adapter itself vouches for counts, never text the model wrote.
    func permissionServer(_ params: JSONValue?, calls: [String: String]) -> String?
    /// MCP server names the engine uses for its own tools. An app's server can't take one: its tools would pass for
    /// the app's.
    var reservedToolServers: Set<String> { get }
    /// Whether this engine's own shell commands run through Agneta's broker under the policy, so a native runner's
    /// `execute` request is for a brokered command (Claude Code's Bash behind its shell prefix).
    func brokersShell(_ policy: SessionPolicy) -> Bool
    func permitsMode(_ mode: String) -> Bool
    /// A model call reported in the stream instead (a notification), as a usage row (keys as `UsageLedger`,
    /// plus `id` to recognize repeats), or nil.
    func modelCall(fromNotification method: String, params: JSONValue?) -> [String: JSONValue]?
}
