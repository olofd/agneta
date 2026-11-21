// Structured results: checking a value against its compiled schema.
//
// One validator for every engine and mechanism, so "valid" means the same everywhere. It's pure and total: it never
// throws, and its work is bounded, so a hostile value or schema can't hold anything up. Work is charged as it's done
// (a check, each key, item and stretch of string, each pattern match), pattern matching has its own time, and checking
// recurses once per level of the value, so it runs on a thread with a large stack (`checked`) and stops at a depth.
// Past any bound the value is reported invalid, never passed unchecked. Issues are deterministic (properties in key
// order) and worded for the model, which reads them to correct itself.
import Foundation

/// One way a value doesn't match its schema.
public struct ResultIssue: Sendable, Equatable, Codable {
    /// Where in the value (a JSON Pointer; empty for the whole value).
    public var path: String
    /// The schema keyword that failed (`type`, `required`, …), or `limit` when checking stopped at a bound.
    public var keyword: String
    /// What's wrong, for the model and the app.
    public var message: String
    /// Where in the schema (a JSON Pointer).
    public var schemaPath: String

    public init(path: String, keyword: String, message: String, schemaPath: String) {
        self.path = path
        self.keyword = keyword
        self.message = message
        self.schemaPath = schemaPath
    }
}

extension ResultSchema {
    public struct ValidationLimits: Sendable, Equatable {
        /// Units of work one validation may do: a check, a key, an item, 64 characters of a string, a pattern match.
        public var checks: Int
        /// Time all of a validation's pattern matching may take together, counted as it's spent.
        public var patternTime: Duration
        /// Issues reported at most (at least 1); the model fixes them in one attempt, so more only adds noise.
        public var issues: Int
        /// How deeply the value's arrays and objects may nest before checking stops.
        public var depth: Int
        /// How deeply checks may nest (the value's levels and the schema's references together).
        public var nesting: Int

        public init(checks: Int, patternTime: Duration, issues: Int, depth: Int = 64, nesting: Int = 512) {
            self.checks = checks
            self.patternTime = patternTime
            self.issues = issues
            self.depth = depth
            self.nesting = nesting
        }

        public static let standard = ValidationLimits(checks: 2_000_000, patternTime: .milliseconds(250), issues: 20)
    }

    /// The stack `checked` validates on: enough for `nesting` checks in a debug build, with room to spare.
    static let stackSize = 64 << 20

    /// The ways `value` doesn't match, checked on a thread of its own with a large stack: checking recurses once per
    /// level of the value, and the router's threads have small stacks. What the router calls.
    public func checked(_ value: JSONValue, limits: ValidationLimits = .standard) async -> [ResultIssue] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[ResultIssue], Never>) in
            let thread = Thread { continuation.resume(returning: self.validate(value, limits: limits)) }
            thread.stackSize = Self.stackSize
            thread.name = "agneta.result-validation"
            thread.start()
        }
    }

    /// The ways `value` doesn't match: empty when it does. On the caller's thread: fine for shallow values and tests;
    /// anything that came from outside goes through `checked`.
    public func validate(_ value: JSONValue, limits: ValidationLimits = .standard) -> [ResultIssue] {
        // Whatever the schema looks into: a value deeper than the bound is refused, measured without recursing, so a
        // schema that never descends ({"type": "object"}) can't let one through (and into Agneta's reply to the app).
        guard value.nestingDepth <= limits.depth else {
            return [
                ResultIssue(
                    path: "", keyword: "limit",
                    message: "the value nests more than \(limits.depth) levels deep, more than Agneta accepts",
                    schemaPath: "")
            ]
        }
        let cap = max(1, limits.issues)
        var evaluator = Evaluator(nodes: nodes, limits: limits)
        var issues: [ResultIssue] = []
        evaluator.check(0, value, path: "", into: &issues, cap: cap)
        if let stopped = evaluator.stopped {
            // Whatever was found before the bound, the value wasn't fully checked: it isn't valid.
            issues = Array(issues.prefix(cap - 1)) + [stopped]
        }
        return issues
    }
}

private struct Evaluator {
    let nodes: [ResultSchema.Node]
    let limits: ResultSchema.ValidationLimits
    var workLeft: Int
    var patternLeft: Duration
    /// Set when checking stopped at a bound: the issue that says so.
    var stopped: ResultIssue?
    /// How deep in the value, and how deeply nested in checks, it is now.
    var depth = 0
    var nesting = 0

    init(nodes: [ResultSchema.Node], limits: ResultSchema.ValidationLimits) {
        self.nodes = nodes
        self.limits = limits
        workLeft = limits.checks
        patternLeft = limits.patternTime
    }

    mutating func stop(_ path: String, _ message: String, _ node: ResultSchema.Node) {
        if stopped == nil {
            stopped = ResultIssue(path: path, keyword: "limit", message: message, schemaPath: node.pointer)
        }
    }

    /// Spends `units` of work, or stops checking when there are none left.
    mutating func charge(_ units: Int, _ path: String, _ node: ResultSchema.Node) -> Bool {
        workLeft -= units
        guard workLeft >= 0 else {
            stop(path, "the value is too large or complex to check within Agneta's limits", node)
            return false
        }
        return true
    }

    /// Adds the ways `value` doesn't match node `index` to `issues`, up to `cap` of them.
    mutating func check(_ index: Int, _ value: JSONValue, path: String, into issues: inout [ResultIssue], cap: Int) {
        guard stopped == nil, issues.count < cap else { return }
        let node = nodes[index]
        nesting += 1
        defer { nesting -= 1 }
        guard nesting <= limits.nesting else {
            stop(path, "the schema's references nest too deeply to check this value", node)
            return
        }
        guard charge(1, path, node) else { return }
        func add(_ keyword: String, _ message: String) {
            Self.push(&issues, cap: cap, path: path, node: node, keyword: keyword, message: message)
        }
        if let always = node.always {
            if !always {
                issues.append(
                    ResultIssue(
                        path: path, keyword: "false", message: "no value is allowed here", schemaPath: node.pointer))
            }
            return
        }
        if let reference = node.reference { check(reference, value, path: path, into: &issues, cap: cap) }
        if let types = node.types, !Self.matches(value, types) {
            add("type", "expected \(Self.describe(types)), got \(Self.describe(value))")
            return // the other keywords would only repeat that it's the wrong kind of value
        }
        if let values = node.enumValues {
            guard charge(values.count, path, node) else { return }
            if !values.contains(where: { JSONEquality.equal($0, value) }) {
                add(
                    "enum",
                    "must be one of \(values.prefix(10).map(Self.preview).joined(separator: ", "))"
                        + (values.count > 10 ? ", … (\(values.count) in all)" : ""))
            }
        }
        if let constant = node.constant, !JSONEquality.equal(constant, value) {
            add("const", "must be \(Self.preview(constant))")
        }
        switch value {
        case .object(let fields): checkObject(node, fields, path: path, into: &issues, cap: cap)
        case .array(let items): checkArray(node, items, path: path, into: &issues, cap: cap)
        case .int, .double: checkNumber(node, value, path: path, into: &issues, cap: cap)
        case .string(let string): checkString(node, string, path: path, into: &issues, cap: cap)
        default: break
        }
        for child in node.allOf { check(child, value, path: path, into: &issues, cap: cap) }
        if !node.anyOf.isEmpty {
            // In order, stopping at the first form that matches; when none does, every form's issues are known.
            var failed: [[ResultIssue]] = []
            for child in node.anyOf {
                let found = attempt(child, value, path: path)
                if found.isEmpty || stopped != nil { break }
                failed.append(found)
            }
            if failed.count == node.anyOf.count, stopped == nil {
                let best = Self.closest(failed, at: path)
                add(
                    "anyOf",
                    "doesn't match any of the \(node.anyOf.count) allowed forms; the closest, form #\(best + 1), fails as follows"
                )
                issues.append(contentsOf: failed[best].prefix(max(0, cap - issues.count)))
            }
        }
        if !node.oneOf.isEmpty {
            // Until a second form matches.
            var results: [[ResultIssue]] = []
            for child in node.oneOf {
                results.append(attempt(child, value, path: path))
                if stopped != nil || results.filter(\.isEmpty).count > 1 { break }
            }
            let passing = results.indices.filter { results[$0].isEmpty }
            if stopped == nil {
                if passing.isEmpty {
                    let best = Self.closest(results, at: path)
                    add(
                        "oneOf",
                        "doesn't match any of the \(node.oneOf.count) allowed forms; the closest, form #\(best + 1), fails as follows"
                    )
                    issues.append(contentsOf: results[best].prefix(max(0, cap - issues.count)))
                } else if passing.count > 1 {
                    add(
                        "oneOf",
                        "matches more than one of the allowed forms (#\(passing[0] + 1) and #\(passing[1] + 1)) but must "
                            + "match exactly one")
                }
            }
        }
        if let excluded = node.not, attempt(excluded, value, path: path).isEmpty, stopped == nil {
            add("not", "matches a form that isn't allowed here")
        }
    }

    /// The issues `value` has against one branch, without adding them anywhere.
    mutating func attempt(_ index: Int, _ value: JSONValue, path: String) -> [ResultIssue] {
        var found: [ResultIssue] = []
        check(index, value, path: path, into: &found, cap: 10)
        return found
    }

    /// One level deeper into the value, or false (and checking stopped) past the bound.
    mutating func descend(at: String, node: ResultSchema.Node) -> Bool {
        guard depth < limits.depth else {
            stop(at, "the value nests more than \(limits.depth) levels deep, more than Agneta checks", node)
            return false
        }
        depth += 1
        return true
    }

    mutating func checkObject(
        _ node: ResultSchema.Node, _ fields: [String: JSONValue], path: String, into issues: inout [ResultIssue],
        cap: Int
    ) {
        guard node.constrainsObjects, charge(fields.count, path, node) else { return }
        func add(_ keyword: String, _ message: String, _ at: String) {
            Self.push(&issues, cap: cap, path: at, node: node, keyword: keyword, message: message)
        }
        // Names compared by their code points (JSON Schema's equality), not Swift's canonical equivalence.
        let present = Set(fields.keys.map { Data($0.utf8) })
        for name in node.required where !present.contains(Data(name.utf8)) {
            add("required", "is missing the required property \(Self.quoted(name))", path)
        }
        if let least = node.minProperties, fields.count < least {
            add("minProperties", "must have at least \(least) properties, has \(fields.count)", path)
        }
        if let most = node.maxProperties, fields.count > most {
            add("maxProperties", "must have at most \(most) properties, has \(fields.count)", path)
        }
        for name in fields.keys.sorted() {
            let value = fields[name]!, at = path + "/" + escape(name)
            guard descend(at: at, node: node) else { return }
            defer { depth -= 1 }
            if let names = node.propertyNames {
                // About the name, not the value: said so, or the model would change the value.
                var found: [ResultIssue] = []
                check(names, .string(name), path: at, into: &found, cap: max(1, cap - issues.count))
                issues.append(
                    contentsOf: found.map {
                        var issue = $0
                        if issue.keyword != "limit" { issue.message = "the property's name " + issue.message }
                        return issue
                    })
            }
            var matched = false
            if let child = node.properties[Data(name.utf8)] {
                matched = true
                check(child, value, path: at, into: &issues, cap: cap)
            }
            for (pattern, child) in node.patternProperties {
                guard let hit = match(pattern, name, at: at, node: node) else { return }
                if hit {
                    matched = true
                    check(child, value, path: at, into: &issues, cap: cap)
                }
            }
            if !matched, let extra = node.additionalProperties {
                if nodes[extra].always == false {
                    add("additionalProperties", "\(Self.quoted(name)) isn't one of the allowed properties", at)
                } else {
                    check(extra, value, path: at, into: &issues, cap: cap)
                }
            }
            if stopped != nil || issues.count >= cap { return }
        }
    }

    mutating func checkArray(
        _ node: ResultSchema.Node, _ items: [JSONValue], path: String, into issues: inout [ResultIssue], cap: Int
    ) {
        guard node.constrainsArrays, charge(items.count, path, node) else { return }
        func add(_ keyword: String, _ message: String) {
            Self.push(&issues, cap: cap, path: path, node: node, keyword: keyword, message: message)
        }
        if let least = node.minItems, items.count < least {
            add("minItems", "must have at least \(least) items, has \(items.count)")
        }
        if let most = node.maxItems, items.count > most {
            add("maxItems", "must have at most \(most) items, has \(items.count)")
        }
        for (i, item) in items.enumerated() {
            guard let child = i < node.prefixItems.count ? node.prefixItems[i] : node.items else { continue }
            guard descend(at: path + "/\(i)", node: node) else { return }
            defer { depth -= 1 }
            check(child, item, path: path + "/\(i)", into: &issues, cap: cap)
            if stopped != nil || issues.count >= cap { return }
        }
        if node.uniqueItems {
            // One pass over each item's canonical form, keyed by its bytes (equal exactly when JSON equality says so),
            // not every pair: a long array stays linear.
            var seen: [Data: Int] = [:]
            for (i, item) in items.enumerated() {
                let key = Data(JSONEquality.canonical(item).utf8)
                guard charge(1 + key.count / 64, path, node) else { return }
                if let first = seen[key] {
                    add("uniqueItems", "items \(first) and \(i) are the same; every item must be different")
                    break
                }
                seen[key] = i
            }
        }
    }

    func checkNumber(
        _ node: ResultSchema.Node, _ value: JSONValue, path: String, into issues: inout [ResultIssue], cap: Int
    ) {
        func add(_ keyword: String, _ message: String) {
            Self.push(&issues, cap: cap, path: path, node: node, keyword: keyword, message: message)
        }
        let shown = Self.preview(value)
        if let bound = node.minimum, JSONNumber.compare(value, bound) < 0 {
            add("minimum", "must be at least \(Self.preview(bound)), is \(shown)")
        }
        if let bound = node.maximum, JSONNumber.compare(value, bound) > 0 {
            add("maximum", "must be at most \(Self.preview(bound)), is \(shown)")
        }
        if let bound = node.exclusiveMinimum, JSONNumber.compare(value, bound) <= 0 {
            add("exclusiveMinimum", "must be more than \(Self.preview(bound)), is \(shown)")
        }
        if let bound = node.exclusiveMaximum, JSONNumber.compare(value, bound) >= 0 {
            add("exclusiveMaximum", "must be less than \(Self.preview(bound)), is \(shown)")
        }
        if let step = node.multipleOf, !JSONNumber.isMultiple(value, of: step) {
            add("multipleOf", "must be a multiple of \(Self.preview(step)), is \(shown)")
        }
    }

    mutating func checkString(
        _ node: ResultSchema.Node, _ string: String, path: String, into issues: inout [ResultIssue], cap: Int
    ) {
        func add(_ keyword: String, _ message: String) {
            Self.push(&issues, cap: cap, path: path, node: node, keyword: keyword, message: message)
        }
        if node.minLength != nil || node.maxLength != nil {
            // JSON Schema counts characters as Unicode code points; counting is charged by the string's length.
            guard charge(1 + string.utf8.count / 64, path, node) else { return }
            let length = string.unicodeScalars.count
            if let least = node.minLength, length < least {
                add("minLength", "must be at least \(least) characters long, is \(length)")
            }
            if let most = node.maxLength, length > most {
                add("maxLength", "must be at most \(most) characters long, is \(length)")
            }
        }
        if let pattern = node.pattern {
            switch match(pattern, string, at: path, node: node) {
            case true?: break
            case false?: add("pattern", "must match the pattern \(Self.quoted(pattern.source, limit: 200))")
            case nil: break // stopped
            }
        }
    }

    /// Matches a pattern, charging the work and the time it actually takes; nil (and checking stopped) when the
    /// pattern time runs out.
    mutating func match(_ pattern: Pattern, _ string: String, at: String, node: ResultSchema.Node) -> Bool? {
        guard charge(1 + string.utf8.count / 256, at, node) else { return nil }
        let started = ContinuousClock.now
        let hit = pattern.matches(string, deadline: started + patternLeft)
        patternLeft -= ContinuousClock.now - started
        guard let hit else {
            stop(
                at, "checking the pattern \(Self.quoted(pattern.source, limit: 200)) took longer than Agneta allows",
                node)
            return nil
        }
        return hit
    }

    static func push(
        _ issues: inout [ResultIssue], cap: Int, path: String, node: ResultSchema.Node, keyword: String, message: String
    ) {
        guard issues.count < cap else { return }
        issues.append(
            ResultIssue(path: path, keyword: keyword, message: message, schemaPath: node.pointer + "/" + keyword))
    }

    // MARK: Wording

    static func matches(_ value: JSONValue, _ types: Set<ResultSchema.Kind>) -> Bool {
        switch value {
        case .null: types.contains(.null)
        case .bool: types.contains(.boolean)
        case .object: types.contains(.object)
        case .array: types.contains(.array)
        case .string: types.contains(.string)
        case .int: types.contains(.number) || types.contains(.integer)
        case .double(let d): types.contains(.number) || (types.contains(.integer) && d.isFinite && d.rounded() == d)
        }
    }

    static func describe(_ types: Set<ResultSchema.Kind>) -> String {
        let order: [ResultSchema.Kind] = [.object, .array, .string, .number, .integer, .boolean, .null]
        let names = order.filter(types.contains).map(name)
        return names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " or " + names.last!
    }

    static func name(_ kind: ResultSchema.Kind) -> String {
        switch kind {
        case .null: "null"
        case .boolean: "true or false"
        case .object: "an object"
        case .array: "an array"
        case .number: "a number"
        case .string: "a string"
        case .integer: "a whole number"
        }
    }

    static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let b): "\(b)"
        case .object: "an object"
        case .array: "an array"
        case .string: "a string"
        case .int, .double: "the number \(preview(value))"
        }
    }

    /// A name or pattern in a message: in quotes, control characters escaped and long ones cut, so text from the value
    /// can't pass for a line of Agneta's own or fill the model's context.
    static func quoted(_ text: String, limit: Int = 60) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\"": out += "\\\""
            case _
            where scalar.value < 0x20 || scalar.value == 0x7f || scalar.value == 0x2028 || scalar.value == 0x2029:
                out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        if out.count > limit { out = String(out.prefix(limit - 1)) + "…" }
        return "\"" + out + "\""
    }

    /// A short JSON rendering of a value for a message.
    static func preview(_ value: JSONValue) -> String {
        let text: String
        switch value {
        case .int(let n): text = "\(n)"
        case .double(let d): text = d.rounded() == d && abs(d) < 1e15 ? "\(Int64(d))" : "\(d)"
        default: text = (try? JSONCoding.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
        }
        return text.count > 60 ? String(text.prefix(57)) + "…" : text
    }

    /// For anyOf and oneOf: the form to show the model when none matched. Forms whose type matched come first (a
    /// type mismatch is one issue, which would otherwise always look closest: an object missing a field would be told
    /// to be null), then the one with the fewest issues, then the first.
    static func closest(_ branches: [[ResultIssue]], at path: String) -> Int {
        func typeMismatch(_ issues: [ResultIssue]) -> Bool {
            guard let first = issues.first else { return false }
            return first.keyword == "type" && first.path == path
        }
        var best = 0
        for index in branches.indices.dropFirst() {
            let (mismatch, bestMismatch) = (typeMismatch(branches[index]), typeMismatch(branches[best]))
            if mismatch != bestMismatch {
                if !mismatch { best = index }
            } else if branches[index].count < branches[best].count {
                best = index
            }
        }
        return best
    }
}

/// JSON numbers compared exactly: integers as integers, an integer against a double without rounding either.
enum JSONNumber {
    static func isPositive(_ value: JSONValue) -> Bool {
        switch value {
        case .int(let n): n > 0
        case .double(let d): d > 0 && d.isFinite
        default: false
        }
    }

    /// -1, 0 or 1. Both must be numbers.
    static func compare(_ a: JSONValue, _ b: JSONValue) -> Int {
        switch (a, b) {
        case (.int(let x), .int(let y)): return x < y ? -1 : (x == y ? 0 : 1)
        case (.double(let x), .double(let y)): return x < y ? -1 : (x == y ? 0 : 1)
        case (.int(let x), .double(let y)): return compare(x, y)
        case (.double(let x), .int(let y)): return -compare(y, x)
        default: return 0
        }
    }

    /// An integer against a double, exactly.
    private static func compare(_ x: Int64, _ y: Double) -> Int {
        if y.isNaN { return 0 }
        if y >= 9_223_372_036_854_775_808.0 { return -1 }
        if y < -9_223_372_036_854_775_808.0 { return 1 }
        let whole = Int64(y.rounded(.towardZero))
        if x != whole { return x < whole ? -1 : 1 }
        let fraction = y - y.rounded(.towardZero)
        return fraction > 0 ? -1 : (fraction < 0 ? 1 : 0)
    }

    /// Whether `value` is a whole multiple of `step` (> 0), exactly, as written: each number is a decimal significand
    /// (at most 19 digits) times a power of ten, and divisibility is decided in integer arithmetic, so 0.0075 is a
    /// multiple of 0.0001, and 1e100 isn't a multiple of 3.
    static func isMultiple(_ value: JSONValue, of step: JSONValue) -> Bool {
        if case .int(let x) = value, case .int(let s) = step { return x % s == 0 }
        guard let (a, p) = decimal(value), let (b, q) = decimal(step), b > 0 else { return false }
        if a == 0 { return true }
        if p >= q {
            // a·10^(p−q) ≡ 0 (mod b)
            return mulMod(a % b, powMod(10, p - q, b), b) == 0
        }
        // a must be divisible by b·10^(q−p), which, being more than a, it can't be unless it divides exactly.
        var divisor = b
        for _ in 0..<(q - p) {
            let (next, overflow) = divisor.multipliedReportingOverflow(by: 10)
            if overflow { return false }
            divisor = next
        }
        return a % divisor == 0
    }

    /// The number as (significand, exponent): its magnitude is significand · 10^exponent, significand without
    /// trailing zeros. From the shortest decimal that reads back as the same double, which is what the JSON held.
    static func decimal(_ value: JSONValue) -> (UInt64, Int)? {
        let text: String
        switch value {
        case .int(let n): return normalized(n.magnitude, 0)
        case .double(let d) where d.isFinite: text = "\(d.magnitude)"
        default: return nil
        }
        var digits = "", exponent = 0, seenPoint = false
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c == "e" || c == "E" {
                exponent += Int(text[text.index(after: index)...]) ?? 0
                break
            }
            if c == "." {
                seenPoint = true
            } else if c.wholeNumberValue != nil {
                digits.append(c)
                if seenPoint { exponent -= 1 }
            }
            index = text.index(after: index)
        }
        let trimmed = digits.drop { $0 == "0" }
        guard let significand = UInt64(trimmed.isEmpty ? "0" : String(trimmed)) else { return nil }
        return normalized(significand, exponent)
    }

    private static func normalized(_ significand: UInt64, _ exponent: Int) -> (UInt64, Int) {
        var (s, e) = (significand, exponent)
        while s != 0, s % 10 == 0 {
            s /= 10
            e += 1
        }
        return (s, e)
    }

    static func mulMod(_ a: UInt64, _ b: UInt64, _ m: UInt64) -> UInt64 {
        let product = a.multipliedFullWidth(by: b)
        return m.dividingFullWidth((product.high, product.low)).remainder
    }

    static func powMod(_ base: UInt64, _ exponent: Int, _ m: UInt64) -> UInt64 {
        var result: UInt64 = 1 % m, b = base % m, e = exponent
        while e > 0 {
            if e & 1 == 1 { result = mulMod(result, b, m) }
            b = mulMod(b, b, m)
            e >>= 1
        }
        return result
    }
}

/// JSON equality as JSON Schema means it: 1 and 1.0 are equal, objects regardless of key order, strings by their code
/// points (not Swift's canonical equivalence, which calls two spellings of "é" equal).
enum JSONEquality {
    static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.int, .int), (.int, .double), (.double, .int), (.double, .double): return JSONNumber.compare(a, b) == 0
        case (.string(let x), .string(let y)): return x.unicodeScalars.elementsEqual(y.unicodeScalars)
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case (.object(let x), .object(let y)):
            guard x.count == y.count else { return false }
            var others: [Data: JSONValue] = [:]
            for (key, value) in y { others[Data(key.utf8)] = value }
            return x.allSatisfy { key, value in others[Data(key.utf8)].map { equal(value, $0) } ?? false }
        default: return a == b
        }
    }

    /// A string equal for exactly the values `equal` calls equal: numbers in one form, keys sorted by their bytes,
    /// strings as their code points.
    static func canonical(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let n): return "\(n)"
        case .double(let d):
            if d.rounded() == d, d >= -9_223_372_036_854_775_808.0, d < 9_223_372_036_854_775_808.0 {
                return "\(Int64(d))"
            }
            return "\(d)"
        case .string(let s):
            let points: [String] = s.unicodeScalars.map { String($0.value, radix: 16) }
            return "\"\(points.joined(separator: ","))\""
        case .array(let items):
            let parts: [String] = items.map(canonical)
            return "[\(parts.joined(separator: ","))]"
        case .object(let fields):
            let keys: [String] = fields.keys.sorted { (a: String, b: String) -> Bool in
                Data(a.utf8).lexicographicallyPrecedes(Data(b.utf8))
            }
            var parts: [String] = []
            for key in keys { parts.append(canonical(.string(key)) + ":" + canonical(fields[key]!)) }
            return "{\(parts.joined(separator: ","))}"
        }
    }
}
