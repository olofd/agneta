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

    /// The engine a kind of provider runs on by default (`pick` among the engines it supports).
    public func defaultEngine(for kind: AccountKind) -> String? {
        pick(ProviderEngines.supported(by: kind), preferring: defaults.selected[kind])
    }

    /// The engine to run on among `candidates` (most preferred first): `preferred` when it's usable, else the first
    /// usable one, but never a failed download while another engine is ready or on its way: a default whose download
    /// failed (offline, say) leaves tasks running on another rather than waiting. With nothing else, the failed one,
    /// which a task's asking downloads again. Nil when none is usable (a ChatGPT plan without Codex).
    public func pick(_ candidates: [String], preferring preferred: String?) -> String? {
        let choices = ((preferred.map { [$0] } ?? []) + candidates).filter { candidates.contains($0) && usable($0) }
        return choices.first { if case .failed? = entries[$0]?.state { false } else { true } } ?? choices.first
    }

    /// What an app sees of an engine: its name, its state (with progress, size or reason) and, once it's here, what
    /// its sessions can do.
    func report(_ id: String) -> AccessReport.Engine {
        guard let entry = entries[id] else { return AccessReport.Engine(id: id, name: id, state: "unavailable") }
        var engine = AccessReport.Engine(
            id: id, name: entry.name, state: entry.state.name, capabilities: entry.adapter.map(SessionCapabilities.init)
        )
        switch entry.state {
        case .downloading(let received, let total): (engine.received, engine.total) = (received, total)
        case .downloadable(let size): engine.size = size
        case .failed(let reason), .unavailable(let reason): engine.reason = reason
        case .ready: break
        }
        return engine
    }

    /// What decides what apps can do, without download progress: apps hear `agneta/accessChanged` when it changes.
    var shape: [String: String] {
        var shape = entries.mapValues(\.state.name)
        for kind in AccountKind.allCases { shape["default." + kind.rawValue] = defaultEngine(for: kind) ?? "" }
        return shape
    }
}
