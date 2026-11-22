import Foundation

/// All content fields are retained, including annotations and future ACP additions.
public struct ContentBlock: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) throws {
        try requireObject(raw)
        guard raw["type"]?.string != nil else { throw AgnetaError(.protocolViolation, "Content block has no type.") }
        self.raw = raw
    }
    private init(_ object: [String: JSONValue]) { raw = .object(object) }
    public static func text(_ text: String) -> Self { Self(["type": "text", "text": .string(text)]) }
    public static func image(data: String, mimeType: String) -> Self {
        Self(["type": "image", "data": .string(data), "mimeType": .string(mimeType)])
    }
    public static func audio(data: String, mimeType: String) -> Self {
        Self(["type": "audio", "data": .string(data), "mimeType": .string(mimeType)])
    }
    public static func resourceLink(uri: String, name: String) -> Self {
        Self(["type": "resource_link", "uri": .string(uri), "name": .string(name)])
    }
    public static func resource(_ resource: JSONValue) -> Self { Self(["type": "resource", "resource": resource]) }
    public var type: String { raw["type"]!.string! }
    public var text: String? { raw["text"]?.string }
}

/// ACP updates are extensible: `kind` identifies the update, while `raw` keeps every field unchanged.
public struct SessionUpdate: JSONBacked {
    public let raw: JSONValue
    public init(raw: JSONValue) throws {
        try requireObject(raw)
        guard raw["sessionUpdate"]?.string != nil else {
            throw AgnetaError(.protocolViolation, "Session update has no kind.")
        }
        self.raw = raw
    }
    public var kind: String { raw["sessionUpdate"]!.string! }
    public var content: ContentBlock? { raw["content"].flatMap { try? ContentBlock(raw: $0) } }
    public var text: String? { content?.type == "text" ? content?.text : nil }
    public var toolCallID: String? { raw["toolCallId"]?.string }
}
public struct ToolCallState: Sendable, Equatable, Identifiable {
    public let id: String
    public internal(set) var raw: [String: JSONValue]
    public var title: String { raw["title"]?.string ?? "" }
    public var status: String? { raw["status"]?.string }
    public var name: String? { raw["name"]?.string }
    public var kind: String? { raw["kind"]?.string }
    public var content: [JSONValue]? { raw["content"]?.array }
    public var rawInput: JSONValue? { raw["rawInput"] }
    public var rawOutput: JSONValue? { raw["rawOutput"] }
}
public struct ConfigOption: JSONBacked, Identifiable {
    public let raw: JSONValue
    public init(raw: JSONValue) throws {
        try requireObject(raw)
        guard raw["id"]?.string != nil else { throw AgnetaError(.protocolViolation, "Config option has no id.") }
        self.raw = raw
    }
    public var id: String { raw["id"]!.string! }
    public var name: String { raw["name"]?.string ?? id }
    public var category: String? { raw["category"]?.string }
    public var type: String? { raw["type"]?.string }
    public var currentValue: JSONValue? { raw["currentValue"] }
    public struct Choice: Sendable, Equatable {
        public let value: String
        public let name: String
        public let description: String?
        public let group: String?
    }
    public var choices: [Choice] {
        func choice(_ value: JSONValue, group: String? = nil) -> Choice? {
            guard let id = value["value"]?.string else { return nil }
            return Choice(
                value: id, name: value["name"]?.string ?? id, description: value["description"]?.string, group: group)
        }
        var result = (raw["options"]?.array ?? []).flatMap { item -> [Choice] in
            if let group = item["group"]?.string {
                return (item["options"]?.array ?? []).compactMap { choice($0, group: group) }
            }
            return choice(item).map { [$0] } ?? []
        }
        if let current = currentValue?.string, !result.contains(where: { $0.value == current }) {
            result.insert(Choice(value: current, name: current, description: nil, group: nil), at: 0)
        }
        return result
    }
}
public struct HTTPMCPServer: Codable, Sendable, Equatable {
    public struct Header: Codable, Sendable, Equatable {
        public var name: String
        public var value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }
    public var type = "http"
    public var name: String
    public var url: String
    public var headers: [Header]
    public init(name: String, url: URL, token: String? = nil, headers: [Header] = []) {
        self.name = name; self.url = url.absoluteString
        self.headers = (token.map { [Header(name: "Authorization", value: "Bearer \($0)")] } ?? []) + headers
    }
}
public struct PermissionOption: Codable, Sendable, Equatable {
    public let optionId: String
    public let name: String
    public let kind: String
}
public struct PermissionRequest: Codable, Sendable, Equatable {
    public let sessionId: String
    public let toolCall: JSONValue
    public let options: [PermissionOption]
}
public enum PermissionAnswer: Sendable, Equatable {
    case allow, reject, cancel, option(String)
    public func response(options: [PermissionOption]) -> JSONValue {
        let kinds: [String]
        switch self {
        case .allow: kinds = ["allow_once", "allow_always"]
        case .reject: kinds = ["reject_once", "reject_always"]
        case .cancel: kinds = []
        case .option(let id):
            guard options.contains(where: { $0.optionId == id }) else { return ["outcome": ["outcome": "cancelled"]] }
            return ["outcome": ["outcome": "selected", "optionId": .string(id)]]
        }
        if let option = kinds.lazy.compactMap({ kind in options.first { $0.kind == kind } }).first {
            return ["outcome": ["outcome": "selected", "optionId": .string(option.optionId)]]
        }
        return ["outcome": ["outcome": "cancelled"]]
    }
}
public typealias PermissionHandler = @MainActor (PermissionRequest) async throws -> PermissionAnswer
