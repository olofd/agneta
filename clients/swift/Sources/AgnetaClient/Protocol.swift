import Foundation

public let protocolVersion = 1

public enum AgnetaBuild: String, Sendable, CaseIterable {
    case release, dev
    public var port: Int { self == .release ? 47321 : 47331 }
    public var name: String { self == .release ? "Agneta" : "Agneta Dev" }
    public var openURL: URL { URL(string: self == .release ? "agneta://open" : "agneta-dev://open")! }
    public var bundleIdentifier: String {
        self == .release ? "com.objectivecoder.agneta" : "com.objectivecoder.agneta.dev"
    }
    public var installURL: URL {
        URL(
            string: self == .release
                ? "https://agneta.dahlbom.io/get/" : "https://github.com/olofd/agneta#build-and-run")!
    }
    public var url: URL { URL(string: "ws://127.0.0.1:\(port)/acp")! }
}

public enum ToolsLevel: String, Codable, Sendable { case appOnly = "app-only", read, workspace }
public enum SandboxLevel: String, Codable, Sendable { case contained, developer }
public enum Approval: String, Codable, Sendable { case askApp = "ask-app", neverAsk = "never-ask" }
public enum BuiltinGroup: String, Codable, Sendable { case read, edit, execute, web, subagents, skills, planning }
public enum AppToolsLoad: String, Codable, Sendable { case always, engine }

/// A selection that remains open to future provider and engine identifiers.
public enum AllowedValues: Codable, Sendable, Equatable {
    case all, only([String])
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if (try? value.decode(String.self)) == "all" {
            self = .all
        } else {
            self = .only(try value.decode([String].self))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .all: try value.encode("all");
        case .only(let items): try value.encode(items)
        }
    }
}

public struct PairingScope: Codable, Sendable, Equatable {
    public var tools: ToolsLevel?
    public var folders: [String]?
    public var providers: AllowedValues?
    public var engines: AllowedValues?
    /// `contained`, `developer`, or `any`.
    public var sandbox: String?
    public init(
        tools: ToolsLevel? = nil, folders: [String]? = nil, providers: AllowedValues? = nil,
        engines: AllowedValues? = nil, sandbox: String? = nil
    ) {
        self.tools = tools; self.folders = folders; self.providers = providers; self.engines = engines;
        self.sandbox = sandbox
    }
}

public struct PolicyLimits: Codable, Sendable, Equatable {
    public var maxTurns: Int?
    public var maxSeconds: Double?
    public var maxCostUSD: Double?
    public init(maxTurns: Int? = nil, maxSeconds: Double? = nil, maxCostUSD: Double? = nil) {
        self.maxTurns = maxTurns; self.maxSeconds = maxSeconds; self.maxCostUSD = maxCostUSD
    }
}

/// Agneta validates the policy and refuses anything it cannot enforce; the client never widens it.
public struct Policy: Codable, Sendable, Equatable {
    public var tools: ToolsLevel?
    public var sandbox: SandboxLevel?
    public var network: JSONValue?
    public var approval: Approval?
    public var readable: [String]?
    public var writable: [String]?
    public var readOnly: [String]?
    public var denied: [String]?
    public var toolEnvironment: [String: String]?
    public var toolPorts: [Int]?
    public var toolSockets: [String]?
    public var limits: PolicyLimits?
    public var builtins: [BuiltinGroup]?
    public init(
        tools: ToolsLevel? = nil, sandbox: SandboxLevel? = nil, network: JSONValue? = nil,
        approval: Approval? = nil, readable: [String]? = nil, writable: [String]? = nil,
        readOnly: [String]? = nil, denied: [String]? = nil, toolEnvironment: [String: String]? = nil,
        toolPorts: [Int]? = nil, toolSockets: [String]? = nil, limits: PolicyLimits? = nil,
        builtins: [BuiltinGroup]? = nil
    ) {
        self.tools = tools; self.sandbox = sandbox; self.network = network; self.approval = approval
        self.readable = readable; self.writable = writable; self.readOnly = readOnly; self.denied = denied
        self.toolEnvironment = toolEnvironment; self.toolPorts = toolPorts; self.toolSockets = toolSockets
        self.limits = limits; self.builtins = builtins
    }
}

public struct SessionCapabilities: Codable, Sendable, Equatable {
    public let engine: String
    public let steer: Bool
    public let fork: Bool
    public let instructionsBetweenTurns: Bool
    public let reportsCost: Bool
}
public struct AccessProvider: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let kind: String
    public let paused: Bool
    public let needsSignIn: Bool
    public let engines: [String]
    public let defaultEngine: String?
    public let uncontained: [String]
    public let sandboxLevels: [String: [SandboxLevel]]
    public let uncounted: [String]?
}
public struct AccessEngine: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let state: String
    public let capabilities: SessionCapabilities?
    public let received: Int64?
    public let total: Int64?
    public let size: Int64?
    public let reason: String?
}
public struct AccessScope: Codable, Sendable, Equatable {
    public let tools: ToolsLevel
    public let folders: [String]
    public let sandbox: SandboxLevel
}
public struct AppLimits: Codable, Sendable, Equatable {
    public struct Spend: Codable, Sendable, Equatable {
        public let max: Double
        public let used: Double
        public let currency: String
        public let period: String
        public let resetsAt: String?
        public let whenReached: String
        public let billing: String
        public let counted: [String: String]
        public let uncounted: [String]
    }
    public struct AtOnce: Codable, Sendable, Equatable { public let max: Int; public let running: Int }
    public struct NewTasks: Codable, Sendable, Equatable {
        public let max: Int
        public let used: Int
        public let period: String
        public let resetsAt: String?
        public let whenReached: String
    }
    public let spend: Spend?
    public let atOnce: AtOnce?
    public let newTasks: NewTasks?
}
public struct Access: Codable, Sendable, Equatable {
    public let providers: [AccessProvider]
    public let engines: [AccessEngine]
    public let allowedEngines: AllowedValues
    public let scope: AccessScope
    public let workspace: String?
    public let limits: AppLimits?
}
public struct Catalog: Codable, Sendable, Equatable {
    public struct Provider: Codable, Sendable, Equatable {
        public struct Engine: Codable, Sendable, Equatable {
            public let id: String
            public let sandboxLevels: [SandboxLevel]
            public let uncontained: Bool?
        }
        public let kind: String
        public let name: String
        public let connected: Bool
        public let engines: [Engine]
    }
    public struct Engine: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let state: String
        public let reason: String?
    }
    public let providers: [Provider]
    public let engines: [Engine]
    public let connected: Bool
    public let version: String?
}
public struct UnmetItem: Codable, Sendable, Equatable {
    public let provider: String?
    public let engine: String?
    public let sandbox: SandboxLevel?
    public let reason: String
}
public struct PairResult: Codable, Sendable, Equatable {
    /// A credential. Keep it only when `remembered` is true. Do not log this value.
    public let token: String
    public let remembered: Bool
    public let access: Access
    public let unmet: [UnmetItem]
}
public struct DownloadProgress: Codable, Sendable, Equatable {
    public let engine: String
    public let received: Int64?
    public let total: Int64?
}
public struct AgnetaUsage: Codable, Sendable, Equatable {
    public let modelCalls: Int?
    public let models: [String]
    public let inputTokens: Int64?
    public let outputTokens: Int64?
    public let cacheReadTokens: Int64?
    public let cacheWriteTokens: Int64?
    public let cost: Double?
    public let costKind: String?
    public let taskCost: Double?
    public let billing: String
    public let account: String
    public let ms: Double?
    public let msToFirstToken: Double?
    public let basis: String
    public let app: JSONValue?
}
public struct LimitHit: Codable, Sendable, Equatable {
    public let limit: String
    public let value: Double
    public let setBy: String?
    public let period: String?
    public let resetsAt: String?
    public let sessionEnded: Bool?
}
public struct TraceRecord: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) throws {
        try requireObject(raw)
        guard raw["seq"]?.integer != nil else {
            throw AgnetaError(.protocolViolation, "Trace record has no integer sequence.")
        }
        self.raw = raw
    }
    public var seq: Int64 { raw["seq"]!.integer! }
    public var type: String? { raw["type"]?.string }
    public var task: String? { raw["task"]?.string }
}
public struct TracePage: Codable, Sendable, Equatable {
    public let records: [TraceRecord]
    public let next: Int64?
    public let complete: Bool
}

public struct ProviderChoice: Sendable, Equatable {
    public let provider: AccessProvider
    public let engine: AccessEngine?
    public let engineID: String
    public var account: String { provider.id }
}
/// The first available provider/engine that meets these constraints. Downloadable engines remain eligible.
public func chooseProvider(
    _ access: Access?, kind: String? = nil, account: String? = nil,
    engine: String? = nil, sandbox: SandboxLevel? = nil
) -> ProviderChoice? {
    guard let access else { return nil }
    for provider in access.providers where !provider.paused && !provider.needsSignIn {
        if let kind, provider.kind != kind { continue }
        if let account, provider.id != account { continue }
        // Honour the explicit default even if an older host does not put it first.
        let ids = provider.engines.sorted { $0 == provider.defaultEngine && $1 != provider.defaultEngine }
        for id in ids {
            if let engine, id != engine { continue }
            let info = access.engines.first { $0.id == id }
            if info?.state == "failed" || info?.state == "unavailable" { continue }
            if let sandbox, let levels = provider.sandboxLevels[id], !levels.contains(sandbox) { continue }
            return ProviderChoice(provider: provider, engine: info, engineID: id)
        }
    }
    return nil
}
