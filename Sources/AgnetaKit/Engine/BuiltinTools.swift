// Agneta's contract with every engine: which of an engine's own (built-in) tools a session's policy permits,
// whichever engine runs it. Brokered engines (Goose, OpenCode) are configured with no more than this; on native
// runners (Claude Code, Codex) Agneta also answers each permission request by it. The app's own tools, from its
// MCP servers, are always the app's to give and aren't counted. EngineContractTests checks every engine under
// every policy.
import Foundation

public enum BuiltinTools: String, CaseIterable, Sendable {
    /// Reading and searching the workspace and the policy's readable folders.
    case read
    /// Writing, editing, deleting and moving inside the writable folders.
    case edit
    /// Commands confined to the workspace, without network.
    case shell
    /// Commands that read the workspace but write only a scratch folder.
    case readOnlyShell = "read-only-shell"
    /// Fetching from or searching the web.
    case web

    /// The most a policy permits. `app-only`: none. `read`: reading, and commands that can't write the workspace.
    /// `workspace`: reading, editing and a shell. The web never, while a policy's network is always `none`.
    public static func permitted(by policy: SessionPolicy) -> Set<BuiltinTools> {
        switch policy.tools {
        case .appOnly: []
        case .read: [.read, .readOnlyShell]
        case .workspace: [.read, .edit, .shell]
        }
    }

    /// What a policy promises at least: an engine may offer less than `permitted`, never less than this.
    public static func promised(by policy: SessionPolicy) -> Set<BuiltinTools> {
        switch policy.tools {
        case .appOnly: []
        case .read: [.read]
        case .workspace: [.read, .edit]
        }
    }

    /// The ACP tool kinds of each, as native runners report them in permission requests.
    public var kinds: Set<String> {
        switch self {
        case .read: ["read", "search"]
        case .edit: ["edit", "delete", "move"]
        case .shell, .readOnlyShell: ["execute"]
        case .web: ["fetch"]
        }
    }

    /// Whether a native runner may use a built-in tool of this ACP kind. Its commands run inside the engine's own
    /// sandbox, which reaches port 443, not through Agneta's broker: with no network, they're refused. Kinds that
    /// touch nothing (think, switch_mode, other) aren't Agneta's to refuse.
    public static func nativeRunnerMayUse(kind: String, policy: SessionPolicy) -> Bool {
        guard let tool = allCases.first(where: { $0.kinds.contains(kind) }) else { return true }
        var allowed = permitted(by: policy)
        if policy.network == .none { allowed.subtract([.shell, .readOnlyShell, .web]) }
        return allowed.contains(tool) || (tool == .shell && allowed.contains(.readOnlyShell))
    }
}
