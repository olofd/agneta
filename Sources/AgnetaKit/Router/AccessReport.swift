// What an app may use, as it sees it: the one shape of `agneta/access`, `initialize`'s `_meta.agneta.access`,
// pairing's result and `agneta/accessChanged` (docs/APP_PROTOCOL.md, Access). Typed, so the router builds it and Swift
// clients and tests read it the same way, and a field can't be misspelled in one of them.
import Foundation

public struct AccessReport: Codable, Sendable, Equatable {
    /// A provider (account) the app may use.
    public struct Provider: Codable, Sendable, Equatable {
        public var id: String
        public var label: String
        /// The kind of provider (`AccountKind`): `chatgpt`, `claude`, `openai-key`, `anthropic-key`.
        public var kind: String
        public var paused: Bool
        public var needsSignIn: Bool
        /// The engines the app's tasks here may run on now or after a download, the default first.
        public var engines: [String]
        public var defaultEngine: String?
    }

    /// An engine the app may use, as it is on this Mac.
    public struct Engine: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// `ready`, `downloading`, `downloadable`, `failed` or `unavailable` (EngineCatalog.State).
        public var state: String
        /// Downloading: bytes so far, and the total when known.
        public var received: Int64?
        public var total: Int64?
        /// Downloadable: its size, when known.
        public var size: Int64?
        /// Failed or unavailable: why.
        public var reason: String?
        /// Ready: what its sessions can do.
        public var capabilities: SessionCapabilities?
    }

    public struct Scope: Codable, Sendable, Equatable {
        public var tools: String
        public var folders: [String]
    }

    public var providers: [Provider]
    public var engines: [Engine]
    public var allowedEngines: EngineAllowance
    public var scope: Scope
    /// The app's own workspace, when Agneta gives apps one.
    public var workspace: String?

    /// As it goes on the wire.
    public var json: JSONValue { (try? JSONCoding.decode(JSONCoding.encode(self))) ?? [:] }

    public init(json: JSONValue) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONCoding.encode(json))
    }

    init(providers: [Provider], engines: [Engine], allowedEngines: EngineAllowance, scope: Scope, workspace: String?) {
        self.providers = providers
        self.engines = engines
        self.allowedEngines = allowedEngines
        self.scope = scope
        self.workspace = workspace
    }
}

/// What a session on an engine can do beyond plain ACP, so the app can offer it (the session result's and the access
/// report's `capabilities`).
public struct SessionCapabilities: Codable, Sendable, Equatable {
    public var engine: String
    public var steer: Bool
    public var fork: Bool
    public var instructionsBetweenTurns: Bool
    public var reportsCost: Bool

    public init(_ engine: any EngineAdapter) {
        let c = engine.capabilities
        self.engine = engine.id
        steer = c.steer
        fork = c.fork
        instructionsBetweenTurns = c.instructionsBetweenTurns
        reportsCost = c.reportsCost
    }
}
