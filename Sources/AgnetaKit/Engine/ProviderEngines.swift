// The one link between providers and engines: each kind of provider (an account's kind) is served by a list of
// engines, and one of them is selected, by the user in Settings → Engines or else by preference. Nothing else names
// an engine: an account runs on its provider's selected engine, and an app on whichever account a task uses.
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

    /// The engine the user selected for a kind of provider, where they selected one.
    public var selected: [AccountKind: String]

    public init(selected: [AccountKind: String] = [:]) { self.selected = selected }

    /// The engine serving a kind of provider: the selected one while it's supported and available, otherwise the most
    /// preferred one that is. Nil when none is (a ChatGPT plan without Codex installed).
    /// - Parameter available: the engines this Agneta can run now or download when needed.
    public func engine(for kind: AccountKind, available: Set<String>) -> String? {
        let candidates = Self.supported(by: kind).filter(available.contains)
        if let chosen = selected[kind], candidates.contains(chosen) { return chosen }
        return candidates.first
    }

    /// The settings key a kind's selection is saved under.
    public static func settingKey(_ kind: AccountKind) -> String { "engine.\(kind.rawValue)" }
}
