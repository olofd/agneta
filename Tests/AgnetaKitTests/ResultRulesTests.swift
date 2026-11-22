// A schema's limits in words, for the result tool's description (ResultRules). Every fixture is compiled first, so
// the words are tested only for schemas Agneta accepts, and read from the same nodes the validator checks.
import Foundation
import Testing

@testable import AgnetaKit

@Suite struct ResultRulesTests {
    static func rules(_ schema: JSONValue) throws -> String? { try ResultSchema.compile(schema).rules }

    /// The words for one property `x`.
    static func words(_ x: JSONValue) throws -> String? {
        let text = try rules(["type": "object", "properties": ["x": x]])
        guard let text, let start = text.range(of: " /x: ") else { return nil }
        return String(text[start.upperBound...].prefix { $0 != ";" }).replacing(/\.$/, with: "")
    }

    @Test func theProbesConstrainedCaseIsSaidInWords() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "code": ["type": "string", "pattern": "^[A-Z]{3}-\\d{4}$"],
                "score": ["type": "integer", "minimum": 1, "maximum": 5],
                "tags": ["type": "array", "items": ["type": "string", "maxLength": 12], "maxItems": 3, "uniqueItems": true]
            ],
            "required": ["code", "score", "tags"], "additionalProperties": false
        ]
        #expect(
            try Self.rules(schema)
                == "Rules the result must meet (Agneta checks them when you submit; * is any item): /code: matches "
                + "`^[A-Z]{3}-\\d{4}$`; /score: a whole number from 1 to 5; /tags: at most 3 items, no two items the "
                + "same; /tags/*: at most 12 characters.")
    }

    @Test func aSchemaWithoutLimitsSaysNothing() throws {
        let schema: JSONValue = [
            "type": "object", "properties": ["name": ["type": "string"], "tags": ["type": "array"]],
            "required": ["name"], "additionalProperties": false
        ]
        #expect(try Self.rules(schema) == nil)
        #expect(try Self.rules(["type": "object"]) == nil)
    }

    struct Limit: Sendable, CustomTestStringConvertible {
        var schema: JSONValue
        var words: String
        var testDescription: String { words }
    }

    static let limits: [Limit] = [
        Limit(schema: ["type": "number", "minimum": 0], words: "a number at least 0"),
        Limit(schema: ["type": "number", "exclusiveMinimum": 0, "maximum": 1], words: "a number above 0 and at most 1"),
        Limit(schema: ["type": "number", "minimum": 2, "exclusiveMinimum": 1], words: "a number at least 2"),
        Limit(schema: ["type": "number", "minimum": 1, "exclusiveMinimum": 1], words: "a number above 1"),
        Limit(schema: ["type": "number", "exclusiveMaximum": 10.5], words: "a number below 10.5"),
        Limit(schema: ["type": "number", "maximum": 100.0], words: "a number at most 100"),
        Limit(schema: ["type": "number", "multipleOf": 0.01], words: "a multiple of 0.01"),
        Limit(schema: ["type": "integer"], words: "a whole number"),
        Limit(schema: ["type": ["integer", "null"], "maximum": 3], words: "a whole number at most 3, or null"),
        Limit(schema: ["type": ["integer", "null"]], words: "a whole number, or null"),
        Limit(schema: ["type": ["number", "integer"], "minimum": 0], words: "a number at least 0"),
        // A bound applies to numbers only: when the value can be something else, it's said so.
        Limit(schema: ["minimum": 0], words: "if a number: at least 0"),
        Limit(schema: ["type": "string", "minimum": 0], words: "if a number: at least 0"),
        Limit(
            schema: ["type": ["string", "integer"], "maxLength": 5, "maximum": 9],
            words: "if a number: at most 9, if a string: at most 5 characters"),
        Limit(schema: ["type": ["array", "null"], "maxItems": 2], words: "at most 2 items, or null"),
        Limit(schema: ["maxItems": 2], words: "if an array: at most 2 items"),
        Limit(schema: ["type": "string", "minLength": 1, "maxLength": 1], words: "exactly 1 character"),
        Limit(schema: ["type": "string", "minLength": 2], words: "at least 2 characters"),
        Limit(schema: ["type": "string", "minLength": 0, "maxLength": 8], words: "at most 8 characters"),
        Limit(schema: ["type": "string", "pattern": "[0-9]"], words: "contains a match for `[0-9]`"),
        Limit(schema: ["type": "string", "pattern": "^a\\$"], words: "contains a match for `^a\\$`"),  // \$ is a literal $
        Limit(schema: ["type": "string", "pattern": "^a\\\\$"], words: "matches `^a\\\\$`"),  // \\ then the end
        Limit(schema: ["type": "string", "pattern": "^a\nb$"], words: "matches `^a\\u000ab$`"),
        Limit(schema: ["type": "array", "minItems": 1, "maxItems": 4], words: "1 to 4 items"),
        Limit(schema: ["type": "array", "minItems": 5, "maxItems": 3], words: "at least 5 items, at most 3 items"),
        Limit(schema: ["type": "object", "minProperties": 1], words: "at least 1 property"),
        Limit(schema: ["type": "null", "maximum": 3], words: ""),
    ]

    @Test(arguments: limits)
    func eachLimitInWords(_ limit: Limit) throws {
        #expect(try Self.words(limit.schema) == (limit.words.isEmpty ? nil : limit.words))
    }

    @Test func referencesAllOfItemsAndOtherPropertiesAreFollowed() throws {
        let schema: JSONValue = [
            "type": "object",
            "$defs": ["amount": ["type": "number", "minimum": 0]],
            "properties": [
                "lines": [
                    "type": "array", "minItems": 1,
                    "items": [
                        "type": "object",
                        "properties": ["amount": ["$ref": "#/$defs/amount"]],
                        "allOf": [["properties": ["text": ["type": "string", "maxLength": 80]]]]
                    ]
                ],
                "pair": [
                    "type": "array", "prefixItems": [["type": "string", "maxLength": 2]],
                    "items": ["type": "integer", "maximum": 3]
                ],
                "extra": [
                    "type": "object", "properties": ["a": ["type": "string", "maxLength": 10]],
                    "additionalProperties": ["type": "string", "maxLength": 2]
                ],
                "map": ["type": "object", "additionalProperties": ["type": "string", "maxLength": 5]],
                "a/b~c": ["type": "string", "maxLength": 3]
            ]
        ]
        let text = try #require(try Self.rules(schema))
        #expect(text.contains("/lines: at least 1 item;"))
        #expect(text.contains("/lines/*/amount: a number at least 0;"))
        #expect(text.contains("/lines/*/text: at most 80 characters"))
        // items beside prefixItems covers only the items after them
        #expect(text.contains("/pair/0: at most 2 characters; /pair/1 onward: a whole number at most 3"))
        #expect(text.contains("/extra/a: at most 10 characters; /extra/(other properties): at most 2 characters"))
        #expect(text.contains("/map/(any property): at most 5 characters"))
        #expect(text.contains("/a~1b~0c: at most 3 characters"))  // as a JSON Pointer, as the issues name it
    }

    @Test func aPercentEncodedReferenceIsReadAsTheValidatorReadsIt() throws {
        // The fragment is decoded before it's split: %2F is a separator, as it is for the validator.
        let schema: JSONValue = [
            "type": "object",
            "$defs": [
                "a/items": ["type": "string", "maxLength": 1],
                "a": ["type": "array", "items": ["type": "string", "maxLength": 50]]
            ],
            "properties": ["x": ["$ref": "#/$defs/a%2Fitems"]]
        ]
        let compiled = try ResultSchema.compile(schema)
        // Whichever schema the validator reached, the words name the same one.
        let validatorMax = compiled.validate(["x": "zz"]).isEmpty ? "50 characters" : "1 character"
        #expect(try #require(compiled.rules).contains("/x: at most \(validatorMax)"))
    }

    @Test func aSchemaThatRefersToItselfEnds() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "name": ["type": "string", "maxLength": 9], "children": ["type": "array", "items": ["$ref": "#"]]
            ]
        ]
        let text = try #require(try Self.rules(schema))
        #expect(text.contains("/name: at most 9 characters"))
        #expect(text.count <= ResultRules.maxText)
    }

    @Test func referencesThatFanOutStayCheap() throws {
        // Six levels of 8 properties each referring to the next level: 8^6 paths, if each were walked.
        var defs: [String: JSONValue] = [:]
        for level in 0..<6 {
            var properties: [String: JSONValue] = [:]
            for key in "abcdefgh" {
                properties[String(key)] =
                    level == 5 ? ["type": "string", "maxLength": 4] : ["$ref": .string("#/$defs/d\(level + 1)")]
            }
            defs["d\(level)"] = ["type": "object", "maxProperties": 9, "properties": .object(properties)]
        }
        var root: [String: JSONValue] = [:]
        for key in "abcdefgh" { root[String(key)] = ["$ref": "#/$defs/d0"] }
        let schema: JSONValue = ["type": "object", "$defs": .object(defs), "properties": .object(root)]
        let started = ContinuousClock.now
        let text = try #require(try Self.rules(schema))
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(text.count <= ResultRules.maxText)
        #expect(text.hasSuffix("more in the schema."))
    }

    @Test func aLongListIsCutWithinTheBound() throws {
        var properties: [String: JSONValue] = [:]
        for i in 0..<200 { properties[String(format: "field%03d", i)] = ["type": "string", "maxLength": 10] }
        let text = try #require(try Self.rules(["type": "object", "properties": .object(properties)]))
        #expect(text.count <= ResultRules.maxText)
        #expect(text.hasSuffix("more in the schema."))
    }

    @Test func theToolDescriptionCarriesTheRules() throws {
        let declaration = try #require(
            try ResultDeclaration.parse([
                "schema": ["type": "object", "properties": ["tags": ["type": "array", "maxItems": 3]]]
            ]))
        let description = ResultServer.tools(declaration)[0]["description"]?.stringValue ?? ""
        #expect(
            description.hasSuffix("Rules the result must meet (Agneta checks them when you submit): /tags: at most 3 items."))
    }
}
