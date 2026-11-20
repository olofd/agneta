// agneta/appTools: how a session's engine offers the app's own MCP tools to the model. Claude Code defers them behind
// its tool search by default (only their names reach the model, and it loads each with ToolSearch before calling it);
// an app whose tools are the instructions for its job can ask for them up front. Not part of agneta/policy: it says
// nothing about what a session may reach, only what the model sees first. Mapped per engine in docs/ENGINES.md.
import Foundation

public enum AppToolsLoad: String, Sendable, Equatable {
    /// As the engine does by default: Claude Code defers them, the other engines load them up front.
    case engine
    /// Every tool's name, description and schema in the model's context from the first request, on every engine.
    case always

    public static let key = "agneta/appTools"

    /// `{"load": "always" | "engine"}`, or nothing for `engine`. Anything else is refused, naming the extension.
    public static func parse(_ value: JSONValue?) throws -> AppToolsLoad {
        guard let value, value != .null else { return .engine }
        guard let object = value.objectValue else {
            throw PolicyRejection(field: key, reason: "it must be an object, such as {\"load\": \"always\"}")
        }
        if let unknown = object.keys.sorted().first(where: { $0 != "load" }) {
            throw PolicyRejection(field: key, reason: "unknown field \(unknown)")
        }
        guard let load = object["load"] else { return .engine }
        guard let text = load.stringValue, let parsed = AppToolsLoad(rawValue: text) else {
            throw PolicyRejection(field: key, reason: "load must be \"always\" or \"engine\"")
        }
        return parsed
    }
}
