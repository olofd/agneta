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
    /// The policy's `builtins` narrow it further: what they leave out is never permitted.
    public static func permitted(by policy: SessionPolicy) -> Set<BuiltinTools> {
        let level: Set<BuiltinTools> =
            switch policy.tools {
            case .appOnly: []
            case .read: [.read, .readOnlyShell]
            case .workspace: [.read, .edit, .shell]
            }
        return level.filter { policy.allows($0.group) }
    }

    /// What a policy promises at least: an engine may offer less than `permitted`, never less than this.
    public static func promised(by policy: SessionPolicy) -> Set<BuiltinTools> {
        let level: Set<BuiltinTools> =
            switch policy.tools {
            case .appOnly: []
            case .read: [.read]
            case .workspace: [.read, .edit]
            }
        return level.filter { policy.allows($0.group) }
    }

    /// The group an app names to keep or leave out these tools (`builtins`).
    public var group: BuiltinGroup {
        switch self {
        case .read: .read
        case .edit: .edit
        case .shell, .readOnlyShell: .execute
        case .web: .web
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
    /// A policy with `builtins` refuses first whatever is outside them, under developer access too: the engine was
    /// configured not to offer it, so a request for it is one more net, not a choice.
    public static func nativeRunnerMayUse(
        kind: String?, tool: String? = nil, policy: SessionPolicy, brokered: Bool = false
    ) -> Bool {
        if let groups = policy.builtins, !BuiltinGroup.kept(kind: kind, tool: tool, in: groups) { return false }
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

/// The groups of an engine's own tools an app can keep (`builtins` in agneta/policy), named the same on every engine: an
/// app narrows a session to some of them, never widening what its `tools`, `sandbox` and network give. Each engine's
/// adapter maps them onto its own tools and settings, and refuses a narrowing it can't honour (docs/ENGINES.md).
public enum BuiltinGroup: String, CaseIterable, Sendable, Comparable {
    /// Reading files, listing and searching them (ACP kinds `read`, `search`).
    case read
    /// Writing, editing, deleting and moving files (`edit`, `delete`, `move`).
    case edit
    /// Shell commands, and stopping their background jobs (`execute`).
    case execute
    /// Fetching pages and searching the web (`fetch`).
    case web
    /// Agents the engine starts itself, and messages to them.
    case subagents
    /// Skills and slash commands: instructions the engine loads by name.
    case skills
    /// Tools that run nothing: to-do lists, plans and plan mode, goals, questions for the user, waiting.
    case planning

    public static func < (a: BuiltinGroup, b: BuiltinGroup) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// Tools that only offer the app's own tools (loading deferred ones), kept whatever the narrowing. Their permission
    /// requests are exempt only when their kind doesn't say what they do: claude-agent-acp 0.107.2 reports ToolSearch as
    /// `other`.
    public static let infrastructure: Set<String> = ["ToolSearch"]

    /// Engines' own tools by name (Claude Code's, older names included, and Codex's), for the tools a narrowed session
    /// is offered and for answering its permission requests. A tool not named here is outside every group: a narrowed
    /// session never gets it.
    public static let named: [String: BuiltinGroup] = {
        var table: [String: BuiltinGroup] = [:]
        let groups: [BuiltinGroup: [String]] = [
            .read: ["Read", "Glob", "Grep", "view_image"],
            .edit: ["Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch"],
            .execute: ["Bash", "BashOutput", "KillShell", "TaskStop"],
            .web: ["WebFetch", "WebSearch", "web_search"],
            .subagents: [
                "Agent", "Task", "SendMessage", "ListAgents", "Workflow", "spawn_agent", "send_input", "wait_agent",
                "close_agent", "resume_agent"
            ],
            .skills: ["Skill", "SlashCommand"],
            .planning: [
                "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "EnterPlanMode", "ExitPlanMode",
                "AskUserQuestion", "update_plan", "request_user_input", "create_goal", "get_goal", "update_goal"
            ]
        ]
        for (group, names) in groups { for name in names { table[name] = group } }
        return table
    }()

    /// The group an ACP kind that names what a tool does belongs to; nil for `other`, `think`, `switch_mode`, a missing
    /// kind and one ACP doesn't define, which don't say.
    public static func of(kind: String?) -> BuiltinGroup? {
        switch kind {
        case "read", "search": .read
        case "edit", "delete", "move": .edit
        case "execute": .execute
        case "fetch": .web
        default: nil
        }
    }

    /// Whether a native runner's request is inside the kept groups. A kind that says what the tool does decides, and a
    /// known name must agree with it (both groups kept): a name alone, which an adapter reads from the engine's own
    /// fields, never widens a kind. A kind that doesn't say (`other`, `think`, `switch_mode`, none) needs a known name
    /// in a kept group, or one of the tools that only load the app's tools: claude-agent-acp reports Agent as `think`,
    /// so `think` alone proves nothing, and such a request is refused.
    public static func kept(kind: String?, tool: String?, in groups: Set<BuiltinGroup>) -> Bool {
        let named = tool.flatMap { Self.named[$0] }
        if let group = of(kind: kind) { return groups.contains(group) && named.map(groups.contains) ?? true }
        // Tool search arrives as `other` (claude-agent-acp reports every tool without a reporter of its own that way):
        // the exemption holds only for a kind that doesn't say, never against one that does.
        if let tool, infrastructure.contains(tool) { return true }
        return named.map(groups.contains) ?? false
    }

    /// `["read", "edit", …]`, or nothing for no narrowing. Anything else is refused, naming the field.
    static func parse(_ value: JSONValue?) throws -> Set<BuiltinGroup>? {
        guard let value else { return nil }
        let expected = allCases.map(\.rawValue).joined(separator: ", ")
        guard let items = value.arrayValue else {
            throw PolicyRejection(field: "builtins", reason: "must be a list of groups: \(expected)")
        }
        return try Set(
            items.map { item in
                guard let name = item.stringValue, let group = BuiltinGroup(rawValue: name) else {
                    throw PolicyRejection(
                        field: "builtins", reason: "\(item.stringValue ?? "a non-string") isn't one of \(expected)")
                }
                return group
            })
    }
}
