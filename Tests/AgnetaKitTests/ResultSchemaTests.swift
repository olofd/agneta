import Foundation
import Testing

@testable import AgnetaKit

/// The schema subset Agneta enforces for structured results: what it compiles, what it refuses and why, and what the
/// validator says about values. The official JSON-Schema-Test-Suite runs in ResultSchemaSuiteTests.
@Suite struct ResultSchemaTests {
    func compile(_ schema: JSONValue) throws -> ResultSchema { try ResultSchema.compile(schema) }

    func refusal(_ schema: JSONValue, limits: ResultSchema.Limits = .standard) -> ResultSchemaRejection? {
        do {
            _ = try ResultSchema.compile(schema, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    func object(_ properties: JSONValue, required: [JSONValue] = [], _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var fields: [String: JSONValue] = ["type": "object", "properties": properties, "required": .array(required)]
        for (key, value) in extra { fields[key] = value }
        return .object(fields)
    }

    /// The issues of `value` against a schema whose root holds it in property `v`.
    func issues(_ schema: JSONValue, _ value: JSONValue) throws -> [ResultIssue] {
        try compile(object(["v": schema])).validate(["v": value])
    }

    func valid(_ schema: JSONValue, _ value: JSONValue) throws -> Bool { try issues(schema, value).isEmpty }

    // MARK: Compiling

    @Test func compilesATypicalInvoiceSchema() throws {
        let schema = try compile(
            object(
                [
                    "number": ["type": "string", "pattern": "^[A-Z]-\\d+$"],
                    "total": ["type": "number", "minimum": 0],
                    "due": ["type": ["string", "null"], "format": "date"],
                    "lines": [
                        "type": "array", "minItems": 1,
                        "items": ["$ref": "#/$defs/line"]
                    ]
                ], required: ["number", "total", "due", "lines"],
                [
                    "additionalProperties": false,
                    "$defs": [
                        "line": [
                            "type": "object", "properties": ["text": ["type": "string"], "amount": ["type": "number"]],
                            "required": ["text", "amount"], "additionalProperties": false
                        ]
                    ]
                ]))
        let invoice: JSONValue = [
            "number": "A-1042", "total": 129.5, "due": .null, "lines": [["text": "Mixing", "amount": 129.5]]
        ]
        #expect(schema.validate(invoice).isEmpty)
        #expect(schema.source["$defs"]?["line"] != nil)
    }

    @Test func theRootMustBeAnObjectSchema() {
        #expect(refusal(true)?.reason.contains("root must be an object schema") == true)
        #expect(refusal(["type": "string"])?.reason.contains(#""type": "object""#) == true)
        #expect(refusal(["properties": [:]])?.path == "")
        #expect(refusal(["type": ["object", "null"]]) != nil)
    }

    @Test func refusesEveryKeywordOutsideTheSubsetWithWhereItIs() {
        for keyword in [
            "unevaluatedProperties", "unevaluatedItems", "dependentSchemas", "dependentRequired", "contains",
            "minContains", "contentMediaType", "contentEncoding", "$dynamicAnchor", "x-custom", "if"
        ] {
            let schema = object(["a": .object(["type": "string", keyword: true])])
            let refused = refusal(schema)
            #expect(refused?.path == "/properties/a/" + keyword, "\(keyword)")
        }
    }

    @Test func explainsCommonMistakes() {
        #expect(refusal(object(["a": ["type": "string", "nullable": true]]))?.reason.contains(#"["string", "null"]"#) == true)
        #expect(refusal(object(["a": ["type": "array", "items": [["type": "string"]]]]))?.reason.contains("prefixItems") == true)
        #expect(refusal(object(["a": ["type": "number", "exclusiveMinimum": true]]))?.reason.contains("draft-04") == true)
        #expect(refusal(object(["a": ["$anchor": "x"]]))?.reason.contains("#/$defs/") == true)
        #expect(refusal(object(["a": ["if": ["type": "string"]]]))?.reason.contains("anyOf") == true)
    }

    @Test func acceptsAnnotationsWithoutEnforcingThem() throws {
        let schema: JSONValue = [
            "type": "string", "title": "T", "description": "D", "default": "x", "examples": ["y"], "format": "email",
            "$comment": "c", "deprecated": true, "readOnly": false, "writeOnly": false
        ]
        #expect(try valid(schema, "not an email"))
    }

    @Test func schemaAndIdOnlyAtTheRoot() {
        #expect(refusal(object([:], ["$schema": "https://json-schema.org/draft/2020-12/schema"])) == nil)
        #expect(refusal(object([:], ["$schema": "http://json-schema.org/draft-07/schema#"])) == nil)
        #expect(refusal(object([:], ["$schema": "http://json-schema.org/draft-04/schema#"]))?.path == "/$schema")
        #expect(refusal(object(["a": ["$schema": "https://json-schema.org/draft/2020-12/schema"]]))?.path == "/properties/a/$schema")
        #expect(refusal(object([:], ["$id": "https://example.com/s"])) == nil)
        #expect(refusal(object(["a": ["$id": "x"]]))?.path == "/properties/a/$id")
        #expect(refusal(object(["a": ["$defs": ["b": true]]]))?.path == "/properties/a/$defs")
    }

    @Test func refusesMalformedKeywordValues() {
        let cases: [(JSONValue, String)] = [
            (["type": "text"], "/properties/a/type"),
            (["type": ["string", "string"]], "/properties/a/type"),
            (["type": []], "/properties/a/type"),
            (["enum": []], "/properties/a/enum"),
            (["required": ["x", "x"]], "/properties/a/required"),
            (["required": [1]], "/properties/a/required"),
            (["minLength": -1], "/properties/a/minLength"),
            (["minLength": 1.5], "/properties/a/minLength"),
            (["maximum": "10"], "/properties/a/maximum"),
            (["multipleOf": 0], "/properties/a/multipleOf"),
            (["multipleOf": -2], "/properties/a/multipleOf"),
            (["pattern": "(unclosed"], "/properties/a/pattern"),
            (["anyOf": []], "/properties/a/anyOf"),
            (["properties": ["x": 3]], "/properties/a/properties/x"),
            (["uniqueItems": "yes"], "/properties/a/uniqueItems")
        ]
        for (schema, path) in cases {
            #expect(refusal(object(["a": schema]))?.path == path, "\(schema)")
        }
    }

    @Test func refAcceptsOnlyTheRootAndItsDefs() throws {
        let tree = try compile(
            object(
                ["name": ["type": "string"], "children": ["type": "array", "items": ["$ref": "#"]]],
                required: ["name"]))
        #expect(tree.validate(["name": "a", "children": [["name": "b", "children": [["name": "c"]]]]]).isEmpty)
        let deep = tree.validate(["name": "a", "children": [["children": []]]])
        #expect(deep.map(\.path) == ["/children/0"] && deep.first?.keyword == "required")

        #expect(refusal(object(["a": ["$ref": "https://example.com/other.json"]]))?.path == "/properties/a/$ref")
        #expect(refusal(object(["a": ["$ref": "other.json#/x"]])) != nil)
        #expect(refusal(object(["a": ["$ref": "#/$defs/missing"]]))?.path == "/properties/a/$ref")
        #expect(refusal(object(["a": ["$ref": "#/properties/b"]]))?.reason.contains("$defs") == true)
        // definitions (draft-07's name) and escaped names work.
        let defs = try compile(object(["a": ["$ref": "#/definitions/a~1b"]], ["definitions": ["a/b": ["type": "integer"]]]))
        #expect(defs.validate(["a": 3]).isEmpty && !defs.validate(["a": "x"]).isEmpty)
        let encoded = try compile(object(["a": ["$ref": "#/$defs/x%20y"]], ["$defs": ["x y": ["const": 1]]]))
        #expect(encoded.validate(["a": 1]).isEmpty)
    }

    @Test func keywordsBesideARefAreRefusedButAnnotationsAreFine() {
        #expect(refusal(object(["a": ["$ref": "#/$defs/n", "minimum": 3]], ["$defs": ["n": ["type": "number"]]]))?
            .path == "/properties/a/minimum")
        #expect(refusal(object(["a": ["$ref": "#/$defs/n", "description": "d"]], ["$defs": ["n": ["type": "number"]]])) == nil)
    }

    @Test func refusesASchemaThatReachesItselfWithoutDescending() {
        #expect(refusal(object([:], ["allOf": [["$ref": "#"]]]))?.reason.contains("refers back to itself") == true)
        #expect(
            refusal(object(["a": ["$ref": "#/$defs/x"]], ["$defs": ["x": ["anyOf": [["$ref": "#/$defs/y"]]], "y": ["not": ["$ref": "#/$defs/x"]]]]))
                != nil)
        // A cycle through a property descends, so it's fine.
        #expect(refusal(object(["next": ["$ref": "#"]])) == nil)
    }

    @Test func enforcesTheLimits() {
        let tight = ResultSchema.Limits(bytes: 200, depth: 3, nodes: 5, enumValues: 3, patternLength: 5)
        #expect(refusal(object(["a": ["description": .string(String(repeating: "x", count: 300))]]), limits: tight)?.reason.contains("bytes") == true)
        #expect(refusal(object(["a": ["not": ["not": ["not": true]]]]), limits: tight)?.reason.contains("nest") == true)
        #expect(refusal(object(["a": true, "b": true, "c": true, "d": true, "e": true]), limits: tight)?.reason.contains("schemas") == true)
        #expect(refusal(object(["a": ["enum": [1, 2]], "b": ["enum": [3, 4]]]), limits: tight)?.reason.contains("enum") == true)
        #expect(refusal(object(["a": ["pattern": "abcdef"]]), limits: tight)?.reason.contains("longer than 5") == true)
        // The standard limits fit a realistic schema with room.
        #expect(ResultSchema.Limits.standard.bytes == 16_384 && ResultSchema.Limits.standard.depth == 32)
    }

    // MARK: Validating

    @Test func typesIncludingWholeNumbersWrittenAsDoubles() throws {
        #expect(try valid(["type": "integer"], 3))
        #expect(try valid(["type": "integer"], 3.0))
        #expect(try !valid(["type": "integer"], 3.5))
        #expect(try valid(["type": "number"], 3))
        #expect(try valid(["type": ["string", "null"]], .null))
        #expect(try !valid(["type": ["string", "null"]], 0))
        #expect(try !valid(["type": "boolean"], 0))
        #expect(try !valid(["type": "object"], []))
        let wrong = try issues(["type": "number"], "12")
        #expect(wrong == [ResultIssue(path: "/v", keyword: "type", message: "expected a number, got a string", schemaPath: "/properties/v/type")])
        #expect(try issues(["type": ["integer", "null"]], true).first?.message == "expected a whole number or null, got true")
    }

    @Test func objectKeywords() throws {
        let schema: JSONValue = [
            "type": "object", "properties": ["a": ["type": "string"]], "required": ["a", "b"],
            "patternProperties": ["^x-": ["type": "integer"]], "additionalProperties": false,
            "propertyNames": ["maxLength": 5], "minProperties": 1, "maxProperties": 3
        ]
        #expect(try valid(schema, ["a": "s", "b": .null]) == false) // b isn't allowed by additionalProperties
        let found = try issues(schema, ["a": 1, "x-1": "no", "other": true, "longername": 1])
        let pairs = found.map { "\($0.path) \($0.keyword)" }
        #expect(pairs.contains("/v required"))
        #expect(pairs.contains("/v maxProperties"))
        #expect(pairs.contains("/v/a type"))
        #expect(pairs.contains("/v/x-1 type"))
        #expect(pairs.contains("/v/other additionalProperties"))
        #expect(pairs.contains("/v/longername maxLength"))
        #expect(found.contains { $0.path == "/v/other" && $0.message == #""other" isn't one of the allowed properties"# })
        #expect(try issues(["type": "object", "additionalProperties": ["type": "number"]], ["k": "s"]).map(\.path) == ["/v/k"])
        #expect(try issues(["type": "object", "minProperties": 2], [:]).first?.message == "must have at least 2 properties, has 0")
    }

    @Test func pointersEscapeSlashesAndTildes() throws {
        let found = try issues(["type": "object", "additionalProperties": ["type": "string"]], ["a/b~c": 1])
        #expect(found.map(\.path) == ["/v/a~1b~0c"])
    }

    @Test func arrayKeywords() throws {
        let schema: JSONValue = [
            "type": "array", "prefixItems": [["type": "string"], ["type": "integer"]], "items": ["type": "boolean"],
            "minItems": 2, "maxItems": 4
        ]
        #expect(try valid(schema, ["a", 1, true, false]))
        #expect(try issues(schema, ["a", "b", 3]).map(\.path) == ["/v/1", "/v/2"])
        #expect(try issues(schema, ["a"]).map(\.keyword) == ["minItems"])
        #expect(try issues(schema, ["a", 1, true, true, true]).map(\.keyword) == ["maxItems"])
        #expect(try valid(["type": "array", "items": false, "prefixItems": [true]], [1]))
        #expect(try !valid(["type": "array", "items": false, "prefixItems": [true]], [1, 2]))
    }

    @Test func uniqueItemsUsesJSONEquality() throws {
        let unique: JSONValue = ["type": "array", "uniqueItems": true]
        #expect(try valid(unique, [1, "1", [1], ["a": 1]]))
        #expect(try issues(unique, [1, 1.0]).first?.message == "items 0 and 1 are the same; every item must be different")
        #expect(try !valid(unique, [["a": 1, "b": 2], ["b": 2, "a": 1]]))
        #expect(try valid(unique, [false, 0]))
        #expect(try valid(["type": "array", "uniqueItems": false], [1, 1]))
    }

    @Test func numberBoundsCompareIntegersExactly() throws {
        #expect(try valid(["type": "number", "minimum": 1, "maximum": 2], 1.5))
        #expect(try !valid(["type": "number", "exclusiveMinimum": 1], 1))
        #expect(try !valid(["type": "number", "exclusiveMinimum": 1], 1.0))
        #expect(try valid(["type": "number", "exclusiveMinimum": 1], 1.0000001))
        #expect(try !valid(["type": "number", "exclusiveMaximum": 2.5], 3))
        // Integers beyond a double's precision compare as integers.
        #expect(try !valid(["type": "integer", "maximum": .int(Int64.max - 1)], .int(Int64.max)))
        #expect(try valid(["type": "integer", "maximum": .double(9.3e18)], .int(Int64.max)))
        #expect(try valid(["type": "integer", "minimum": .double(-1e19)], .int(Int64.min)))
        #expect(try issues(["type": "number", "minimum": 0], -2).first?.message == "must be at least 0, is -2")
    }

    @Test func multipleOfIsExactForDecimals() throws {
        #expect(try valid(["type": "number", "multipleOf": 0.0001], 0.0075))
        #expect(try valid(["type": "number", "multipleOf": 0.01], 19.99))
        #expect(try !valid(["type": "number", "multipleOf": 0.01], 19.995))
        #expect(try valid(["type": "integer", "multipleOf": 3], 9))
        #expect(try !valid(["type": "integer", "multipleOf": 3], 10))
        #expect(try valid(["type": "number", "multipleOf": 1.5], 4.5))
        // A quotient too large for any number isn't a multiple, and nothing overflows.
        #expect(try !valid(["type": "number", "multipleOf": 0.123456789], 1e308))
        #expect(try valid(["type": "integer", "multipleOf": 1], .int(Int64.min)))
    }

    @Test func stringLengthsCountCodePoints() throws {
        #expect(try valid(["type": "string", "maxLength": 1], "💩"))
        #expect(try valid(["type": "string", "minLength": 2, "maxLength": 2], "é😀"))
        #expect(try issues(["type": "string", "minLength": 3], "ab").first?.message == "must be at least 3 characters long, is 2")
    }

    @Test func patternsSearchAnywhereUnlessAnchored() throws {
        #expect(try valid(["type": "string", "pattern": "b"], "abc"))
        #expect(try !valid(["type": "string", "pattern": "^b"], "abc"))
        #expect(try issues(["type": "string", "pattern": "^\\d{4}$"], "12a4").first?.message == "must match the pattern ^\\d{4}$")
    }

    @Test func aPatternThatRunsAwayIsStoppedAndTheValueIsNotValid() throws {
        let schema = try compile(object(["v": ["type": "string", "pattern": "^(a+)+$"]]))
        let evil = JSONValue.string(String(repeating: "a", count: 40) + "!")
        let started = ContinuousClock.now
        let found = schema.validate(
            ["v": evil], limits: .init(checks: 1_000, patternTime: .milliseconds(50), issues: 20))
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(found.last?.keyword == "limit")
        #expect(found.last?.message.contains("took longer") == true)
    }

    @Test func enumAndConstCompareAsJSON() throws {
        #expect(try valid(["enum": ["a", 1, .null, ["x": [1, 2]]]], ["x": [1.0, 2]]))
        #expect(try !valid(["enum": ["a", 1]], "b"))
        #expect(try issues(["enum": ["draft", "sent"]], "paid").first?.message == #"must be one of "draft", "sent""#)
        #expect(try valid(["const": .null], .null))
        #expect(try !valid(["const": .null], false))
        #expect(try valid(["const": 2], 2.0))
        #expect(try issues(["const": "yes"], "no").first?.message == #"must be "yes""#)
        let many = JSONValue.array((1...12).map { .int($0) })
        #expect(try issues(["enum": many], 0).first?.message.hasSuffix("… (12 in all)") == true)
    }

    @Test func anyOfReportsTheClosestForm() throws {
        let schema: JSONValue = [
            "anyOf": [
                ["type": "object", "properties": ["kind": ["const": "a"], "x": ["type": "number"]], "required": ["kind", "x"]],
                ["type": "string"]
            ]
        ]
        #expect(try valid(schema, "ok"))
        #expect(try valid(schema, ["kind": "a", "x": 1]))
        let found = try issues(schema, ["kind": "a", "x": "1"])
        #expect(found.first?.keyword == "anyOf")
        #expect(found.first?.message == "doesn't match any of the 2 allowed forms; the closest, form #1, fails as follows")
        #expect(found.dropFirst().map(\.path) == ["/v/x"])
    }

    @Test func oneOfNeedsExactlyOne() throws {
        let schema: JSONValue = ["oneOf": [["type": "integer"], ["type": "number", "minimum": 2]]]
        #expect(try valid(schema, 1))
        #expect(try valid(schema, 2.5))
        #expect(try issues(schema, 3).first?.message == "matches 2 of the allowed forms (#1, #2) but must match exactly one")
        #expect(try issues(schema, "x").first?.keyword == "oneOf")
    }

    @Test func allOfAndNot() throws {
        let schema: JSONValue = ["allOf": [["type": "string"], ["minLength": 2]], "not": ["const": "no"]]
        #expect(try valid(schema, "yes"))
        #expect(try issues(schema, "y").map(\.keyword) == ["minLength"])
        #expect(try issues(schema, "no").map(\.keyword) == ["not"])
    }

    @Test func booleanSchemas() throws {
        #expect(try valid(true, ["anything": [1]]))
        #expect(try issues(false, 1) == [ResultIssue(path: "/v", keyword: "false", message: "no value is allowed here", schemaPath: "/properties/v")])
    }

    @Test func issuesAreCappedAndInKeyOrder() throws {
        var properties: [String: JSONValue] = [:]
        var value: [String: JSONValue] = [:]
        for i in 0..<30 {
            let name = String(format: "p%02d", i)
            properties[name] = ["type": "string"]
            value[name] = .int(Int64(i))
        }
        let schema = try compile(["type": "object", "properties": .object(properties)])
        let found = schema.validate(.object(value))
        #expect(found.count == 20)
        #expect(found.map(\.path) == (0..<20).map { String(format: "/p%02d", $0) })
    }

    @Test func checkingStopsAtItsBoundAndSaysSo() throws {
        let schema = try compile(["type": "object", "properties": ["xs": ["type": "array", "items": ["type": "integer"]]]])
        let big: JSONValue = ["xs": .array((0..<10_000).map { .int(Int64($0)) })]
        #expect(schema.validate(big).isEmpty)
        let found = schema.validate(big, limits: .init(checks: 100, patternTime: .milliseconds(250), issues: 20))
        #expect(found.last?.keyword == "limit")
        #expect(found.last?.message == "the value is too large or complex to check within Agneta's limits")
    }

    @Test func uniqueItemsStaysLinearOnLongArrays() throws {
        let schema = try compile(["type": "object", "properties": ["xs": ["type": "array", "uniqueItems": true]]])
        var items: [JSONValue] = (0..<100_000).map { .int(Int64($0)) }
        let started = ContinuousClock.now
        #expect(schema.validate(["xs": .array(items)]).isEmpty)
        items.append(.double(5.0))
        #expect(schema.validate(["xs": .array(items)]).first?.message == "items 5 and 100000 are the same; every item must be different")
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func canonicalFormsAgreeWithEquality() {
        let pairs: [(JSONValue, JSONValue, Bool)] = [
            (1, 1.0, true), (0, -0.0, true), (1, "1", false), (["a": 1, "b": [2]], ["b": [2.0], "a": 1], true),
            ([1, 2], [2, 1], false), (.null, false, false), ("a\"b", "a\"b", true), (0.1, 0.1, true), (0.1, 0.2, false)
        ]
        for (a, b, equal) in pairs {
            #expect(JSONEquality.equal(a, b) == equal, "\(a) \(b)")
            #expect((JSONEquality.canonical(a) == JSONEquality.canonical(b)) == equal, "\(a) \(b)")
        }
    }

    @Test func validationIsDeterministic() throws {
        let schema = try compile(object(["a": ["type": "string"], "b": ["type": "string"], "c": ["type": "string"]]))
        let value: JSONValue = ["c": 1, "a": 2, "b": 3]
        let first = schema.validate(value)
        for _ in 0..<20 { #expect(schema.validate(value) == first) }
        #expect(first.map(\.path) == ["/a", "/b", "/c"])
    }
}
