// What an app may run where. A grant names the providers (accounts) and the engines an app may use, as two lists the
// user ticks; a task runs on a pair from them that its provider supports (ProviderEngines) and this Mac can run
// (EngineCatalog). The app picks the pair; everything that answers "may this run here" (session/new, initialize,
// agneta/access, the approval window, Settings) asks this.
import Foundation

/// The engines a grant allows: all of them (including ones Agneta adds later), or only these. Saved and sent as
/// `"all"`, or the engine ids, sorted.
public enum EngineAllowance: Sendable, Equatable, Hashable, Codable {
    case all
    case only(Set<String>)

    public func allows(_ engine: String) -> Bool {
        switch self {
        case .all: true
        case .only(let engines): engines.contains(engine)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .all: try container.encode("all")
        case .only(let engines): try container.encode(engines.sorted())
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let engines = try? container.decode([String].self) { self = .only(Set(engines)) } else {
            guard try container.decode(String.self) == "all" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Engines are \"all\" or a list of engine ids")
            }
            self = .all
        }
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
        /// The engine reports no cost, so the spending limit the user set for the app can't count it there.
        case uncounted(String)
    }

    /// The engines an app's tasks on a provider may run on: those the provider supports, the grant allows and this Mac
    /// can run now or after a download. The default first.
    public static func engines(for kind: AccountKind, allowed: EngineAllowance, catalog: EngineCatalog) -> [String] {
        let usable = ProviderEngines.supported(by: kind).filter { allowed.allows($0) && catalog.usable($0) }
        guard let first = defaultEngine(for: kind, allowed: allowed, catalog: catalog, sandbox: nil) else { return usable }
        return [first] + usable.filter { $0 != first }
    }

    /// The engine a task on a provider runs on when it doesn't ask: the provider's default when the app may use it,
    /// else the most preferred one it may (EngineCatalog.pick: a failed download only when nothing else can run). Given
    /// the sandbox the task wants, among engines that can provide it, when the app may use any: a Claude plan whose
    /// default is Goose runs a contained task on Claude Code rather than refusing it.
    public static func defaultEngine(for kind: AccountKind, allowed: EngineAllowance, catalog: EngineCatalog, sandbox: Sandbox? = nil) -> String? {
        let candidates = ProviderEngines.supported(by: kind).filter(allowed.allows)
        let capable = sandbox.map { level in candidates.filter { ProviderEngines.sandboxLevels($0, for: kind).contains(level) } } ?? candidates
        let preferred = catalog.defaults.selected[kind]
        return catalog.pick(capable.isEmpty ? candidates : capable,
                            preferring: preferred.flatMap { capable.isEmpty || capable.contains($0) ? $0 : nil })
            ?? catalog.pick(candidates, preferring: preferred)
    }

    /// The engine a new task runs on: the one it asks for, checked, or the default.
    public static func engine(for kind: AccountKind, requested: String?, allowed: EngineAllowance, catalog: EngineCatalog,
                              sandbox: Sandbox? = nil) -> Result<String, Refusal> {
        guard let requested else {
            guard let engine = defaultEngine(for: kind, allowed: allowed, catalog: catalog, sandbox: sandbox) else { return .failure(.noEngine) }
            return .success(engine)
        }
        guard ProviderEngines.supported(by: kind).contains(requested) else { return .failure(.unsupported(requested)) }
        guard allowed.allows(requested) else { return .failure(.notAllowed(requested)) }
        guard catalog.usable(requested) else { return .failure(.unavailable(requested)) }
        return .success(requested)
    }
}
