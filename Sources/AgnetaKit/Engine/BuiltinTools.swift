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

    /// ACP kinds that run nothing of their own: a plan or a mode switch.
    public static let inertKinds: Set<String> = ["think", "switch_mode"]

    /// Tools reported as kind `other` that run nothing of their own: finding deferred tools, a to-do list, a
    /// question, plan mode. `other` alone proves nothing: claude-agent-acp reports every tool without a reporter of
    /// its own that way, Monitor (which runs commands) among them, and codex-acp its requests for more sandbox
    /// permissions and for spawning agents. So `other` passes only for these names.
    public static let inertTools: Set<String> = [
        "ToolSearch", "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet",
        "AskUserQuestion", "EnterPlanMode", "ExitPlanMode", "ReportFindings"
    ]

    /// Whether a native runner may use a built-in tool of this ACP kind and name. Its commands run inside the
    /// engine's own sandbox, which reaches port 443, not through Agneta's broker: with no network, they're refused.
    /// A request with no kind, or one ACP doesn't define, can't be checked, so it's refused too. Developer access
    /// runs the engine's own tools natively, as in a terminal: everything passes, inside its widened sandbox.
    /// `brokered`: the engine's shell runs through Agneta's broker (Claude Code's Bash behind its prefix), so its
    /// commands get the session's tool profile like Goose's do, and only Bash itself is such a command.
    public static func nativeRunnerMayUse(
        kind: String?, tool: String? = nil, policy: SessionPolicy, brokered: Bool = false
    ) -> Bool {
        if policy.sandbox == .developer { return true }
        guard let kind else { return false }
        if inertKinds.contains(kind) { return true }
        if kind == "other" { return tool.map(inertTools.contains) ?? false }
        if kind == "execute", brokered {
            return tool == "Bash" && permitted(by: policy).contains { $0 == .shell || $0 == .readOnlyShell }
        }
        guard let builtIn = allCases.first(where: { $0.kinds.contains(kind) }) else { return false }
        var allowed = permitted(by: policy)
        if policy.network == .none { allowed.subtract([.shell, .readOnlyShell, .web]) }
        return allowed.contains(builtIn) || (builtIn == .shell && allowed.contains(.readOnlyShell))
    }
}
