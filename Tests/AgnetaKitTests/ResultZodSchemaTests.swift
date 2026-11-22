// Schemas as Zod 4 writes them, the most common way an app will give one through the TypeScript client (Standard JSON
// Schema, `~standard.jsonSchema.input({ target: "draft-2020-12" })`): each must compile in Agneta's subset, and a
// fitting value must be valid. The fixture is Zod 4.6.7's output for the constructs apps use most; regenerate it when
// a new Zod major changes what it writes.
import Foundation
import Testing

@testable import AgnetaKit

@Suite struct ResultZodSchemaTests {
    static let fixture = URL(filePath: #filePath).deletingLastPathComponent().appending(
        path: "Fixtures/zod-4.6.7-schemas.json")

    /// A value each schema should accept.
    static let values: [String: JSONValue] = [
        "object": ["name": "Ada", "age": 36],
        "optional": ["b": .null],
        "enumLiteral": ["s": "sent", "k": "x"],
        "array": ["xs": [["t": "a"]]],
        "strings": [
            "e": "ada@example.com", "u": "https://example.com/a", "id": "123e4567-e89b-42d3-a456-426614174000",
            "d": "2026-11-22", "r": "ABC", "l": "hello"
        ],
        "union": ["v": 3],
        "discriminated": ["ev": ["type": "b", "y": "z"]],
        "record": ["m": ["a": 1, "b": 2.5]],
        "defaults": [:],
        "nested": ["a": ["b": ["c": ["x"]]]],
        "tuple": ["t": ["a", 1]],
        "recursive": ["root": ["name": "r", "children": [["name": "c", "children": []]]]],
        "numbers": ["p": 0.5, "m": 19.99, "i": 7],
        "strict": ["a": "x"],
        "loose": ["a": "x", "extra": true]
    ]

    @Test func everyZodSchemaCompilesAndAcceptsAFittingValue() throws {
        let schemas = try #require(try JSONCoding.decode(Data(contentsOf: Self.fixture)).objectValue)
        #expect(Set(schemas.keys) == Set(Self.values.keys))
        for (name, schema) in schemas.sorted(by: { $0.key < $1.key }) {
            do {
                let compiled = try ResultSchema.compile(schema)
                let issues = compiled.validate(Self.values[name] ?? [:])
                #expect(issues.isEmpty, "\(name): \(issues.map(\.message))")
            } catch {
                Issue.record("\(name) refused: \(error.message)")
            }
        }
    }

    @Test func zodsStrictnessHolds() throws {
        let schemas = try #require(try JSONCoding.decode(Data(contentsOf: Self.fixture)).objectValue)
        let strict = try ResultSchema.compile(try #require(schemas["strict"]))
        #expect(!strict.validate(["a": "x", "extra": true]).isEmpty)
        let strings = try ResultSchema.compile(try #require(schemas["strings"]))
        var wrong = Self.values["strings"]!.objectValue!
        wrong["r"] = "abc"
        #expect(strings.validate(.object(wrong)).map(\.path) == ["/r"])
        let discriminated = try ResultSchema.compile(try #require(schemas["discriminated"]))
        #expect(!discriminated.validate(["ev": ["type": "a", "y": "z"]]).isEmpty)
    }
}
