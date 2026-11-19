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
    /// The scope an app asks for: `{"tools": "app-only" | "read" | "workspace", "folders": [absolute paths],
    /// "sandbox": "contained" | "developer"}`. `sandbox` is the most its tasks will need, where the approval window's
    /// picker starts; the user decides (full power, `developer`, by default).
    /// No scope asks for app-only tools and no folders of the user's (the app still gets its own workspace).
    /// Folders follow the session policy's rules: absolute, and nothing that reaches the home folder as a whole,
    /// other apps' storage, Agneta's data or secrets.
    public static func requested(_ value: JSONValue?, context: PolicyContext) throws -> (tools: SessionPolicy.Tools, folders: [URL], sandbox: Sandbox) {
        guard let value, value != .null else { return (.appOnly, [], .default) }
        guard let fields = value.objectValue else { throw PolicyRejection(field: "scope", reason: "expected an object") }
        let unknown = Set(fields.keys).subtracting(["tools", "folders", "sandbox"])
        guard unknown.isEmpty else { throw PolicyRejection(field: "scope", reason: "unknown fields \(unknown.sorted().joined(separator: ", "))") }
        var tools = SessionPolicy.Tools.appOnly
        if let raw = fields["tools"] {
            guard let name = raw.stringValue, let parsed = SessionPolicy.Tools(rawValue: name) else {
                throw PolicyRejection(field: "scope.tools", reason: "expected app-only, read or workspace")
            }
            tools = parsed
        }
        var folders: [URL] = []
        if let raw = fields["folders"] {
            guard let items = raw.arrayValue else { throw PolicyRejection(field: "scope.folders", reason: "expected a list of absolute paths") }
            for item in items {
                guard let path = item.stringValue else { throw PolicyRejection(field: "scope.folders", reason: "expected absolute paths") }
                folders.append(try SessionPolicy.canonical(path, field: "scope.folders", context: context))
            }
        }
        var sandbox = Sandbox.default
        if let raw = fields["sandbox"] {
            guard let name = raw.stringValue, let parsed = Sandbox(rawValue: name) else {
                throw PolicyRejection(field: "scope.sandbox", reason: "expected contained or developer")
            }
            sandbox = parsed
        }
        return (tools, folders, sandbox)
    }

    /// Why a session doesn't fit its app's grant, or nil when it does: no more built-in tools than granted, and
    /// every folder it names (workspace, readable, writable, read-only) inside a granted folder.
    public static func check(_ policy: SessionPolicy, against grant: Router.Grant) -> PolicyRejection? {
        if policy.tools.rank > grant.tools.rank {
            return PolicyRejection(field: "tools", reason: "\(grant.app) was allowed \(grant.tools.rawValue) tools, not \(policy.tools.rawValue)")
        }
        // Real paths on both sides (/tmp is /private/tmp): the policy's folders are resolved when parsed, the grant's when
        // the app paired, and never again: a session may have replaced a granted folder, or one above a granted
        // folder, with a link to somewhere it wasn't granted.
        let granted = grant.folders.map { URL(filePath: $0, directoryHint: .isDirectory) }
        let named = [("cwd", policy.workspace)] + policy.readable.map { ("readable", $0) } + policy.writable.map { ("writable", $0) }
            + policy.readOnly.map { ("readOnly", $0) }
        for (field, folder) in named where !granted.contains(where: { folder.isInside($0) }) {
            return PolicyRejection(field: field, reason: "\(folder.path(percentEncoded: false)) is outside the folders \(grant.app) was allowed")
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
