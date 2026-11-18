import Foundation
import Testing
@testable import AgnetaKit

/// What may run where (Access) and which engine a provider runs on by default (EngineCatalog.pick), on their own.
@Suite struct AccessTests {
    static let none = URL(filePath: "/usr/bin/false")
    static func catalog(_ states: [String: EngineCatalog.State], selected: [AccountKind: String] = [:]) -> EngineCatalog {
        EngineCatalog(states.map { EngineCatalog.Entry(id: $0.key, name: $0.key, state: $0.value) }, defaults: ProviderEngines(selected: selected))
    }

    /// The chosen default while it can run or is on its way; a failed download falls back to one that's ready, and is
    /// used only when nothing else can run (asking for it then downloads it again).
    @Test func aFailedDefaultFallsBackWhileAnotherCanRun() {
        let failed = Self.catalog(["goose": .ready, "opencode": .failed("offline")], selected: [.openAIKey: "opencode"])
        #expect(failed.defaultEngine(for: .openAIKey) == "goose")
        let downloading = Self.catalog(["goose": .ready, "opencode": .downloading(received: 1, total: 2)], selected: [.openAIKey: "opencode"])
        #expect(downloading.defaultEngine(for: .openAIKey) == "opencode")
        let only = Self.catalog(["codex": .failed("offline")])
        #expect(only.defaultEngine(for: .chatGPT) == "codex")
        #expect(Self.catalog(["codex": .unavailable("Install Codex")]).defaultEngine(for: .chatGPT) == nil)
        // Without a choice, the most preferred one that can run, skipping a failed one.
        #expect(Self.catalog(["goose": .failed("x"), "opencode": .ready]).defaultEngine(for: .openAIKey) == "opencode")
    }

    /// A provider's engines for an app: what it supports, the grant allows and this Mac can run, the default first.
    @Test func aProvidersEnginesAreWhatAllThreeAllow() {
        let catalog = Self.catalog(["goose": .ready, "opencode": .downloadable(size: 1), "codex": .unavailable("Install Codex"), "claude-code": .ready],
                                   selected: [.openAIKey: "opencode"])
        #expect(Access.engines(for: .openAIKey, allowed: .all, catalog: catalog) == ["opencode", "goose"])
        #expect(Access.engines(for: .openAIKey, allowed: .only(["goose", "claude-code"]), catalog: catalog) == ["goose"])
        #expect(Access.engines(for: .chatGPT, allowed: .all, catalog: catalog).isEmpty)
        #expect(Access.defaultEngine(for: .openAIKey, allowed: .only(["goose"]), catalog: catalog) == "goose")
    }

    /// Asking for an engine: refused for what the provider can't run, the grant doesn't allow, or this Mac lacks.
    @Test func askingIsCheckedInOrder() {
        let catalog = Self.catalog(["goose": .ready, "opencode": .ready, "codex": .unavailable("Install Codex")])
        #expect(Access.engine(for: .openAIKey, requested: "opencode", allowed: .all, catalog: catalog) == .success("opencode"))
        #expect(Access.engine(for: .chatGPT, requested: "goose", allowed: .all, catalog: catalog) == .failure(.unsupported("goose")))
        #expect(Access.engine(for: .openAIKey, requested: "opencode", allowed: .only(["goose"]), catalog: catalog) == .failure(.notAllowed("opencode")))
        #expect(Access.engine(for: .openAIKey, requested: "codex", allowed: .all, catalog: catalog) == .failure(.unavailable("codex")))
        #expect(Access.engine(for: .chatGPT, requested: nil, allowed: .all, catalog: catalog) == .failure(.noEngine))
    }

    /// "all" includes engines added later; a list is saved sorted and read back as given.
    @Test func allowancesRoundTrip() {
        #expect(EngineAllowance.all.allows("future-engine"))
        #expect(EngineAllowance(json: EngineAllowance.only(["goose", "codex"]).json) == .only(["codex", "goose"]))
        #expect(EngineAllowance(json: "all") == .all)
        #expect(EngineAllowance.only(["goose", "codex"]).json == ["codex", "goose"])
    }
}
