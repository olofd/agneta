// What an app may run where. A grant names the providers (accounts) and the engines an app may use, as two lists the
// user ticks; a task runs on a pair from them that its provider supports (ProviderEngines) and this Mac can run
// (EngineCatalog). The app picks the pair; everything that answers "may this run here" (session/new, initialize,
// agneta/access, the approval window, Settings) asks this.
import Foundation

/// The engines a grant allows: all of them (including ones Agneta adds later), or only these.
public enum EngineAllowance: Sendable, Equatable, Hashable {
    case all
    case only(Set<String>)

    public func allows(_ engine: String) -> Bool {
        switch self {
        case .all: true
        case .only(let engines): engines.contains(engine)
        }
    }

    /// As saved and as apps see it: `"all"`, or the engine ids, sorted.
    public var json: JSONValue {
        switch self {
        case .all: "all"
        case .only(let engines): .array(engines.sorted().map(JSONValue.string))
        }
    }

    public init(json: JSONValue?) {
        if let list = json?.arrayValue { self = .only(Set(list.compactMap(\.stringValue))) } else { self = .all }
    }
}

public enum Access {
    /// Why a task can't run on the engine it asked for.
    public enum Refusal: Error, Sendable, Equatable {
        /// The provider can't run on it (ProviderEngines).
        case unsupported(String)
        /// The user didn't allow the app this engine.
        case notAllowed(String)
        /// This Mac can't run it now.
        case unavailable(String)
        /// The provider has no engine the app may use here.
        case noEngine
    }

    /// The engines an app's tasks on a provider may run on: those the provider supports, the grant allows and this Mac
    /// can run now or after a download. The default first.
    public static func engines(for kind: AccountKind, allowed: EngineAllowance, catalog: EngineCatalog) -> [String] {
        let usable = ProviderEngines.supported(by: kind).filter { allowed.allows($0) && catalog.usable($0) }
        guard let first = defaultEngine(among: usable, kind: kind, catalog: catalog) else { return usable }
        return [first] + usable.filter { $0 != first }
    }

    /// The engine a task on a provider runs on when it doesn't ask: the provider's default when the app may use it,
    /// else the most preferred one it may.
    public static func defaultEngine(for kind: AccountKind, allowed: EngineAllowance, catalog: EngineCatalog) -> String? {
        defaultEngine(among: ProviderEngines.supported(by: kind).filter { allowed.allows($0) && catalog.usable($0) }, kind: kind, catalog: catalog)
    }

    private static func defaultEngine(among usable: [String], kind: AccountKind, catalog: EngineCatalog) -> String? {
        if let chosen = catalog.defaultEngine(for: kind), usable.contains(chosen) { return chosen }
        return usable.first
    }

    /// The engine a new task runs on: the one it asks for, checked, or the default.
    public static func engine(for kind: AccountKind, requested: String?, allowed: EngineAllowance, catalog: EngineCatalog) -> Result<String, Refusal> {
        guard let requested else {
            guard let engine = defaultEngine(for: kind, allowed: allowed, catalog: catalog) else { return .failure(.noEngine) }
            return .success(engine)
        }
        guard ProviderEngines.supported(by: kind).contains(requested) else { return .failure(.unsupported(requested)) }
        guard allowed.allows(requested) else { return .failure(.notAllowed(requested)) }
        guard catalog.usable(requested) else { return .failure(.unavailable(requested)) }
        return .success(requested)
    }
}
