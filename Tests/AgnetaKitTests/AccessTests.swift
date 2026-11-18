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

    /// Each provider's default: the user's choice while its provider supports it and it's here, else the most
    /// preferred one that is; nil for a ChatGPT plan without Codex.
    @Test func eachProviderDefaultsToASupportedEngineThatsHere() {
        let all = Self.catalog(["goose": .ready, "opencode": .ready, "claude-code": .ready, "codex": .ready],
                               selected: [.openAIKey: "opencode", .claude: "opencode"])
        #expect(all.defaultEngine(for: .chatGPT) == "codex")
        #expect(all.defaultEngine(for: .claude) == "claude-code") // OpenCode can't serve a Claude plan: ignored
        #expect(all.defaultEngine(for: .openAIKey) == "opencode")
        let gooseOnly = Self.catalog(["goose": .ready], selected: [.openAIKey: "opencode"])
        #expect(gooseOnly.defaultEngine(for: .openAIKey) == "goose") // chosen but not here: the next one
        #expect(gooseOnly.defaultEngine(for: .claude) == "goose")
        #expect(gooseOnly.defaultEngine(for: .chatGPT) == nil) // a ChatGPT plan needs Codex
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
    @Test func allowancesRoundTrip() throws {
        #expect(EngineAllowance.all.allows("future-engine"))
        func coded(_ allowance: EngineAllowance) throws -> String { String(decoding: try JSONCoding.encode(allowance), as: UTF8.self) }
        #expect(try coded(.all) == "\"all\"" && coded(.only(["goose", "codex"])) == #"["codex","goose"]"#)
        for allowance in [EngineAllowance.all, .only(["goose", "codex"]), .only([])] {
            #expect(try JSONDecoder().decode(EngineAllowance.self, from: JSONCoding.encode(allowance)) == allowance)
        }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EngineAllowance.self, from: Data("\"some\"".utf8)) }
    }

    /// The table and the adapters agree: every pair ProviderEngines allows starts, and every other pair is refused by
    /// the adapter itself, so a change to one can't leave the other behind.
    @Test func theTableIsWhatTheAdaptersAccept() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agneta-pairs-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let none = Self.none
        let adapters: [any EngineAdapter] = [GooseAdapter(executable: none), OpenCodeAdapter(executable: none),
                                             ClaudeCodeAdapter(executable: none, cli: InstalledCLI(path: none, version: "2.1.0", source: "path")),
                                             CodexAdapter(node: none, script: none, cli: InstalledCLI(path: none, version: "0.166.0", source: "path"))]
        #expect(Set(adapters.map(\.id)) == Set(AccountKind.allCases.flatMap(ProviderEngines.supported(by:))))
        for kind in AccountKind.allCases {
            let home = root.appending(path: kind.rawValue, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let provider = switch kind {
            case .chatGPT: ProviderSetup(kind: .chatGPT, subscription: SubscriptionAccount(route: .chatGPT, home: home))
            case .claude: ProviderSetup(kind: .claudeCode, subscription: SubscriptionAccount(route: .claudeCode, home: home, adapter: none, claudeCode: none))
            case .openAIKey: ProviderSetup(kind: .openAI, apiKey: "k")
            case .anthropicKey: ProviderSetup(kind: .anthropic, apiKey: "k")
            }
            for adapter in adapters {
                let engineHome = home.appending(path: adapter.id, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: engineHome, withIntermediateDirectories: true)
                let context = EngineLaunchContext(home: engineHome, provider: provider, shell: nil, session: nil, loopbackPorts: [])
                let starts = (try? adapter.launch(context)) != nil
                #expect(starts == ProviderEngines.supported(by: kind).contains(adapter.id), "\(kind.rawValue) on \(adapter.id)")
            }
        }
    }
}
