// Account kinds and records, and where Agneta keeps its files. The records
// themselves live in SQLite (Database.swift); secrets never do: API keys are in
// the Keychain, subscription tokens in each account's folder.
import Foundation

public enum AccountKind: String, Codable, Sendable, CaseIterable {
    case chatGPT = "chatgpt"
    case claude = "claude"
    case anthropicKey = "anthropic-key"
    case openAIKey = "openai-key"

    public var provider: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude, .anthropicKey: "Claude"
        case .openAIKey: "OpenAI"
        }
    }

    public var plan: String {
        switch self {
        case .chatGPT: "ChatGPT plan"
        case .claude: "Claude plan"
        case .anthropicKey, .openAIKey: "API key"
        }
    }

    public var subscription: SubscriptionRoute? {
        switch self {
        case .chatGPT: .chatGPT
        case .claude: .claudeCode
        default: nil
        }
    }
}

public struct AccountRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var kind: AccountKind
    public var label: String
    public var email: String?
    public var model: String?
    public var created: Date
    /// A paused account takes no new tasks; running ones finish.
    public var paused: Bool
    /// The engine serving the account ("goose", "opencode").
    public var engine: String

    public init(id: String = String(UUID().uuidString.prefix(8)).lowercased(), kind: AccountKind, label: String, email: String? = nil, model: String? = nil,
                created: Date = Date(), paused: Bool = false, engine: String = "goose") {
        self.id = id
        self.kind = kind
        self.label = label
        self.email = email
        self.model = model
        self.created = created
        self.paused = paused
        self.engine = engine
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(AccountKind.self, forKey: .kind)
        label = try container.decode(String.self, forKey: .label)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        created = try container.decode(Date.self, forKey: .created)
        paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        engine = try container.decodeIfPresent(String.self, forKey: .engine) ?? "goose"
    }
}

/// Agneta's folders inside its Application Support root.
public struct AgnetaStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public var databaseFile: URL { root.appending(path: "agneta.sqlite") }
    /// Accounts and grants from builds before SQLite; imported once.
    public var legacyFile: URL { root.appending(path: "agneta.json") }
    public var accountsFolder: URL { root.appending(path: "Accounts", directoryHint: .isDirectory) }
    public var runtimesFolder: URL { root.appending(path: "Runtimes", directoryHint: .isDirectory) }
    /// One `agneta/trace@1` JSONL file per task (docs/DIAGNOSTICS.md).
    public var tracesFolder: URL { root.appending(path: "Traces", directoryHint: .isDirectory) }
    public func home(of account: AccountRecord) -> URL { accountsFolder.appending(path: account.id, directoryHint: .isDirectory) }

    /// Opens the database, after making the data folder owner-only.
    public func open() throws -> AgnetaDatabase {
        try Self.ownerOnly(root)
        return try AgnetaDatabase(file: databaseFile, importing: legacyFile)
    }

    /// Makes a folder owner-only (0700), creating it if needed, on every launch rather than only when it's made:
    /// folders made along the way to another one, or by an older build, get the default 0755. Everything inside an
    /// owner-only folder is out of other users' reach, whatever its own permissions.
    public static func ownerOnly(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path(percentEncoded: false))
    }
}
