// Structured results: the JSON Schema an app asks a result in, compiled once when it's declared.
//
// Agneta enforces a documented subset of JSON Schema 2020-12 (docs/APP_PROTOCOL.md, Structured results), the same on
// every engine. A schema that uses anything outside it is refused, naming the keyword and where it is, never
// weakened: a schema Agneta can't enforce isn't one it may claim to enforce. Compiling resolves every `$ref` to a
// node, compiles every pattern and checks the limits, so validating a value (ResultValidator) does no parsing and
// can't fail on the schema.
import Foundation

/// Why a schema can't be used: where in the schema (a JSON Pointer), and why.
public struct ResultSchemaRejection: Error, Equatable, Sendable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    /// For error messages: "at /properties/total: …", or the reason alone at the root.
    public var message: String { path.isEmpty ? reason : "at \(path): \(reason)" }
}

public struct ResultSchema: Sendable {
    /// Bounds on what a schema may be. A value's own bound (its size) is the result server's.
    public struct Limits: Sendable, Equatable {
        /// The schema's size as JSON, in bytes: it's in the model's tool list on every call of the session.
        public var bytes: Int
        /// How deeply schemas may nest inside each other.
        public var depth: Int
        /// How many schemas (subschemas included) one may hold.
        public var nodes: Int
        /// How many values all its `enum`s and `const`s may list together.
        public var enumValues: Int
        /// The longest `pattern` (or `patternProperties` key), in characters.
        public var patternLength: Int

        public static let standard = Limits(
            bytes: 16_384, depth: 32, nodes: 1_000, enumValues: 1_000, patternLength: 1_000)
    }

    /// The JSON types a value can have, as `type` names them.
    enum Kind: String, CaseIterable, Sendable {
        case null, boolean, object, array, number, string, integer
    }

    /// One compiled schema. Children are indices into `nodes`. A class, so checking passes a reference down the stack
    /// rather than copying every field into each frame (checking recurses once per level of the value). Filled in
    /// while compiling, never changed after.
    final class Node: @unchecked Sendable {
        /// Where it is in the app's schema (a JSON Pointer), for messages.
        var pointer: String
        init(pointer: String) { self.pointer = pointer }
        /// A boolean schema: `true` accepts anything, `false` nothing.
        var always: Bool?
        var types: Set<Kind>?
        var reference: Int?
        var enumValues: [JSONValue]?
        /// `const` (`const: null` is `.null`, not nil).
        var constant: JSONValue?
        var allOf: [Int] = []
        var anyOf: [Int] = []
        var oneOf: [Int] = []
        var not: Int?
        // Objects
        /// By the name's UTF-8 bytes: JSON Schema compares names by code points, and Swift's String equality would
        /// call two spellings of "é" one name.
        var properties: [Data: Int] = [:]
        var patternProperties: [(Pattern, Int)] = []
        var additionalProperties: Int?
        var propertyNames: Int?
        var required: [String] = []
        var minProperties: Int?
        var maxProperties: Int?
        // Arrays
        var prefixItems: [Int] = []
        var items: Int?
        var minItems: Int?
        var maxItems: Int?
        var uniqueItems = false
        // Numbers, kept as the schema gave them so integers compare exactly.
        var minimum: JSONValue?
        var maximum: JSONValue?
        var exclusiveMinimum: JSONValue?
        var exclusiveMaximum: JSONValue?
        var multipleOf: JSONValue?
        // Strings
        var minLength: Int?
        var maxLength: Int?
        var pattern: Pattern?

        /// Whether it says anything about an object's members (else checking an object needn't walk them).
        var constrainsObjects: Bool {
            if !properties.isEmpty || !patternProperties.isEmpty || !required.isEmpty { return true }
            if additionalProperties != nil || propertyNames != nil { return true }
            return minProperties != nil || maxProperties != nil
        }

        /// Whether it says anything about an array's items.
        var constrainsArrays: Bool {
            if !prefixItems.isEmpty || uniqueItems { return true }
            return items != nil || minItems != nil || maxItems != nil
        }
    }

    /// The schema as the app sent it.
    public let source: JSONValue
    let nodes: [Node]

    /// Compiles `schema`, or refuses it with the first thing outside the subset or over a limit.
    public static func compile(_ schema: JSONValue, limits: Limits = .standard) throws(ResultSchemaRejection)
        -> ResultSchema
    {
        let size = (try? JSONCoding.encode(schema).count) ?? Int.max
        guard size <= limits.bytes else {
            throw ResultSchemaRejection(
                path: "", reason: "the schema is \(size) bytes; at most \(limits.bytes) are allowed")
        }
        guard case .object = schema else {
            throw ResultSchemaRejection(path: "", reason: "the schema's root must be an object schema")
        }
        guard schema["type"] == "object" || schema["type"] == ["object"] else {
            throw ResultSchemaRejection(
                path: "", reason: #"the schema's root must have "type": "object" (a result is an object)"#)
        }
        var compiler = Compiler(limits: limits)
        let root = try compiler.compile(schema, pointer: "", depth: 0, isRoot: true)
        try compiler.resolveReferences()
        let order = try compiler.refuseCyclesThatDontDescend()
        try compiler.boundWork(order)
        precondition(root == 0)
        return ResultSchema(source: schema, nodes: compiler.nodes)
    }
}

private struct Compiler {
    let limits: ResultSchema.Limits
    var nodes: [ResultSchema.Node] = []
    /// Every compiled schema by its pointer, for `$ref`.
    var byPointer: [String: Int] = [:]
    /// References to resolve once every schema is compiled: the node, the `$ref` as written, and where it was.
    var references: [(node: Int, target: String, pointer: String)] = []
    var enumValues = 0

    init(limits: ResultSchema.Limits) { self.limits = limits }

    /// Keywords that describe and don't constrain: accepted, with the JSON type each must have, and not enforced.
    static let annotations: [String: String] = [
        "title": "string", "description": "string", "default": "", "examples": "array", "format": "string",
        "$comment": "string", "deprecated": "boolean", "readOnly": "boolean", "writeOnly": "boolean"
    ]
    /// Keywords that may stand beside `$ref`: annotations only, so `$ref` means the same in every draft.
    static let applicators: Set<String> = [
        "type", "enum", "const", "allOf", "anyOf", "oneOf", "not", "properties", "patternProperties",
        "additionalProperties", "propertyNames", "required", "minProperties", "maxProperties", "prefixItems", "items",
        "minItems", "maxItems", "uniqueItems", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
        "multipleOf", "minLength", "maxLength", "pattern"
    ]
    /// Common keywords outside the subset, with what to write instead.
    static let hints: [String: String] = [
        "nullable": #"write "type": ["string", "null"] instead of "nullable""#,
        "additionalItems": #"use "prefixItems" for the leading items and "items" for the rest"#,
        "dependencies": "it isn't in the subset Agneta enforces",
        "if": "conditional schemas (if, then, else) aren't in the subset Agneta enforces; use anyOf or oneOf",
        "then": "conditional schemas (if, then, else) aren't in the subset Agneta enforces; use anyOf or oneOf",
        "else": "conditional schemas (if, then, else) aren't in the subset Agneta enforces; use anyOf or oneOf",
        "$dynamicRef": "dynamic references aren't in the subset Agneta enforces",
        "$anchor": ##"anchors aren't in the subset Agneta enforces; use "$ref": "#/$defs/…""##
    ]

    /// Compiles the schema at `pointer` and returns its node's index.
    mutating func compile(_ schema: JSONValue, pointer: String, depth: Int, isRoot: Bool = false)
        throws(ResultSchemaRejection) -> Int
    {
        guard depth <= limits.depth else {
            throw ResultSchemaRejection(
                path: pointer, reason: "schemas nest more than \(limits.depth) deep")
        }
        guard nodes.count < limits.nodes else {
            throw ResultSchemaRejection(
                path: pointer, reason: "the schema holds more than \(limits.nodes) schemas")
        }
        let index = nodes.count
        nodes.append(ResultSchema.Node(pointer: pointer))
        byPointer[pointer] = index
        switch schema {
        case .bool(let value):
            nodes[index].always = value
            return index
        case .object(let fields):
            let node = ResultSchema.Node(pointer: pointer)
            if fields["$ref"] != nil {
                if let other = fields.keys.sorted().first(where: { Self.applicators.contains($0) }) {
                    throw ResultSchemaRejection(
                        path: pointer + "/" + escape(other),
                        reason: #"keywords beside "$ref" would mean different things in different drafts; "#
                            + #"put them in "allOf" with the "$ref""#)
                }
            }
            for key in fields.keys.sorted() {
                let value = fields[key]!
                let at = pointer + "/" + escape(key)
                try keyword(key, value, at: at, node: node, index: index, depth: depth, isRoot: isRoot)
            }
            nodes[index] = node
            return index
        default:
            throw ResultSchemaRejection(path: pointer, reason: "a schema must be an object or true or false")
        }
    }

    private mutating func keyword(
        _ key: String, _ value: JSONValue, at: String, node: ResultSchema.Node, index: Int, depth: Int,
        isRoot: Bool
    ) throws(ResultSchemaRejection) {
        if let kind = Self.annotations[key] {
            let fits: Bool =
                switch kind {
                case "string": value.stringValue != nil
                case "array": value.arrayValue != nil
                case "boolean": value.boolValue != nil
                default: true
                }
            guard fits else { throw notA("a \(kind)", at) }
            return
        }
        switch key {
        case "$schema":
            guard isRoot else { throw ResultSchemaRejection(path: at, reason: #""$schema" belongs at the root"#) }
            let known = [
                "https://json-schema.org/draft/2020-12/schema", "http://json-schema.org/draft-07/schema#",
                "http://json-schema.org/draft-07/schema"
            ]
            guard let uri = value.stringValue, known.contains(uri) else {
                throw ResultSchemaRejection(path: at, reason: "only JSON Schema 2020-12 and draft-07 are supported")
            }
        case "$id":
            guard value.stringValue != nil else { throw notA("a string", at) }
            guard isRoot else {
                throw ResultSchemaRejection(
                    path: at, reason: #""$id" inside a schema changes what "$ref" points to; keep it at the root"#)
            }
        case "$defs", "definitions":
            guard let defs = value.objectValue else { throw notA("an object of schemas", at) }
            for name in defs.keys.sorted() {
                _ = try compile(defs[name]!, pointer: at + "/" + escape(name), depth: depth + 1)
            }
        case "$ref":
            guard let target = value.stringValue else { throw notA("a string", at) }
            references.append((index, target, at))
        case "type":
            node.types = try types(value, at: at)
        case "enum":
            guard let values = value.arrayValue, !values.isEmpty else { throw notA("a non-empty array", at) }
            try tally(values.count, at: at)
            try matchable(values, at: at)
            node.enumValues = values
        case "const":
            try tally(1, at: at)
            try matchable([value], at: at)
            node.constant = value
        case "allOf", "anyOf", "oneOf":
            guard let list = value.arrayValue, !list.isEmpty else { throw notA("a non-empty array of schemas", at) }
            var children: [Int] = []
            for (i, child) in list.enumerated() {
                children.append(try compile(child, pointer: at + "/\(i)", depth: depth + 1))
            }
            switch key {
            case "allOf": node.allOf = children
            case "anyOf": node.anyOf = children
            default: node.oneOf = children
            }
        case "not":
            node.not = try compile(value, pointer: at, depth: depth + 1)
        case "properties":
            guard let fields = value.objectValue else { throw notA("an object of schemas", at) }
            for name in fields.keys.sorted() {
                node.properties[Data(name.utf8)] = try compile(
                    fields[name]!, pointer: at + "/" + escape(name), depth: depth + 1)
            }
        case "patternProperties":
            guard let fields = value.objectValue else { throw notA("an object of schemas", at) }
            for source in fields.keys.sorted() {
                let pattern = try compilePattern(source, at: at + "/" + escape(source))
                let child = try compile(fields[source]!, pointer: at + "/" + escape(source), depth: depth + 1)
                node.patternProperties.append((pattern, child))
            }
        case "additionalProperties":
            node.additionalProperties = try compile(value, pointer: at, depth: depth + 1)
        case "propertyNames":
            node.propertyNames = try compile(value, pointer: at, depth: depth + 1)
        case "required":
            guard let names = value.arrayValue?.compactMap(\.stringValue), names.count == value.arrayValue?.count,
                Set(names).count == names.count
            else { throw notA("an array of distinct property names", at) }
            node.required = names
        case "prefixItems":
            guard let list = value.arrayValue, !list.isEmpty else { throw notA("a non-empty array of schemas", at) }
            for (i, child) in list.enumerated() {
                node.prefixItems.append(try compile(child, pointer: at + "/\(i)", depth: depth + 1))
            }
        case "items":
            if value.arrayValue != nil {
                throw ResultSchemaRejection(
                    path: at, reason: #"an array of schemas in "items" is draft-07's tuple form; use "prefixItems""#)
            }
            node.items = try compile(value, pointer: at, depth: depth + 1)
        case "uniqueItems":
            guard let flag = value.boolValue else { throw notA("true or false", at) }
            node.uniqueItems = flag
        case "minProperties": node.minProperties = try count(value, at: at)
        case "maxProperties": node.maxProperties = try count(value, at: at)
        case "minItems": node.minItems = try count(value, at: at)
        case "maxItems": node.maxItems = try count(value, at: at)
        case "minLength": node.minLength = try count(value, at: at)
        case "maxLength": node.maxLength = try count(value, at: at)
        case "minimum": node.minimum = try number(value, at: at)
        case "maximum": node.maximum = try number(value, at: at)
        case "exclusiveMinimum": node.exclusiveMinimum = try number(value, at: at, draft4: true)
        case "exclusiveMaximum": node.exclusiveMaximum = try number(value, at: at, draft4: true)
        case "multipleOf":
            let step = try number(value, at: at)
            guard JSONNumber.isPositive(step) else { throw notA("a number above 0", at) }
            node.multipleOf = step
        case "pattern":
            guard let source = value.stringValue else { throw notA("a string", at) }
            node.pattern = try compilePattern(source, at: at)
        default:
            throw ResultSchemaRejection(
                path: at,
                reason: Self.hints[key].map { "\"\(key)\": \($0)" }
                    ?? "\"\(key)\" isn't in the subset of JSON Schema Agneta enforces")
        }
    }

    /// Refuses `enum` and `const` values that no value could ever equal: one nested deeper than a submitted value may
    /// be at all (a value that deep is turned away before it's checked).
    private func matchable(_ values: [JSONValue], at: String) throws(ResultSchemaRejection) {
        let deepest = ResultSchema.ValidationLimits.standard.depth
        guard values.allSatisfy({ $0.nestingDepth <= deepest }) else {
            throw ResultSchemaRejection(
                path: at,
                reason: "a value here nests more than \(deepest) levels deep, so no result could ever match it")
        }
    }

    private func types(_ value: JSONValue, at: String) throws(ResultSchemaRejection) -> Set<ResultSchema.Kind> {
        let names: [String]
        switch value {
        case .string(let name): names = [name]
        case .array(let list) where !list.isEmpty:
            names = list.compactMap(\.stringValue)
            guard names.count == list.count, Set(names).count == names.count else {
                throw notA("a type name or a list of distinct type names", at)
            }
        default: throw notA("a type name or a list of distinct type names", at)
        }
        var kinds: Set<ResultSchema.Kind> = []
        for name in names {
            guard let kind = ResultSchema.Kind(rawValue: name) else {
                throw ResultSchemaRejection(path: at, reason: "\"\(name)\" isn't a JSON Schema type")
            }
            kinds.insert(kind)
        }
        return kinds
    }

    private mutating func tally(_ n: Int, at: String) throws(ResultSchemaRejection) {
        enumValues += n
        guard enumValues <= limits.enumValues else {
            throw ResultSchemaRejection(
                path: at, reason: "the schema lists more than \(limits.enumValues) enum and const values")
        }
    }

    private func count(_ value: JSONValue, at: String) throws(ResultSchemaRejection) -> Int {
        guard let n = value.intValue, n >= 0, n <= Int64(Int32.max) else {
            throw notA("a whole number from 0 to \(Int32.max)", at)
        }
        return Int(n)
    }

    private func number(_ value: JSONValue, at: String, draft4: Bool = false) throws(ResultSchemaRejection)
        -> JSONValue
    {
        switch value {
        case .int, .double: return value
        case .bool where draft4:
            throw ResultSchemaRejection(
                path: at, reason: "a boolean here is draft-04's form; give the bound itself as a number")
        default: throw notA("a number", at)
        }
    }

    private func compilePattern(_ source: String, at: String) throws(ResultSchemaRejection) -> Pattern {
        guard source.count <= limits.patternLength else {
            throw ResultSchemaRejection(
                path: at, reason: "the pattern is longer than \(limits.patternLength) characters")
        }
        switch Pattern.compile(source) {
        case .success(let pattern): return pattern
        case .failure(let refusal):
            throw ResultSchemaRejection(path: at, reason: "the pattern can't be used: " + refusal.reason)
        }
    }

    private func notA(_ what: String, _ at: String) -> ResultSchemaRejection {
        ResultSchemaRejection(path: at, reason: "must be \(what)")
    }

    /// Points every `$ref` at its schema: any schema in this one, by JSON Pointer (`#`, `#/$defs/…`,
    /// `#/properties/…`), never another document.
    mutating func resolveReferences() throws(ResultSchemaRejection) {
        for reference in references {
            guard reference.target.hasPrefix("#") else {
                throw ResultSchemaRejection(
                    path: reference.pointer,
                    reason: "only references within the schema (#/$defs/…) are supported, never another document")
            }
            // The fragment is URI-encoded; one that doesn't decode is refused, never read as some other pointer.
            guard let fragment = String(reference.target.dropFirst()).removingPercentEncoding else {
                throw ResultSchemaRejection(
                    path: reference.pointer, reason: "\"\(reference.target)\" isn't a valid URI fragment")
            }
            guard fragment.isEmpty || fragment.hasPrefix("/"), let target = byPointer[fragment] else {
                throw ResultSchemaRejection(
                    path: reference.pointer,
                    reason: "\"\(reference.target)\" doesn't point at a schema in this one (#, or #/$defs/<name>)")
            }
            nodes[reference.node].reference = target
        }
    }

    /// The most one value position may cost to check: the checks its `$ref`, `allOf`, `anyOf`, `oneOf` and `not` lead
    /// to before looking inside the value. A schema of 1 KB whose anyOf branches double at every level would otherwise
    /// cost millions of checks per value; and how deep those in-place chains go is what checking recurses through.
    static let maxFanOut = 1_000
    static let maxChain = 64

    /// Refuses a schema whose in-place applicators multiply past `maxFanOut` checks, or chain deeper than `maxChain`.
    /// Reads nodes in `order` (each after what it leads to), so it never recurses.
    func boundWork(_ order: [Int]) throws(ResultSchemaRejection) {
        var cost = Array(repeating: 1, count: nodes.count)
        var chain = Array(repeating: 0, count: nodes.count)
        for index in order {
            let node = nodes[index]
            var total = 1, longest = 0
            for next in [node.reference, node.not].compactMap({ $0 }) + node.allOf + node.anyOf + node.oneOf {
                total = min(total + cost[next], Int.max / 2)
                longest = max(longest, chain[next] + 1)
            }
            guard total <= Self.maxFanOut else {
                throw ResultSchemaRejection(
                    path: node.pointer,
                    reason: "its anyOf, oneOf, allOf, not and $ref choices add up to more than \(Self.maxFanOut) "
                        + "checks for one value; simplify them")
            }
            guard longest <= Self.maxChain else {
                throw ResultSchemaRejection(
                    path: node.pointer, reason: "its $ref and applicator chains are more than \(Self.maxChain) deep")
            }
            cost[index] = total
            chain[index] = longest
        }
    }

    /// Refuses a schema that reaches itself without looking inside the value (`{"$ref": "#"}` at the root, or
    /// `anyOf` back to itself): checking a value against it would never end.
    /// Returns every node with what it leads to in place before it, the order `boundWork` reads them in.
    func refuseCyclesThatDontDescend() throws(ResultSchemaRejection) -> [Int] {
        var order: [Int] = []
        var state = [UInt8](repeating: 0, count: nodes.count) // 0 unseen, 1 on the path, 2 done
        // Bounded by the chain limit as it goes: the compiler runs on the router's small stack, and a chain of a
        // thousand references mustn't recurse a thousand deep to find out it's too long.
        func visit(_ index: Int, level: Int) throws(ResultSchemaRejection) {
            if state[index] == 2 { return }
            guard level <= Self.maxChain else {
                throw ResultSchemaRejection(
                    path: nodes[index].pointer,
                    reason: "its $ref and applicator chains are more than \(Self.maxChain) deep")
            }
            if state[index] == 1 {
                throw ResultSchemaRejection(
                    path: nodes[index].pointer,
                    reason: "the schema refers back to itself without describing anything inside the value")
            }
            state[index] = 1
            let node = nodes[index]
            for next in [node.reference, node.not].compactMap({ $0 }) + node.allOf + node.anyOf + node.oneOf {
                try visit(next, level: level + 1)
            }
            state[index] = 2
            order.append(index)
        }
        for index in nodes.indices { try visit(index, level: 0) }
        return order
    }
}

/// A JSON Pointer token: `~` and `/` escaped (RFC 6901).
func escape(_ token: String) -> String {
    token.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
}
