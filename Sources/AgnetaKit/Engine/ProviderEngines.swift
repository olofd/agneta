// Which engines can serve which kind of provider (an account's kind), a fixed table, and the default the user chose
// for each kind in Settings → Engines. Accounts name no engine; an app picks one per task among what its grant
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

    /// The engine the user selected for a kind of provider, where they selected one. Which engine runs is
    /// EngineCatalog's to decide (`defaultEngine`), from this and what's on this Mac.
    public var selected: [AccountKind: String]

    public init(selected: [AccountKind: String] = [:]) { self.selected = selected }

    /// The settings key a kind's selection is saved under.
    public static func settingKey(_ kind: AccountKind) -> String { "engine.\(kind.rawValue)" }
}
