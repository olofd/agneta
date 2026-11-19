// agneta/policy: the rules an app sends with session/new. Agneta enforces
// every field or refuses the session; it never runs with weaker rules.
import Foundation

public struct SessionPolicy: Sendable, Equatable {
    public enum Tools: String, Sendable {
        /// Only the app's MCP tools.
        case appOnly = "app-only"
        /// Plus read-only built-ins.
        case read
        /// Plus edit and shell, confined to the workspace.
        case workspace
    }

    public enum Network: Sendable, Equatable {
        /// Tools reach only the provider and the app's tool server.
        case none
        /// Tools may also reach these hosts.
        case allow([String])
    }

    public enum Approval: String, Sendable {
        case neverAsk = "never-ask"
        case askApp = "ask-app"
    }

    public struct Limits: Sendable, Equatable {
        public var maxTurns: Int
        public var maxSeconds: Int
        public var maxCostUSD: Double?

        public static let `default` = Limits(maxTurns: 200, maxSeconds: 4 * 3600, maxCostUSD: nil)

        /// The first limit a running prompt has passed, with the limit's value, or nil.
        /// `maxTurns` counts the model's turns within one prompt (its calls to the model);
        /// `maxSeconds` is the prompt's wall time; `maxCostUSD` the task's known cost so far.
        public func breached(seconds: Double, modelCalls: Int, cost: Double) -> (limit: String, value: JSONValue)? {
            if seconds > Double(maxSeconds) { return ("maxSeconds", .int(Int64(maxSeconds))) }
            if modelCalls > maxTurns { return ("maxTurns", .int(Int64(maxTurns))) }
            if let maxCostUSD, cost > maxCostUSD { return ("maxCostUSD", .double(maxCostUSD)) }
            return nil
        }
    }

    public var tools: Tools
    public var workspace: URL
    public var readable: [URL]
    public var writable: [URL]
    /// Readable, never writable, even inside the workspace or a writable folder.
    public var readOnly: [URL] = []
    /// Never readable or writable, even inside allowed folders.
    public var denied: [URL]
    public var network: Network
    /// Loopback ports and Unix sockets shell commands may reach even under `network: none`.
    public var toolPorts: [Int] = []
    public var toolSockets: [URL] = []
    /// Of `toolPorts` and `toolSockets`, those found served by the app itself when the session opened (ToolReach): what
    /// a contained session may reach beyond its granted folders (GrantScope.reach). Set by the router, never by the app.
    public var servedByApp: Set<ToolReach.Endpoint> = []
    public var approval: Approval
    public var limits: Limits
    /// The sandbox the session runs in, as resolved when it opens (SandboxResolution): what Agneta's profiles build.
    public var sandbox: Sandbox = .contained
    /// The sandbox the app asked for, or nil: it may only be more restrictive than the user's choice.
    public var requestedSandbox: Sandbox?
    /// Environment variables the app sets for shell commands run by Agneta's broker: its toolchain's PATH (entries
    /// in the session's readable folders), CARGO_HOME, PYTHONPATH, a kit's settings. Never what confines or names the
    /// command (HOME, TMPDIR, the loader's DYLD_ and LD_ variables, Agneta's and Claude Code's own).
    public var toolEnvironment: [String: String] = [:]
    /// Developer access: the app's own build caches (set by the router, one folder per app; never the user's own). Nil
    /// gives the engine's scratch folder.
    public var buildCaches: URL?
    /// The build caches a developer session uses: the app's, or the engine's scratch.
    public func caches(scratch: URL) -> URL {
        buildCaches ?? scratch.appending(path: "caches", directoryHint: .isDirectory)
    }
    /// The policy's folders as they were checked when it was parsed (resolved, refused if protected), recorded then:
    /// sandbox profiles write these without resolving them again. Empty for a policy built in code.
    public var checkedPaths: Set<String> = []

    public static let key = "agneta/policy"

    /// An app that sends no policy gets workspace tools in its cwd, approval through the app.
    public static func fallback(workspace: URL) -> SessionPolicy {
        SessionPolicy(
            tools: .workspace, workspace: workspace, readable: [], writable: [], denied: [], network: .none,
            approval: .askApp, limits: .default)
    }
}

public struct PolicyRejection: Error, Equatable, Sendable {
    public var field: String
    public var reason: String

    /// The JSON-RPC error Agneta returns, naming the field that can't be enforced.
    public var rpcError: RPCError {
        RPCError(
            code: RPCError.invalidParams, message: "Agneta can't enforce \(field): \(reason)",
            data: ["agneta": ["unenforceable": [.string(field)], "reason": .string(reason)]])
    }
}

public struct PolicyContext: Sendable {
    /// The user's real home, e.g. /Users/name.
    public var userHome: URL
    /// Agneta's own data roots (Application Support, Caches); never readable to sessions.
    public var agnetaRoots: [URL]
    /// Where each paired app gets a workspace of its own (`<this>/<grant id>`), always within its grant.
    public var appWorkspaces: URL?

    public init(userHome: URL, agnetaRoots: [URL], appWorkspaces: URL? = nil) {
        self.userHome = userHome
        self.agnetaRoots = agnetaRoots
        self.appWorkspaces = appWorkspaces
    }
}

extension SessionPolicy {
    /// The strict profile for this session's shell commands, widened for developer access (with the user's home and
    /// Agneta's own data roots, which stay out).
    public func toolProfile(scratch: URL, home: URL? = nil, agnetaRoots: [URL] = []) -> SandboxProfile {
        let caches = caches(scratch: scratch)
        var profile = SandboxProfile(
            kind: .tool,
            writable: tools == .workspace ? [workspace] + writable + [scratch] : [scratch],
            denied: denied,
            readable: [workspace] + readable + readOnly,
            loopbackPorts: toolPorts)
        profile.readOnly = readOnly
        profile.unixSockets = toolSockets
        profile.verbatim = checkedPaths
        if sandbox == .developer, let home {
            DeveloperAccess.widen(&profile, home: home, agnetaRoots: agnetaRoots, caches: caches)
        }
        return profile
    }

    func recordingChecked() -> SessionPolicy {
        var policy = self
        // As resolved, nothing more: standardizedFileURL would turn /private/var into /var, which the sandbox never matches.
        policy.checkedPaths = Set(
            ([workspace] + readable + writable + readOnly + denied).map {
                $0.path(percentEncoded: false).trimmingSuffix("/")
            })
        return policy
    }

    /// Parses and validates the extension from `session/new` params.
    public static func parse(_ value: JSONValue?, cwd: String, context: PolicyContext) throws -> SessionPolicy {
        let workspace = try canonical(cwd, field: "cwd", context: context)
        guard let value else { return SessionPolicy.fallback(workspace: workspace).recordingChecked() }
        guard let fields = value.objectValue else {
            throw PolicyRejection(field: "policy", reason: "must be an object")
        }
        // A field Agneta doesn't know may be a rule the app expects enforced: refuse it.
        if let unknown = Set(fields.keys).subtracting(knownFields).sorted().first {
            throw PolicyRejection(field: unknown, reason: "isn't a policy field Agneta knows")
        }

        // A field that's there must be the right type: one of another type is refused, never read as left out.
        func name(_ field: String, otherwise: String) throws -> String {
            guard let raw = value[field] else { return otherwise }
            guard let text = raw.stringValue else { throw PolicyRejection(field: field, reason: "must be a string") }
            return text
        }
        let toolsName = try name("tools", otherwise: Tools.workspace.rawValue)
        guard let tools = Tools(rawValue: toolsName) else {
            throw PolicyRejection(field: "tools", reason: "unknown value \(toolsName)")
        }

        func folders(_ field: String) throws -> [URL] {
            guard let items = value[field] else { return [] }
            guard let list = items.arrayValue else {
                throw PolicyRejection(field: field, reason: "must be a list of absolute paths")
            }
            return try list.map { item in
                guard let path = item.stringValue else {
                    throw PolicyRejection(field: field, reason: "must be a list of absolute paths")
                }
                return try canonical(path, field: field, context: context)
            }
        }

        let network: Network
        switch value["network"] {
        case nil, .string("none")?: network = .none
        case .object(let fields)?:
            guard let items = fields["allow"]?.arrayValue, items.allSatisfy({ $0.stringValue != nil }) else {
                throw PolicyRejection(field: "network", reason: "expected \"none\" or {\"allow\": [hosts]}")
            }
            // No hosts is no network, not an allowance.
            network = items.isEmpty ? .none : .allow(items.compactMap(\.stringValue))
        default: throw PolicyRejection(field: "network", reason: "expected \"none\" or {\"allow\": [hosts]}")
        }
        // Seatbelt filters by address and port, not host name, so a host allowlist for tools can't be enforced.
        if case .allow(let hosts) = network, !hosts.isEmpty {
            throw PolicyRejection(field: "network", reason: "per-host network access for tools isn't supported yet")
        }

        var requestedSandbox: Sandbox?
        if value["sandbox"] != nil {
            let level = try name("sandbox", otherwise: "")
            guard let parsed = Sandbox(rawValue: level) else {
                throw PolicyRejection(field: "sandbox", reason: "expected contained or developer")
            }
            if parsed == .developer, tools != .workspace {
                throw PolicyRejection(field: "sandbox", reason: "developer access needs workspace tools")
            }
            requestedSandbox = parsed
        }

        let approvalName = try name("approval", otherwise: Approval.askApp.rawValue)
        guard let approval = Approval(rawValue: approvalName) else {
            throw PolicyRejection(field: "approval", reason: "unknown value \(approvalName)")
        }

        var limits = Limits.default
        if let raw = value["limits"] {
            // Known limits only, as numbers; anything else is refused rather than ignored.
            guard let fields = raw.objectValue, Set(fields.keys).isSubset(of: ["maxTurns", "maxSeconds", "maxCostUSD"])
            else {
                throw PolicyRejection(field: "limits", reason: "expected maxTurns, maxSeconds and maxCostUSD")
            }
            func number(_ key: String) throws -> Double? {
                guard let field = fields[key] else { return nil }
                switch field {
                case .int(let v): return Double(v)
                case .double(let v): return v
                default: throw PolicyRejection(field: "limits", reason: "\(key) must be a number")
                }
            }
            // Checked before converting: Int(1e300) traps, which would take Agneta down with every task in it.
            func whole(_ key: String) throws -> Int? {
                guard let value = try number(key) else { return nil }
                guard value.isFinite, value.rounded() == value, value >= 1, value <= Double(Int32.max) else {
                    throw PolicyRejection(
                        field: "limits", reason: "\(key) must be a whole number from 1 to \(Int32.max)")
                }
                return Int(value)
            }
            if let turns = try whole("maxTurns") { limits.maxTurns = turns }
            if let seconds = try whole("maxSeconds") { limits.maxSeconds = seconds }
            if let cost = try number("maxCostUSD") {
                guard cost.isFinite else {
                    throw PolicyRejection(field: "limits", reason: "maxCostUSD must be a finite number")
                }
                limits.maxCostUSD = cost
            }
            guard limits.maxTurns > 0, limits.maxSeconds > 0, (limits.maxCostUSD ?? 1) > 0 else {
                throw PolicyRejection(field: "limits", reason: "must be positive")
            }
        }

        let denied = try folders("denied")
        let writable = try folders("writable")
        let readOnly = try folders("readOnly")
        for folder in writable where denied.contains(where: { folder.isInside($0) }) {
            throw PolicyRejection(
                field: "writable", reason: "\(folder.path(percentEncoded: false)) is inside a denied folder")
        }
        if denied.contains(where: { workspace.isInside($0) }) {
            throw PolicyRejection(field: "denied", reason: "the workspace itself is denied")
        }
        var toolPorts: [Int] = []
        if let raw = value["toolPorts"] {
            guard let ports = raw.arrayValue?.compactMap(\.intValue), ports.count == raw.arrayValue?.count,
                ports.allSatisfy({ (1...65535).contains($0) })
            else { throw PolicyRejection(field: "toolPorts", reason: "must be a list of port numbers") }
            toolPorts = ports.map(Int.init)
        }
        if let raw = value["toolSockets"], raw.arrayValue == nil {
            throw PolicyRejection(field: "toolSockets", reason: "must be a list of absolute socket paths")
        }
        let toolSockets = try (value["toolSockets"]?.arrayValue ?? []).map { item -> URL in
            guard let path = item.stringValue, path.hasPrefix("/") else {
                throw PolicyRejection(field: "toolSockets", reason: "must be a list of absolute socket paths")
            }
            // Connecting is a network rule, not a file one, so no folder check would see it: a socket gets the same
            // protected places (other apps' containers, Agneta's data, ~/.ssh) as a folder does.
            _ = try canonical(path, field: "toolSockets", context: context)
            return URL(filePath: path).realFileURL
        }
        var policy = SessionPolicy(
            tools: tools, workspace: workspace, readable: try folders("readable"), writable: writable,
            denied: denied, network: network, approval: approval, limits: limits)
        policy.readOnly = readOnly
        policy.toolPorts = toolPorts
        policy.toolSockets = toolSockets
        policy.requestedSandbox = requestedSandbox
        if let raw = value["toolEnvironment"] {
            guard let fields = raw.objectValue else {
                throw PolicyRejection(field: "toolEnvironment", reason: "must be an object of strings")
            }
            for (key, item) in fields {
                guard let text = item.stringValue else {
                    throw PolicyRejection(field: "toolEnvironment", reason: "\(key) must be a string")
                }
                guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                    !Self.reservedEnvironment.contains(key),
                    !Self.reservedPrefixes.contains(where: key.hasPrefix)
                else {
                    throw PolicyRejection(field: "toolEnvironment", reason: "\(key) can't be set for commands")
                }
                if key == "PATH" {
                    let reach =
                        [workspace] + policy.readable + policy.readOnly + policy.writable
                        + SandboxProfile.systemReadable
                    // An empty entry (a leading, trailing or doubled colon) would look commands up in the current folder.
                    for entry in text.split(separator: ":", omittingEmptySubsequences: false).map(String.init) {
                        let url = URL(filePath: entry, directoryHint: .isDirectory).realFileURL
                        guard entry.hasPrefix("/"), reach.contains(where: { url.isInside($0.realFileURL) }) else {
                            throw PolicyRejection(
                                field: "toolEnvironment", reason: "PATH entry \(entry) isn't in the session's folders")
                        }
                    }
                }
                policy.toolEnvironment[key] = text
            }
        }
        return policy.recordingChecked()
    }

    static let knownFields: Set<String> = [
        "tools", "network", "approval", "limits", "readable", "writable", "readOnly", "denied", "toolPorts",
        "toolSockets",
        "sandbox", "toolEnvironment"
    ]
    static let reservedEnvironment: Set<String> = [
        "HOME", "TMPDIR", "USER", "LOGNAME", "SHELL", "BASH_ENV", "ENV", "ZDOTDIR", "PROMPT_COMMAND", "IFS"
    ]
    static let reservedPrefixes = ["DYLD_", "LD_", "AGNETA_", "CLAUDE_CODE_", "CODEX_", "GOOSE_", "OPENCODE_"]

    /// Resolves symlinks and refuses paths that would escape into protected places, or contain them: /Users or
    /// ~/Library would expose Agneta's data and other apps' containers.
    static func canonical(_ path: String, field: String, context: PolicyContext) throws -> URL {
        guard path.hasPrefix("/") else { throw PolicyRejection(field: field, reason: "\(path) isn't an absolute path") }
        let url = URL(filePath: path, directoryHint: .isDirectory).realFileURL
        let resolved = url.path(percentEncoded: false)
        if resolved == "/" || url.isInside(context.userHome.realFileURL) && context.userHome.realFileURL.isInside(url) {
            throw PolicyRejection(field: field, reason: "\(resolved) is too broad")
        }
        let home = context.userHome.realFileURL
        if home.isInside(url) {
            throw PolicyRejection(field: field, reason: "\(resolved) contains your whole home folder")
        }
        let containers = context.userHome.appending(path: "Library/Containers").realFileURL
        let groups = context.userHome.appending(path: "Library/Group Containers").realFileURL
        if url.isInside(containers) || url.isInside(groups) || containers.isInside(url) || groups.isInside(url) {
            throw PolicyRejection(field: field, reason: "\(resolved) reaches other apps' private storage")
        }
        if context.agnetaRoots.contains(where: { url.isInside($0.realFileURL) || $0.realFileURL.isInside(url) }) {
            throw PolicyRejection(field: field, reason: "\(resolved) reaches Agneta's own data")
        }
        // Places where a write would outlive the session or reach secrets.
        for sensitive in ["Library/LaunchAgents", "Library/Keychains", ".ssh"].map({
            context.userHome.appending(path: $0).realFileURL
        })
        where url.isInside(sensitive) || sensitive.isInside(url) {
            throw PolicyRejection(field: field, reason: "\(resolved) reaches \(sensitive.lastPathComponent)")
        }
        return url
    }
}

extension URL {
    /// The real path with symlinks resolved by realpath(3). Foundation's
    /// resolvingSymlinksInPath maps /private/tmp to /tmp, which Seatbelt
    /// doesn't match; the kernel sees /private/tmp. Missing tails are kept.
    public var realFileURL: URL {
        let path = standardizedFileURL.path(percentEncoded: false)
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return URL(
                filePath: String(cString: resolved), directoryHint: hasDirectoryPath ? .isDirectory : .inferFromPath)
        }
        let parent = deletingLastPathComponent()
        guard parent.path(percentEncoded: false) != path else { return self }
        return parent.realFileURL.appending(
            path: lastPathComponent, directoryHint: hasDirectoryPath ? .isDirectory : .inferFromPath)
    }

    /// True when self equals or lies under `folder` (both canonical file URLs). Compared as written, with only `.` and
    /// `..` removed: `standardizedFileURL` drops a leading /private only when the shorter path exists, so a missing
    /// /private/tmp/a/x was never inside an existing /private/tmp/a, and a check meant to refuse it passed.
    public func isInside(_ folder: URL) -> Bool {
        let path = standardized.path(percentEncoded: false).trimmingSuffix("/")
        let base = folder.standardized.path(percentEncoded: false).trimmingSuffix("/")
        return path == base || path.hasPrefix(base + "/")
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > suffix.count ? String(dropLast(suffix.count)) : self
    }
}
