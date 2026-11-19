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
        /// Engines here whose own tools Agneta's policy doesn't confine (ProviderEngines.uncontained): a session on one
        /// has the engine's full tool set whatever its policy says.
        public var uncontained: [String]
        /// The sandbox levels each engine here can provide (Sandbox): one that can't contain its tools provides
        /// `developer` only.
        public var sandboxLevels: [String: [String]]
        /// Engines the grant allows here that can't run while the app's spending limit counts this provider: they
        /// report no cost (Codex on an OpenAI key). Absent when there are none.
        public var uncounted: [String]?
    }

    /// The limits the user set for the app (AppLimits), and where it stands: absent when there are none.
    public struct Limits: Codable, Sendable, Equatable {
        public struct Spend: Codable, Sendable, Equatable {
            public var max: Double
            public var currency: String
            public var period: String
            public var whenReached: String
            /// Spent in this period, the running turns' cost so far included.
            public var used: Double
            public var resetsAt: String?
            /// What it counts: tasks on accounts with this billing (API keys), never a plan's.
            public var billing: String
            /// The engines it counts, by when their cost is known: `live` or `turn-end`.
            public var counted: [String: String]
            /// The engines it can't count, which the app's tasks on API keys can't use while it's set.
            public var uncounted: [String]
        }
        public struct AtOnce: Codable, Sendable, Equatable {
            public var max: Int
            public var running: Int
        }
        public struct NewTasks: Codable, Sendable, Equatable {
            public var max: Int
            public var period: String
            public var whenReached: String
            public var used: Int
            public var resetsAt: String?
        }
        public var spend: Spend?
        public var atOnce: AtOnce?
        public var newTasks: NewTasks?
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
        /// The most the app's tasks may do: `developer` (the default) or `contained`, as the user chose for it.
        public var sandbox: String
    }

    public var providers: [Provider]
    public var engines: [Engine]
    public var allowedEngines: EngineAllowance
    public var scope: Scope
    /// The app's own workspace, when Agneta gives apps one.
    public var workspace: String?
    /// The limits the user set for the app, when there are any.
    public var limits: Limits?

    /// As it goes on the wire.
    public var json: JSONValue { (try? JSONCoding.decode(JSONCoding.encode(self))) ?? [:] }

    public init(json: JSONValue) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONCoding.encode(json))
    }

    init(providers: [Provider], engines: [Engine], allowedEngines: EngineAllowance, scope: Scope, workspace: String?, limits: Limits? = nil) {
        self.providers = providers
        self.engines = engines
        self.allowedEngines = allowedEngines
        self.scope = scope
        self.workspace = workspace
        self.limits = limits
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
