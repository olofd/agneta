// What a user allows an app when they pair it, and how every session is held to
// it. The app asks for a scope with `agneta/pair` (the most built-in tools it
// will use, and the folders it will work in); the approval window shows it; the
// grant keeps it; and each session's policy must fit inside: no more tools, no
// folder outside the granted ones. A session can't widen what the user saw.
import Foundation

extension SessionPolicy.Tools: Codable {
    /// Ordered by what the engine may do: app-only < read < workspace.
    var rank: Int {
        switch self {
        case .appOnly: 0
        case .read: 1
        case .workspace: 2
        }
    }
}

public enum GrantScope {
    /// What an app asks for when it pairs. Each part narrows the approval window to it; left out, the user decides.
    public struct Request: Sendable, Equatable {
        /// The most built-in tools, and folders of the user's beyond the app's own workspace.
        public var tools: SessionPolicy.Tools = .appOnly
        public var folders: [URL] = []
        /// The provider kinds asked for: nil leaves it to the user (one provider ticked to start), every kind for "all".
        public var providers: [AccountKind]?
        /// The engines asked for: nil for all of them.
        public var engines: [String]?
        /// The mode asked for: nil for any (the window's picker starts on developer access).
        public var sandbox: Sandbox?
        public init(
            tools: SessionPolicy.Tools = .appOnly, folders: [URL] = [], providers: [AccountKind]? = nil,
            engines: [String]? = nil, sandbox: Sandbox? = nil
        ) {
            (self.tools, self.folders, self.providers, self.engines, self.sandbox) = (
                tools, folders, providers, engines, sandbox
            )
        }
    }

    /// The scope an app asks for: `{"tools": "app-only" | "read" | "workspace", "folders": [absolute paths],
    /// "providers": "all" | [kinds], "engines": "all" | [engine ids], "sandbox": "contained" | "developer" | "any"}`.
    /// No scope asks for app-only tools and no folders of the user's (the app still gets its own workspace), and leaves
    /// providers, engines and mode to the user. Folders follow the session policy's rules: absolute, and nothing that
    /// reaches the home folder as a whole, other apps' storage, Agneta's data or secrets. `engines` names engines Agneta
    /// knows (`known`); an unknown kind or engine is refused, with the ones there are.
    public static func requested(_ value: JSONValue?, context: PolicyContext, known engines: Set<String>) throws
        -> Request
    {
        guard let value, value != .null else { return Request() }
        guard let fields = value.objectValue else {
            throw PolicyRejection(field: "scope", reason: "expected an object")
        }
        let unknown = Set(fields.keys).subtracting(["tools", "folders", "sandbox", "providers", "engines"])
        guard unknown.isEmpty else {
            throw PolicyRejection(field: "scope", reason: "unknown fields \(unknown.sorted().joined(separator: ", "))")
        }
        var request = Request()
        if let raw = fields["tools"] {
            guard let name = raw.stringValue, let parsed = SessionPolicy.Tools(rawValue: name) else {
                throw PolicyRejection(field: "scope.tools", reason: "expected app-only, read or workspace")
            }
            request.tools = parsed
        }
        if let raw = fields["folders"] {
            guard let items = raw.arrayValue else {
                throw PolicyRejection(field: "scope.folders", reason: "expected a list of absolute paths")
            }
            for item in items {
                guard let path = item.stringValue else {
                    throw PolicyRejection(field: "scope.folders", reason: "expected absolute paths")
                }
                request.folders.append(try SessionPolicy.canonical(path, field: "scope.folders", context: context))
            }
        }
        if let raw = fields["sandbox"] {
            switch raw.stringValue {
            case "any"?: request.sandbox = nil
            case let name? where Sandbox(rawValue: name) != nil: request.sandbox = Sandbox(rawValue: name)
            default: throw PolicyRejection(field: "scope.sandbox", reason: "expected contained, developer or any")
            }
        }
        if let raw = fields["providers"] {
            let kinds = AccountKind.allCases.map(\.rawValue)
            request.providers = try list(raw, field: "scope.providers", all: kinds, valid: kinds).compactMap(
                AccountKind.init(rawValue:))
        }
        if let raw = fields["engines"] {
            request.engines = try list(raw, field: "scope.engines", all: engines.sorted(), valid: engines.sorted())
        }
        return request
    }

    /// `"all"`, or a non-empty list of distinct known names.
    private static func list(_ raw: JSONValue, field: String, all: [String], valid: [String]) throws -> [String] {
        if raw.stringValue == "all" { return all }
        guard let items = raw.arrayValue?.compactMap(\.stringValue), items.count == raw.arrayValue?.count,
            !items.isEmpty
        else {
            throw PolicyRejection(
                field: field, reason: "expected \"all\" or a list of: \(valid.joined(separator: ", "))")
        }
        if let bad = items.first(where: { !valid.contains($0) }) {
            throw PolicyRejection(field: field, reason: "\(bad) isn't one of: \(valid.joined(separator: ", "))")
        }
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    /// Why a session doesn't fit its app's grant, or nil when it does: no more built-in tools than granted, and
    /// every folder it names (workspace, readable, writable, read-only) inside a granted folder.
    public static func check(_ policy: SessionPolicy, against grant: Router.Grant) -> PolicyRejection? {
        if policy.tools.rank > grant.tools.rank {
            return PolicyRejection(
                field: "tools",
                reason: "\(grant.app) was allowed \(grant.tools.rawValue) tools, not \(policy.tools.rawValue)")
        }
        // Real paths on both sides (/tmp is /private/tmp): the policy's folders are resolved when parsed, the grant's when
        // the app paired, and never again: a session may have replaced a granted folder, or one above a granted
        // folder, with a link to somewhere it wasn't granted.
        let granted = grant.folders.map { URL(filePath: $0, directoryHint: .isDirectory) }
        let named =
            [("cwd", policy.workspace)] + policy.readable.map { ("readable", $0) }
            + policy.writable.map { ("writable", $0) }
            + policy.readOnly.map { ("readOnly", $0) }
        for (field, folder) in named where !granted.contains(where: { folder.isInside($0) }) {
            return PolicyRejection(
                field: field,
                reason: "\(folder.path(percentEncoded: false)) is outside the folders \(grant.app) was allowed")
        }
        return nil
    }

    /// Whether the app connecting with a verified grant's token is still that app: same signing identifier and
    /// team, with a checkable signature. A token alone (copied to another program) isn't enough. Grants made
    /// without a verified identity have nothing to compare, and pass.
    public static func identityMatches(_ grant: Router.Grant, _ peer: PeerIdentity?) -> Bool {
        guard grant.verified else { return true }
        guard let peer, peer.trusted, peer.identifier == grant.identifier else { return false }
        return grant.team == nil || peer.team == grant.team
    }
}
