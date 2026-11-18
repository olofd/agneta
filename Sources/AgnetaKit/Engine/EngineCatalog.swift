// The engines this Agneta has and each provider's default engine, as one snapshot. Only the host knows where engines
// come from (the bundle, the user's Claude Code and Codex installs, downloads), so it builds the snapshot whenever any
// of that changes and hands it to the runtime; the router, the supervisor and every window then read the same one, so
// they can't disagree about what can run. What may run where is decided from it by `Access`.
import Foundation

public struct EngineCatalog: Sendable {
    public enum State: Sendable, Equatable {
        case ready
        case downloading(received: Int64, total: Int64?)
        /// Not here yet; it downloads when it's first needed. `size` in bytes, when known.
        case downloadable(size: Int64?)
        /// The last download failed; needing the engine again tries again.
        case failed(String)
        /// Can't run on this Mac now, and why, in words the user can act on ("Install Codex 0.166 or later").
        case unavailable(String)

        /// The state's name, as apps see it.
        public var name: String {
            switch self {
            case .ready: "ready"
            case .downloading: "downloading"
            case .downloadable: "downloadable"
            case .failed: "failed"
            case .unavailable: "unavailable"
            }
        }
    }

    public struct Entry: Sendable {
        public var id: String
        public var name: String
        public var state: State
        /// The engine itself, once it's ready.
        public var adapter: (any EngineAdapter)?

        public init(id: String, name: String, state: State) {
            self.id = id
            self.name = name
            self.state = state
        }

        public init(ready adapter: any EngineAdapter) {
            id = adapter.id
            name = adapter.displayName
            state = .ready
            self.adapter = adapter
        }
    }

    public var entries: [String: Entry]
    /// The default engine the user chose for each kind of provider (Settings → Engines).
    public var defaults: ProviderEngines

    public init(_ entries: [Entry] = [], defaults: ProviderEngines = ProviderEngines()) {
        self.entries = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.defaults = defaults
    }

    /// Engines that are all here.
    public init(ready adapters: [any EngineAdapter], defaults: ProviderEngines = ProviderEngines()) {
        self.init(adapters.map(Entry.init(ready:)), defaults: defaults)
    }

    public func adapter(_ id: String) -> (any EngineAdapter)? { entries[id]?.adapter }

    /// Whether a task can run on the engine now or once it's downloaded.
    public func usable(_ id: String) -> Bool {
        switch entries[id]?.state {
        case .ready?, .downloading?, .downloadable?, .failed?: true
        case .unavailable?, nil: false
        }
    }

    /// The engine a kind of provider runs on by default: the user's choice while it's usable, else the most preferred
    /// usable one; nil when none is (a ChatGPT plan without Codex).
    public func defaultEngine(for kind: AccountKind) -> String? {
        defaults.engine(for: kind, available: Set(entries.keys.filter(usable)))
    }

    /// What an app sees of an engine: its name, its state (with progress, size or reason) and, once it's here, what
    /// its sessions can do.
    func json(_ id: String) -> JSONValue {
        guard let entry = entries[id] else { return ["id": .string(id), "name": .string(id), "state": "unavailable"] }
        var value: [String: JSONValue] = ["id": .string(id), "name": .string(entry.name), "state": .string(entry.state.name)]
        switch entry.state {
        case .downloading(let received, let total):
            value["received"] = .int(received)
            value["total"] = total.map(JSONValue.int) ?? .null
        case .downloadable(let size):
            value["size"] = size.map(JSONValue.int) ?? .null
        case .failed(let reason), .unavailable(let reason):
            value["reason"] = .string(reason)
        case .ready:
            break
        }
        if let adapter = entry.adapter { value["capabilities"] = Router.capabilities(adapter) }
        return .object(value)
    }

    /// What decides what apps can do, without download progress: apps hear `agneta/accessChanged` when it changes.
    var shape: [String: String] {
        var shape = entries.mapValues(\.state.name)
        for kind in AccountKind.allCases { shape["default." + kind.rawValue] = defaultEngine(for: kind) ?? "" }
        return shape
    }
}
