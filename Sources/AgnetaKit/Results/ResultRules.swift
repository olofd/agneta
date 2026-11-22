// Structured results: a schema's limits, said in words in the result tool's description.
//
// Measured on real models (docs/ENGINES.md): Sonnet met `maxItems: 3` on its first call, but Luna and Terra on Codex sent
// 4 or 5 items every time and fixed it only from Agneta's issue, a second attempt that cost 1 to 4 more model calls.
// With these words in the description, both met it first time in 12 of 12 runs. Smaller models read a tool's description
// more closely than its schema, and an engine may show the model less of a schema than it was given.
//
// The words come from the compiled schema (ResultSchema's nodes, references already resolved), so they say what the
// validator enforces and nothing it doesn't: a bound on numbers is said for numbers only ("if a number: …") when the
// value may be something else, `items` beside `prefixItems` covers the items after them, `additionalProperties` the
// other properties. Choices (`anyOf`, `oneOf`, `not`) are left to the schema and Agneta's issues. They're worked out
// once, when the schema is compiled, within a budget of visits and characters, so no schema can make them costly.
import Foundation

enum ResultRules {
    /// The longest text, in characters, its ending included: it's in the tool's description on every model call.
    static let maxText = 1_200
    /// How many schemas the walk visits at most. References can fan out (a property's schema referring to one with
    /// many properties, each referring on), so the walk is bounded by visits, not depth alone.
    static let maxVisits = 1_000

    static let heading = "Rules the result must meet (Agneta checks them when you submit"

    /// The text for a compiled schema, or nil when it sets none of these limits.
    static func text(_ nodes: [ResultSchema.Node]) -> String? {
        var walk = Walk(nodes: nodes)
        walk.visit(0, path: "", ancestors: [])
        guard !walk.rules.isEmpty else { return nil }
        let marks = walk.rules.contains { $0.path.contains("/*") } ? "; * is any item" : ""
        // What ends the text when it stops early; each line is added only if the ending after it still fits, so the
        // whole stays within maxText.
        func ending(after rest: Int) -> String {
            rest > 0 ? " … and \(rest) more in the schema." : (walk.truncated ? " … and more in the schema." : "")
        }
        var text = heading + marks + "):"
        for (i, rule) in walk.rules.enumerated() {
            let line = " \(rule.path.isEmpty ? "the result" : rule.path): \(rule.words.joined(separator: ", "));"
            if text.count + line.count + ending(after: walk.rules.count - i - 1).count > maxText {
                return text + ending(after: walk.rules.count - i)
            }
            text += line
        }
        return walk.truncated ? text + ending(after: 0) : String(text.dropLast()) + "."
    }

    struct Walk {
        let nodes: [ResultSchema.Node]
        var rules: [(path: String, words: [String])] = []
        var index: [String: Int] = [:]
        var visits = 0
        var truncated = false

        init(nodes: [ResultSchema.Node]) { self.nodes = nodes }

        mutating func visit(_ at: Int, path: String, ancestors: Set<Int>) {
            guard nodes.indices.contains(at), !ancestors.contains(at) else { return }
            guard visits < maxVisits else {
                truncated = true
                return
            }
            visits += 1
            let node = nodes[at]
            let inside = ancestors.union([at])
            // `$ref` and allOf's parts hold at this same path.
            if let target = node.reference { visit(target, path: path, ancestors: inside) }
            for part in node.allOf { visit(part, path: path, ancestors: inside) }
            add(ResultRules.limits(node), at: path)
            let named = node.properties.compactMap { key, child in String(data: key, encoding: .utf8).map { ($0, child) } }
            for (name, child) in named.sorted(by: { $0.0 < $1.0 }) {
                visit(child, path: path + "/" + escape(name), ancestors: inside)
            }
            for (i, child) in node.prefixItems.enumerated() { visit(child, path: path + "/\(i)", ancestors: inside) }
            if let items = node.items {
                let label = node.prefixItems.isEmpty ? "/*" : "/\(node.prefixItems.count) onward"
                visit(items, path: path + label, ancestors: inside)
            }
            if let other = node.additionalProperties {
                visit(other, path: path + (named.isEmpty ? "/(any property)" : "/(other properties)"), ancestors: inside)
            }
        }

        mutating func add(_ words: [String], at path: String) {
            guard !words.isEmpty else { return }
            if let at = index[path] {
                rules[at].words += words.filter { !rules[at].words.contains($0) }
            } else {
                index[path] = rules.count
                rules.append((path, words))
            }
        }
    }

    /// The limits one schema sets itself, in words.
    static func limits(_ node: ResultSchema.Node) -> [String] {
        let allowed = node.types ?? Set(ResultSchema.Kind.allCases)
        let kinds = allowed.subtracting([.null])
        guard !kinds.isEmpty else { return [] }  // only null: no limit applies
        let nullable = node.types != nil && allowed.contains(.null)
        // Words for one kind of value are said plainly only when the value can be nothing else (or null).
        func said(_ words: [String], only: Set<ResultSchema.Kind>, as kind: String) -> [String] {
            guard !words.isEmpty else { return [] }
            if node.types != nil, kinds.isSubset(of: only) { return words }
            return ["if \(kind): " + words.joined(separator: ", ")]
        }
        var words: [String] = []
        let whole = node.types != nil && kinds == [.integer]
        var numbers: [String] = []
        // "a number at least 0" when it can only be a number; "if a number: at least 0" when it can be more.
        let plain = node.types != nil && kinds.isSubset(of: [.number, .integer])
        let noun = plain ? (whole ? "a whole number " : "a number ") : ""
        let low = bound(node.minimum, node.exclusiveMinimum, tighter: >)
        let high = bound(node.maximum, node.exclusiveMaximum, tighter: <)
        switch (low, high) {
        case let ((min, false)?, (max, false)?): numbers.append("\(noun)from \(number(min)) to \(number(max))")
        case let (low?, high?):
            numbers.append(
                "\(noun)\(low.exclusive ? "above" : "at least") \(number(low.value)) and "
                    + "\(high.exclusive ? "below" : "at most") \(number(high.value))")
        case let (low?, nil): numbers.append("\(noun)\(low.exclusive ? "above" : "at least") \(number(low.value))")
        case let (nil, high?): numbers.append("\(noun)\(high.exclusive ? "below" : "at most") \(number(high.value))")
        case (nil, nil): if whole { numbers.append("a whole number") }
        }
        if let step = node.multipleOf { numbers.append("a multiple of \(number(step))") }
        words += said(numbers, only: [.number, .integer], as: "a number")
        var strings = range(node.minLength, node.maxLength, "character", "characters")
        if let pattern = node.pattern {
            let source = "`" + ResultWording.escapeControls(pattern.source) + "`"
            // Patterns aren't anchored: one that doesn't span the whole value only has to occur in it.
            strings.append(anchored(pattern.source) ? "matches \(source)" : "contains a match for \(source)")
        }
        words += said(strings, only: [.string], as: "a string")
        var arrays = range(node.minItems, node.maxItems, "item", "items")
        if node.uniqueItems { arrays.append("no two items the same") }
        words += said(arrays, only: [.array], as: "an array")
        words += said(range(node.minProperties, node.maxProperties, "property", "properties"), only: [.object], as: "an object")
        if nullable, !words.isEmpty, !words.contains(where: { $0.hasPrefix("if ") }) { words.append("or null") }
        return words
    }

    /// Whether a pattern must match the whole value: `^…$`, with the `$` not escaped.
    static func anchored(_ pattern: String) -> Bool {
        guard pattern.hasPrefix("^"), pattern.hasSuffix("$") else { return false }
        let backslashes = pattern.dropLast().reversed().prefix { $0 == "\\" }.count
        return backslashes % 2 == 0
    }

    /// The bound that holds, and whether it's exclusive: with both forms, the tighter one (on a tie, the exclusive).
    private static func bound(
        _ inclusive: JSONValue?, _ exclusive: JSONValue?, tighter: (Double, Double) -> Bool
    ) -> (value: JSONValue, exclusive: Bool)? {
        switch (inclusive.flatMap(double), exclusive.flatMap(double)) {
        case let (i?, e?): return tighter(e, i) || e == i ? (exclusive!, true) : (inclusive!, false)
        case (_?, nil): return (inclusive!, false)
        case (nil, _?): return (exclusive!, true)
        case (nil, nil): return nil
        }
    }

    private static func double(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let n): Double(n)
        case .double(let d): d
        default: nil
        }
    }

    private static func range(_ low: Int?, _ high: Int?, _ one: String, _ many: String) -> [String] {
        func count(_ n: Int) -> String { "\(n) \(n == 1 ? one : many)" }
        switch (low, high) {
        case let (min?, max?) where min == max: return ["exactly \(count(min))"]
        case let (min?, max?) where min > 0 && min < max: return ["\(min) to \(count(max))"]
        case let (min?, max?) where min > max: return ["at least \(count(min))", "at most \(count(max))"]
        case let (_, max?): return ["at most \(count(max))"]
        case let (min?, nil) where min > 0: return ["at least \(count(min))"]
        default: return []
        }
    }

    private static func number(_ value: JSONValue) -> String {
        switch value {
        case .int(let n): String(n)
        case .double(let d) where d == d.rounded() && abs(d) < 1e15: String(Int64(d))
        case .double(let d): String(d)
        default: "?"
        }
    }

    /// A name as it appears in a JSON Pointer (and so in Agneta's issues), with control characters escaped.
    private static func escape(_ name: String) -> String {
        ResultWording.escapeControls(
            name.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1"))
    }
}
