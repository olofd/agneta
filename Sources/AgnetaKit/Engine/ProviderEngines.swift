// Which engines can serve which kind of provider (an account's kind), a fixed table, what each can provide there
// (Sandbox levels), and the default the user chose for each kind in Settings → Engines. Accounts name no engine; an app picks one per task among what its grant
// allows (Access), and a task that names none runs on its provider's default.
import Foundation

public struct ProviderEngines: Sendable, Equatable {
    /// The engines that can serve each kind of provider, most preferred first.
    /// - A ChatGPT plan's sign-in is Codex's own, so only Codex can use it.
    /// - A Claude plan's sign-in is Claude Code's own: Claude Code runs it, and so can Goose, through that same Claude Code.
    /// - An API key works with any engine that speaks to its provider; Goose, built in, comes first.
    public static func supported(by kind: AccountKind) -> [String] {
        switch kind {
        case .chatGPT: ["codex"]
        case .claude: ["claude-code", "goose"]
        case .openAIKey: ["goose", "opencode", "codex"]
        case .anthropicKey: ["goose", "opencode", "claude-code"]
        }
    }

    /// Engines that serve a kind of provider without Agneta's policy confining their own tools, said plainly wherever
    /// engines are chosen (Settings, the access report) rather than removed: Goose on a Claude plan runs Claude Code as
    /// its model, and that Claude Code uses all its own tools and the claude.ai account's connectors, as in a terminal
    /// (measured on 2.1.325). Agneta's sandbox still holds the engine process (files outside the session's folders);
    /// the policy's tool, network and approval rules don't reach that Claude Code's tools.
    public static func uncontained(by kind: AccountKind) -> Set<String> {
        kind == .claude ? ["goose"] : []
    }

    /// When each engine's cost is known (its adapter's `capabilities.cost`), for choosing engines before one is on this
    /// Mac: a spending limit can't count an engine that never reports cost. `AccessTests` checks the adapters agree.
    public static func cost(_ engine: String) -> CostReporting {
        switch engine {
        case "claude-code": .turnEnd
        case "codex": .none
        default: .live
        }
    }

    /// The engine the user selected for a kind of provider, where they selected one. Which engine runs is
    /// EngineCatalog's to decide (`defaultEngine`), from this and what's on this Mac.
    public var selected: [AccountKind: String]

    public init(selected: [AccountKind: String] = [:]) { self.selected = selected }

    /// The settings key a kind's selection is saved under.
    public static func settingKey(_ kind: AccountKind) -> String { "engine.\(kind.rawValue)" }

    /// The sandbox levels an engine can provide for a kind of provider, the same ladder for every engine: one that
    /// can't contain its own tools there (`uncontained`) provides developer access only.
    public static func sandboxLevels(_ engine: String, for kind: AccountKind) -> [Sandbox] {
        uncontained(by: kind).contains(engine) ? [.developer] : Sandbox.allCases
    }

    /// Why an engine can't contain its own tools for a kind of provider, in plain words, or nil when it can.
    public static func uncontainedReason(_ engine: String, for kind: AccountKind) -> String? {
        guard uncontained(by: kind).contains(engine) else { return nil }
        return "On a Claude plan, Goose runs Claude Code with all its own tools and your claude.ai connectors, which Agneta can't contain"
    }
}
