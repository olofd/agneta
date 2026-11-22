import Foundation

public let resultExtension = "agneta/result"
private let wrapperComment = "@agneta-ai/client: wraps a non-object root as { value }"

/// Named JSON Schemas declared when a session opens. Non-object roots are wrapped for the wire and unwrapped by `ask`.
public struct ResultDeclaration: Sendable, Equatable {
    public let schemas: [String: JSONValue]
    public let every: String?
    public init(schemas: [String: JSONValue], every: String? = nil) { self.schemas = schemas; self.every = every }
    public init(schema: JSONValue) { self.init(schemas: ["result": schema], every: "result") }
    func wire() throws -> JSONValue {
        guard !schemas.isEmpty, schemas.count <= 8, every.map({ schemas[$0] != nil }) ?? true else {
            throw AgnetaError(
                .invalidParams, "Declare one to eight result schemas, and an every name present in that declaration.")
        }
        var values: [String: JSONValue] = [:]
        for (name, schema) in schemas {
            guard name != "any", name.utf8.count <= 32,
                name.range(of: #"^[a-z][a-z0-9_]*$"#, options: .regularExpression) != nil, !name.contains("__"),
                schema.object != nil
            else { throw AgnetaError(.invalidParams, "Result schemas need valid names and JSON Schema objects.") }
            values[name] = prepareResultSchema(schema)
        }
        var result: [String: JSONValue] = ["schemas": .object(values)]
        if let every { result["every"] = .string(every) }
        return .object(result)
    }
}
public struct SessionResults: Codable, Sendable, Equatable {
    public let declared: [String]
    public let every: String?
    public let mechanism: String
    public let schemas: [String: JSONValue]?
}
public struct ResultIssue: Codable, Sendable, Equatable {
    public let path: String
    public let keyword: String
    public let message: String
    public let schemaPath: String
}
public struct StructuredResult: JSONBacked {
    public enum Status: String, Sendable { case valid, invalid, missing }
    public let raw: JSONValue
    public init(raw: JSONValue) throws {
        guard let status = raw["status"]?.string, Status(rawValue: status) != nil,
            raw["name"]?.string != nil, raw["mechanism"]?.string != nil,
            let attempts = raw["attempts"]?.integer, attempts >= 0,
            status != "valid" || raw["value"] != nil,
            status != "missing" || raw["reason"]?.string != nil
        else {
            throw AgnetaError(.protocolViolation, "Malformed structured-result report.")
        }
        if let issues = raw["issues"], (try? issues.decode([ResultIssue].self)) == nil {
            throw AgnetaError(.protocolViolation, "Malformed structured-result issues.")
        }
        self.raw = raw
    }
    public var status: Status { Status(rawValue: raw["status"]!.string!)! }
    public var name: String { raw["name"]!.string! }
    public var mechanism: String { raw["mechanism"]!.string! }
    public var attempts: Int64 { raw["attempts"]!.integer! }
    public var value: JSONValue? { raw["value"] }
    public var issues: [ResultIssue] { (try? raw["issues"]?.decode([ResultIssue].self)) ?? [] }
    public var reason: String? { raw["reason"]?.string }
}
public enum ResultAsk: Sendable {
    case named(String, attempts: Int? = nil)
    case disabled
    func wire() throws -> JSONValue {
        switch self {
        case .disabled: return false
        case .named(let name, let attempts):
            var value: [String: JSONValue] = ["name": .string(name)]
            if let attempts {
                guard (1...10).contains(attempts) else {
                    throw AgnetaError(.invalidParams, "Result attempts must be between 1 and 10.")
                }
                value["attempts"] = .integer(Int64(attempts))
            }
            return .object(value)
        }
    }
}
public struct ResultFailure: Error, LocalizedError, Sendable {
    public enum Kind: Sendable { case missing, invalid, decoding }
    public let kind: Kind
    public let report: StructuredResult
    public let turnResult: TurnResult
    public let message: String
    /// The app-facing value and issue paths, unwrapped for a non-object schema root.
    public let value: JSONValue?
    public let submitted: JSONValue?
    public let issues: [ResultIssue]
    public enum Source: Sendable { case agneta, client }
    public var source: Source { kind == .decoding ? .client : .agneta }
    public var valueOmitted: String? { report.raw["valueOmitted"]?.string }
    public var errorDescription: String? { message }

    init(kind: Kind, report: StructuredResult, turnResult: TurnResult, message: String, wrapped: Bool) {
        self.kind = kind; self.report = report; self.turnResult = turnResult; self.message = message
        submitted = report.value
        value = wrapped ? report.value?["value"] : report.value
        if kind == .decoding {
            issues = [ResultIssue(path: "", keyword: "decode", message: message, schemaPath: "")]
        } else {
            issues = wrapped ? report.issues.map(unwrapResultIssue) : report.issues
        }
    }
}
public struct AskDetails<Value: Sendable>: Sendable {
    public let value: Value
    public let report: StructuredResult
    public let turnResult: TurnResult
}
@MainActor public final class Ask<Value: Decodable & Sendable> {
    public let turn: Turn
    private let name: String
    private let wrapped: Bool
    init(turn: Turn, name: String, wrapped: Bool) { self.turn = turn; self.name = name; self.wrapped = wrapped }
    public var value: Value { get async throws { try await details.value } }
    public var details: AskDetails<Value> {
        get async throws {
            let result: TurnResult
            do { result = try await turn.result } catch var error as AgnetaError {
                if let report = error.structured, report.status == .valid, report.name == name,
                    let value = wrapped ? report.value?["value"] : report.value
                {
                    let issues: [ResultIssue]?
                    do { _ = try value.decode(Value.self); issues = nil } catch {
                        issues = [
                            ResultIssue(
                                path: "", keyword: "decode",
                                message: "The accepted value could not be decoded as \(Value.self).", schemaPath: "")
                        ]
                    }
                    error.accepted = AcceptedResult(value: value, issues: issues)
                }
                throw error
            }
            guard let report = result.structured, report.name == name else {
                throw AgnetaError(.protocolViolation, "The prompt returned no result for \(name).")
            }
            switch report.status {
            case .missing:
                throw ResultFailure(
                    kind: .missing, report: report, turnResult: result,
                    message: "No result was submitted: \(report.reason ?? "unknown reason").", wrapped: wrapped)
            case .invalid:
                throw ResultFailure(
                    kind: .invalid, report: report, turnResult: result,
                    message: "Agneta refused the result against its schema.", wrapped: wrapped)
            case .valid:
                guard let value = wrapped ? report.value?["value"] : report.value else {
                    throw AgnetaError(.protocolViolation, "The result wrapper has no value.")
                }
                do { return AskDetails(value: try value.decode(Value.self), report: report, turnResult: result) } catch
                {
                    throw ResultFailure(
                        kind: .decoding, report: report, turnResult: result,
                        message: "The accepted result could not be decoded as \(Value.self).", wrapped: wrapped)
                }
            }
        }
    }
}

extension Session {
    /// Decode a result Agneta accepted. Decoding may reject a value further; it cannot make an invalid report valid.
    public func ask<Value: Decodable & Sendable>(
        _ input: String, name: String? = nil, as type: Value.Type,
        attempts: Int? = nil, options: RequestOptions = .init()
    ) throws -> Ask<Value> {
        guard supports(resultExtension) else {
            throw AgnetaError(.unsupportedByAgneta, "This Agneta does not offer structured results.")
        }
        guard let results, let name = name ?? results.every, results.declared.contains(name) else {
            throw AgnetaError(.invalidParams, "Ask for one of the session's declared result schemas.")
        }
        guard let schema = results.schemas?[name] else {
            throw AgnetaError(
                .protocolViolation,
                "This session does not report its saved result schemas. Pass results when loading it.")
        }
        let turn = try prompt(input, options: options, result: .named(name, attempts: attempts))
        return Ask(turn: turn, name: name, wrapped: schema["$comment"]?.string == wrapperComment)
    }
}
extension AgnetaClient {
    /// One result in a temporary session, closed on success or failure. No automatic retry or extra prompt.
    public func ask<Value: Decodable & Sendable>(
        _ input: String, schema: JSONValue, as type: Value.Type,
        options: SessionOptions = .init(), attempts: Int? = nil
    ) async throws -> AskDetails<Value> {
        var options = options
        options.results = ResultDeclaration(schema: schema)
        if options.policy == nil { options.policy = Policy(tools: .appOnly, approval: .neverAsk) }
        let session = try await newSession(options)
        do {
            let answer = try session.ask(input, as: type, attempts: attempts)
            let result = try await answer.details
            await closeOneShot(session)
            return result
        } catch {
            await closeOneShot(session)
            throw error
        }
    }
    private func closeOneShot(_ session: Session) async {
        // Cleanup must run even when the caller's task was cancelled. Preserve the answer/original failure,
        // but never leave a one-shot engine alive if its close cannot be acknowledged.
        await Task { @MainActor in
            do { try await session.close() } catch { session.connection.close() }
        }.value
    }
}

// Walk schema positions only. Enum/default/examples values are data, even if their keys look like schema keywords.
private func prepareResultSchema(_ schema: JSONValue) -> JSONValue {
    if schema["type"] == "object" || schema["type"] == ["object"] { return schema }
    let schemaKeys: Set<String> = [
        "items", "additionalItems", "additionalProperties", "not", "propertyNames", "contains", "if", "then", "else",
        "unevaluatedItems", "unevaluatedProperties", "contentSchema"
    ]
    let listKeys: Set<String> = ["allOf", "anyOf", "oneOf", "prefixItems"]
    let mapKeys: Set<String> = ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas"]
    func moved(_ value: JSONValue) -> JSONValue {
        guard var object = value.object else { return value }
        for (key, item) in object {
            if key == "$ref", let ref = item.string, ref.hasPrefix("#"),
                let pointer = String(ref.dropFirst()).removingPercentEncoding
            {
                if !pointer.hasPrefix("/$defs/"), !pointer.hasPrefix("/definitions/"),
                    pointer.isEmpty || pointer.hasPrefix("/")
                {
                    object[key] = .string("#/properties/value" + ref.dropFirst())
                }
            } else if schemaKeys.contains(key) {
                object[key] = item.array.map { .array($0.map(moved)) } ?? moved(item)
            } else if listKeys.contains(key), let array = item.array {
                object[key] = .array(array.map(moved))
            } else if mapKeys.contains(key), let map = item.object {
                object[key] = .object(map.mapValues(moved))
            } else if key == "dependencies", let map = item.object {
                object[key] = .object(map.mapValues { $0.array == nil ? moved($0) : $0 })
            }
        }
        return .object(object)
    }
    var inner = schema.object!, wrapper: [String: JSONValue] = [:]
    for key in ["$schema", "$id", "$defs", "definitions"] {
        if let value = inner.removeValue(forKey: key) {
            wrapper[key] =
                ["$defs", "definitions"].contains(key)
                ? value.object.map { .object($0.mapValues(moved)) } ?? value : value
        }
    }
    wrapper.merge(
        [
            "$comment": .string(wrapperComment), "type": "object", "properties": ["value": moved(.object(inner))],
            "required": ["value"], "additionalProperties": false
        ], uniquingKeysWith: { _, last in last })
    return .object(wrapper)
}

private func unwrapResultIssue(_ issue: ResultIssue) -> ResultIssue {
    func strip(_ value: String, prefix: String) -> String? {
        if value == prefix { return "" }
        return value.hasPrefix(prefix + "/") ? String(value.dropFirst(prefix.count)) : nil
    }
    if let path = strip(issue.path, prefix: "/value"),
        let schemaPath = strip(issue.schemaPath, prefix: "/properties/value")
    {
        return ResultIssue(path: path, keyword: issue.keyword, message: issue.message, schemaPath: schemaPath)
    }
    return ResultIssue(
        path: "", keyword: issue.keyword,
        message:
            "the model didn't submit the value as { \"value\": … } (\(issue.path.isEmpty ? "the submission" : issue.path): \(issue.message))",
        schemaPath: "")
}
