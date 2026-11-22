import Foundation

public struct BufferLimits: Sendable {
    /// Replay is bounded by both count and estimated payload bytes. Exceeding either budget
    /// closes the connection, ending its sessions.
    public var turnEvents = 100_000
    public var turnBytes = 64 * 1024 * 1024
    public var earlySessions = 16
    public var earlyEventsPerSession = 10_000
    public var earlyBytes = 16 * 1024 * 1024
    public init() {}
}
public struct Timeouts: Sendable {
    /// All durations in seconds. Zero disables a deadline.
    public var connect: TimeInterval = 5
    public var request: TimeInterval = 30
    public var pair: TimeInterval = 310
    public var session: TimeInterval = 180
    public var prompt: TimeInterval = 0
    public var open: TimeInterval = 300
    public var download: TimeInterval = 600
    public var downloadPoll: TimeInterval = 2
    public init() {}
}
public struct ReconnectOptions: Sendable {
    public var delay: TimeInterval
    public var maxDelay: TimeInterval
    public init(delay: TimeInterval = 1, maxDelay: TimeInterval = 30) { self.delay = delay; self.maxDelay = maxDelay }
}
@MainActor public struct ClientOptions {
    public var name: String
    public var version = "0.0.0"
    public var build: AgnetaBuild
    public var url: URL?
    public var scope: PairingScope?
    public var tokens: any TokenStore
    public var permissions: PermissionHandler?
    public var reconnect: ReconnectOptions?
    public var minimumVersion: String?
    public var timeouts = Timeouts()
    public var buffers = BufferLimits()
    public var environment: any AgnetaEnvironment
    /// Receives the selected endpoint; must return a fresh transport for each connection.
    public var transport: (@MainActor (URL) -> any WebSocketTransport)?
    public init(name: String, build: AgnetaBuild = .release, tokens: (any TokenStore)? = nil) {
        self.name = name; self.build = build; self.tokens = tokens ?? MemoryTokenStore()
        environment = MacEnvironment()
    }
}
public enum PairMode: Sendable { case ifNeeded, never, always }
@MainActor public struct ConnectOptions {
    public var pair: PairMode = .ifNeeded
    public var scope: PairingScope?
    /// Show the provider window when no provider is connected. `providerKind` narrows it when set.
    public var setup = false
    public var providerKind: String?
    /// The library opens Agneta or its install page only after this guide returns true.
    public var guide: Guide?
    public var onProgress: (@MainActor (ConnectProgress) -> Void)?
    public init(pair: PairMode = .ifNeeded) { self.pair = pair }
}
@MainActor public struct SessionOptions {
    public var cwd: String?
    public var account: String?
    public var engine: String?
    public var policy: Policy?
    public var title: String?
    public var stopWarning: String?
    public var results: ResultDeclaration?
    public var instructions: String?
    public var appTools: AppToolsLoad?
    public var trace = false
    public var traceInclude: [String]?
    public var mcpServers: [HTTPMCPServer] = []
    /// Extra metadata overrides the convenience fields. Unknown keys pass through unchanged.
    public var meta: [String: JSONValue] = [:]
    public var params: [String: JSONValue] = [:]
    public var permissions: PermissionHandler?
    /// Attached before replay, including trace records received while the session opened.
    public var onEvent: (@MainActor (SessionEvent) -> Void)?
    public var waitForDownload = true
    public var onDownloadProgress: (@MainActor (DownloadProgress) -> Void)?
    public var timeout: TimeInterval?
    public init() {}

    func metadata() throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        var agneta: [String: JSONValue] = [:]
        if let account { agneta["account"] = .string(account) }
        if let engine { agneta["engine"] = .string(engine) }
        if !agneta.isEmpty { result["agneta"] = .object(agneta) }
        if let policy { result["agneta/policy"] = try JSONValue(encoding: policy) }
        if title != nil || stopWarning != nil {
            var task: [String: JSONValue] = [:]
            if let title { task["title"] = .string(title) }
            if let stopWarning { task["stopWarning"] = .string(stopWarning) }
            result["agneta/task"] = .object(task)
        }
        if let results { result[resultExtension] = try results.wire() }
        if let instructions { result["agneta/instructions"] = ["text": .string(instructions)] }
        if let appTools { result["agneta/appTools"] = ["load": .string(appTools.rawValue)] }
        if trace {
            var delivery: [String: JSONValue] = ["live": true]
            if let traceInclude { delivery["include"] = .array(traceInclude.map(JSONValue.string)) }
            result["agneta/trace"] = .object(delivery)
        }
        result.merge(meta, uniquingKeysWith: { _, last in last })
        return result
    }
}
