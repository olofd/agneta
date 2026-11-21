// agneta/result: what a session may ask results in, and what one prompt asks for.
//
// A session declares its schemas when it opens (`session/new`, `load`, `fork`), because engines take their MCP tools
// only then: each schema becomes one tool, `submit_<name>`, whose input is that schema. A prompt then asks for one of
// them by name, or a session's `every` asks for one on each prompt. Parsed as strictly as the session policy: an
// unknown field is refused, never ignored, naming the extension (`-32602`, `unenforceable: ["agneta/result"]`).
// docs/APP_PROTOCOL.md, Structured results.
import Foundation

public struct ResultDeclaration: Sendable {
    public static let key = "agneta/result"
    /// At most this many schemas in one session: each is a tool in the model's tool list on every call.
    public static let maxSchemas = 8
    /// What all of a session's schemas may weigh together, as JSON.
    public static let maxTotalBytes = 32_768

    /// The schemas by name, compiled.
    public let schemas: [String: ResultSchema]
    /// The schema every prompt asks for unless it opts out, or nil.
    public let every: String?

    /// The declaration as the app sent it, kept with the task so a resume or fork declares the same.
    public var recorded: JSONValue {
        var fields: [String: JSONValue] = [
            "schemas": .object(schemas.mapValues(\.source))
        ]
        if let every { fields["every"] = .string(every) }
        return .object(fields)
    }

    /// The names in a stable order (the tool list's).
    public var names: [String] { schemas.keys.sorted() }

    /// The tool that submits the named result.
    public static func tool(for name: String) -> String { "submit_" + name }

    /// The result name a tool submits, if it's one of this declaration's.
    public func name(forTool tool: String) -> String? {
        guard tool.hasPrefix("submit_") else { return nil }
        let name = String(tool.dropFirst("submit_".count))
        return schemas[name] != nil ? name : nil
    }

    /// `{"schemas": {name: schema, …}, "every": name}` or the shorthand `{"schema": schema}` (one schema named
    /// `result`, asked for on every prompt). Nil or null: no results declared.
    public static func parse(_ value: JSONValue?) throws(PolicyRejection) -> ResultDeclaration? {
        guard let value, value != .null else { return nil }
        guard let object = value.objectValue else {
            throw refused(#"it must be an object, such as {"schema": {…}} or {"schemas": {"invoice": {…}}}"#)
        }
        if let unknown = object.keys.sorted().first(where: { !["schema", "schemas", "every"].contains($0) }) {
            throw refused("unknown field \(unknown)")
        }
        var raw: [String: JSONValue]
        var every = object["every"]?.stringValue
        switch (object["schema"], object["schemas"]) {
        case (let schema?, nil):
            guard object["every"] == nil else {
                throw refused(#""schema" already asks for its result on every prompt; "every" goes with "schemas""#)
            }
            raw = ["result": schema]
            every = "result"
        case (nil, let schemas?):
            guard let map = schemas.objectValue, !map.isEmpty else {
                throw refused(#""schemas" must name at least one schema: {"invoice": {…}}"#)
            }
            raw = map
        case (nil, nil): throw refused(#"declare "schema" or "schemas""#)
        default: throw refused(#"declare either "schema" or "schemas", not both"#)
        }
        if object["every"] != nil, every == nil { throw refused(#""every" must be a schema's name"#) }
        guard raw.count <= maxSchemas else {
            throw refused("a session may declare at most \(maxSchemas) schemas; it declared \(raw.count)")
        }
        let total = (try? JSONCoding.encode(JSONValue.object(raw)).count) ?? Int.max
        guard total <= maxTotalBytes else {
            throw refused("the schemas are \(total) bytes together; at most \(maxTotalBytes) are allowed")
        }
        var compiled: [String: ResultSchema] = [:]
        for name in raw.keys.sorted() {
            guard validName(name) else {
                throw refused(
                    "\"\(name)\" isn't a usable name: lowercase letters, digits and _, starting with a letter, "
                        + "at most 32 characters")
            }
            do {
                compiled[name] = try ResultSchema.compile(raw[name]!)
            } catch {
                throw refused("schema \"\(name)\" \(error.message)")
            }
        }
        if let every, compiled[every] == nil { throw refused("\"every\" names \"\(every)\", which isn't declared") }
        return ResultDeclaration(schemas: compiled, every: every)
    }

    static func validName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, ("a"..."z").contains(first), name.unicodeScalars.count <= 32
        else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    static func refused(_ reason: String) -> PolicyRejection { PolicyRejection(field: key, reason: reason) }
}

/// What one prompt asks for: a declared schema, how many submissions the model gets.
public struct ResultRequest: Sendable, Equatable {
    /// Submissions the model may make in one turn by default, and at most.
    public static let defaultAttempts = 3
    public static let maxAttempts = 10

    public var name: String
    public var attempts: Int

    /// The prompt's `_meta["agneta/result"]` against the session's declaration: `{"name": …}`, optionally with
    /// `attempts`; `false` to opt out of `every` for this prompt; nothing to take `every`. Nil: no result this turn.
    public static func parse(_ value: JSONValue?, declaration: ResultDeclaration?) throws(PolicyRejection)
        -> ResultRequest?
    {
        switch value {
        case nil, .null?:
            return declaration?.every.map { ResultRequest(name: $0, attempts: defaultAttempts) }
        case .bool(false)?:
            return nil
        case .object(let object)?:
            guard let declaration else {
                throw ResultDeclaration.refused(
                    "this session declared no results; declare them in _meta[\"agneta/result\"] when it opens")
            }
            if object["schema"] != nil {
                throw ResultDeclaration.refused(
                    #"a schema is declared when the session opens and asked for by name here: {"name": "…"}"#)
            }
            if let unknown = object.keys.sorted().first(where: { !["name", "attempts"].contains($0) }) {
                throw ResultDeclaration.refused("unknown field \(unknown)")
            }
            guard let name = object["name"].map({ $0.stringValue }) ?? declaration.every else {
                throw ResultDeclaration.refused(#""name" must be a declared schema's name"#)
            }
            guard declaration.schemas[name] != nil else {
                throw ResultDeclaration.refused(
                    "\"\(name)\" wasn't declared when the session opened (declared: "
                        + declaration.names.joined(separator: ", ") + ")")
            }
            var attempts = defaultAttempts
            if let given = object["attempts"] {
                guard let n = given.intValue, (1...Int64(maxAttempts)).contains(n), given.boolValue == nil else {
                    throw ResultDeclaration.refused("attempts must be a whole number from 1 to \(maxAttempts)")
                }
                attempts = Int(n)
            }
            return ResultRequest(name: name, attempts: attempts)
        default:
            throw ResultDeclaration.refused(#"a prompt asks with {"name": "…"}, or false to ask for none"#)
        }
    }
}
