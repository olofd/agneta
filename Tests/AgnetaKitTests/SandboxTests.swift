// The sandbox rules, case by case, as the maintainer set them (2026-11-19): full power unless the user asks for less;
// an app may ask for a more restrictive sandbox than the user chose, never a less restrictive one; an engine that can't
// contain its tools is never hidden, but a restriction it can't honour is refused with the reason. The table is written
// out by hand from those rules, not derived from the code under test.
import Foundation
import Testing

@testable import AgnetaKit

@Suite struct SandboxTests {
    typealias Row = (
        requested: Sandbox?, ceiling: Sandbox, levels: [Sandbox], tools: SessionPolicy.Tools,
        expect: (profile: Sandbox, effective: Sandbox)?
    )
    static let both: [Sandbox] = [.contained, .developer]
    static let uncontained: [Sandbox] = [.developer]

    static let rows: [Row] = [
        // The user's default (developer access) and an app that doesn't ask: full power, for workspace tools.
        (nil, .developer, both, .workspace, (.developer, .developer)),
        // An app that asked for fewer tools than workspace runs contained: developer access is a terminal's commands.
        (nil, .developer, both, .read, (.contained, .contained)),
        (nil, .developer, both, .appOnly, (.contained, .contained)),
        // An app may ask for less than the user chose.
        (.contained, .developer, both, .workspace, (.contained, .contained)),
        (.developer, .developer, both, .workspace, (.developer, .developer)),
        // The user chose Contained: the app gets it, and can't ask for more.
        (nil, .contained, both, .workspace, (.contained, .contained)),
        (.contained, .contained, both, .workspace, (.contained, .contained)),
        (.developer, .contained, both, .workspace, nil),
        // An engine that can't contain its tools (Goose on a Claude plan): full power when nobody asked for less…
        (nil, .developer, uncontained, .workspace, (.developer, .developer)),
        (nil, .developer, uncontained, .read, (.contained, .developer)),
        (nil, .developer, uncontained, .appOnly, (.contained, .developer)),
        (.developer, .developer, uncontained, .workspace, (.developer, .developer)),
        // …and refused when anyone did: the app, or the user.
        (.contained, .developer, uncontained, .workspace, nil),
        (.contained, .developer, uncontained, .read, nil),
        (nil, .contained, uncontained, .workspace, nil),
        (nil, .contained, uncontained, .appOnly, nil),
        (.developer, .contained, uncontained, .workspace, nil)
    ]

    @Test func everyCombinationResolvesByTheRules() {
        for row in Self.rows {
            let got = SandboxResolution.resolve(
                requested: row.requested, ceiling: row.ceiling, levels: row.levels, tools: row.tools,
                provider: "Claude", why: "it can't")
            let label =
                "asked \(row.requested?.rawValue ?? "nothing"), user \(row.ceiling.rawValue), engine \(row.levels.map(\.rawValue)), tools \(row.tools.rawValue)"
            switch (got, row.expect) {
            case (.success(let outcome), let expect?):
                #expect(
                    outcome.profile == expect.profile && outcome.effective == expect.effective, "\(label): \(outcome)")
            case (.failure(let refusal), nil):
                #expect(refusal.field == "sandbox", "\(label)")
            case (.success(let outcome), nil): Issue.record("\(label): expected a refusal, got \(outcome)")
            case (.failure(let refusal), _?):
                Issue.record("\(label): expected a sandbox, got refused: \(refusal.reason)")
            }
        }
    }

    /// A refusal says why, in words an app can show: the user's choice, or what the engine can't do.
    @Test func refusalsSayWhy() {
        guard
            case .failure(let ceiling) = SandboxResolution.resolve(
                requested: .developer, ceiling: .contained, levels: Self.both, tools: .workspace,
                provider: "Claude", why: nil)
        else { Issue.record("not refused"); return }
        #expect(ceiling.reason.contains("Settings → Apps") && ceiling.reason.contains("less, not more"))
        guard
            case .failure(let engine) = SandboxResolution.resolve(
                requested: .contained, ceiling: .developer, levels: Self.uncontained, tools: .workspace,
                provider: "Claude", why: ProviderEngines.uncontainedReason("goose", for: .claude))
        else { Issue.record("not refused"); return }
        #expect(engine.reason.contains("Goose") && engine.reason.contains("choose another engine"))
    }

    /// Full power is a grant's default; each engine provides both levels except Goose on a Claude plan.
    @Test func theDefaultsAndWhatEachEngineProvides() {
        #expect(Sandbox.default == .developer && Router.Grant(app: "A", accounts: []).sandbox == .developer)
        #expect(Router.PairingAnswer(accounts: [], remember: true).sandbox == .developer)
        for kind in AccountKind.allCases {
            for engine in ProviderEngines.supported(by: kind) {
                let levels = ProviderEngines.sandboxLevels(engine, for: kind)
                if kind == .claude, engine == "goose" {
                    #expect(levels == [.developer] && ProviderEngines.uncontainedReason(engine, for: kind) != nil)
                } else {
                    #expect(
                        levels == Sandbox.allCases && ProviderEngines.uncontainedReason(engine, for: kind) == nil,
                        "\(engine) on \(kind)")
                }
            }
        }
        #expect(Sandbox.contained < Sandbox.developer)
    }

    /// The policy's `sandbox` field: the two levels by name, developer only with workspace tools, nothing else; the
    /// old `access` field is gone and refused like any unknown field.
    @Test func thePolicyFieldParsesStrictly() throws {
        let context = PolicyContext(
            userHome: FileManager.default.homeDirectoryForCurrentUser, agnetaRoots: [URL(filePath: "/tmp/agneta-none")])
        let cwd = FileManager.default.temporaryDirectory.path(percentEncoded: false)
        #expect(try SessionPolicy.parse(["tools": "workspace"], cwd: cwd, context: context).requestedSandbox == nil)
        #expect(
            try SessionPolicy.parse(["sandbox": "contained"], cwd: cwd, context: context).requestedSandbox == .contained
        )
        #expect(
            try SessionPolicy.parse(["tools": "workspace", "sandbox": "developer"], cwd: cwd, context: context)
                .requestedSandbox == .developer)
        #expect(
            try SessionPolicy.parse(["tools": "read", "sandbox": "contained"], cwd: cwd, context: context)
                .requestedSandbox == .contained)
        for bad: JSONValue in [
            ["tools": "read", "sandbox": "developer"], ["sandbox": "standard"], ["sandbox": 1], ["access": "developer"]
        ] {
            #expect(throws: PolicyRejection.self, "\(bad)") { try SessionPolicy.parse(bad, cwd: cwd, context: context) }
        }
    }
}
