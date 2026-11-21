// Structured results: checking a value against its compiled schema.
//
// One validator for every engine and mechanism, so "valid" means the same everywhere. It's pure and total: it never
// throws, and its work is bounded (a count of schema checks and a time for patterns), so a hostile value or schema
// can't hold up the router. Past a bound the value is reported invalid, never passed unchecked. Issues are
// deterministic (properties in key order) and worded for the model, which reads them to correct itself.
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
        /// Schema checks one validation may make; anyOf and oneOf over large values multiply them.
        public var checks: Int
        /// Time all of a validation's pattern matching may take together.
        public var patternTime: Duration
        /// Issues reported at most; the model fixes them in one attempt, so more than a screenful only adds noise.
        public var issues: Int
        /// How deeply a value's arrays and objects may nest. Checking recurses a few calls per level, on whatever
        /// thread the caller runs (the router's, with a small stack), so a value nested deeper is reported, never
        /// walked into. Real results nest a handful of levels.
        public var depth: Int

        public init(checks: Int, patternTime: Duration, issues: Int, depth: Int = 32) {
            self.checks = checks
            self.patternTime = patternTime
            self.issues = issues
            self.depth = depth
        }

        public static let standard = ValidationLimits(
            checks: 2_000_000, patternTime: .milliseconds(250), issues: 20, depth: 32)
    }

    /// The ways `value` doesn't match: empty when it does.
    public func validate(_ value: JSONValue, limits: ValidationLimits = .standard) -> [ResultIssue] {
        var evaluator = Evaluator(
            nodes: nodes, checksLeft: limits.checks, deadline: ContinuousClock.now + limits.patternTime,
            maxDepth: limits.depth)
        var issues: [ResultIssue] = []
        evaluator.check(0, value, path: "", into: &issues, cap: limits.issues)
        if let stopped = evaluator.stopped {
            // Whatever was found before the bound, the value wasn't fully checked: it isn't valid.
            issues = Array(issues.prefix(limits.issues - 1)) + [stopped]
        }
        return issues
    }
}

private struct Evaluator {
    let nodes: [ResultSchema.Node]
    var checksLeft: Int
    let deadline: ContinuousClock.Instant
    let maxDepth: Int
    /// Set when checking stopped at a bound: the issue that says so.
    var stopped: ResultIssue?
    /// How deep in the value the check now is.
    var depth = 0

    /// Adds the ways `value` doesn't match node `index` to `issues`, up to `cap` of them.
    mutating func check(_ index: Int, _ value: JSONValue, path: String, into issues: inout [ResultIssue], cap: Int) {
        guard stopped == nil, issues.count < cap else { return }
        checksLeft -= 1
        guard checksLeft >= 0 else {
            stopped = ResultIssue(
                path: path, keyword: "limit",
                message: "the value is too large or complex to check within Agneta's limits",
                schemaPath: nodes[index].pointer)
            return
        }
        let node = nodes[index]
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
        if let values = node.enumValues, !values.contains(where: { JSONEquality.equal($0, value) }) {
            add(
                "enum",
                "must be one of \(values.prefix(10).map(Self.preview).joined(separator: ", "))"
                    + (values.count > 10 ? ", … (\(values.count) in all)" : ""))
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
            let branches = node.anyOf.map { attempt($0, value, path: path) }
            if !branches.contains(where: \.isEmpty), stopped == nil {
                add("anyOf", "doesn't match any of the \(node.anyOf.count) allowed forms" + Self.closest(branches))
                issues.append(
                    contentsOf: (branches.min { $0.count < $1.count } ?? []).prefix(max(0, cap - issues.count)))
            }
        }
        if !node.oneOf.isEmpty {
            let branches = node.oneOf.map { attempt($0, value, path: path) }
            let passing = branches.indices.filter { branches[$0].isEmpty }
            if stopped == nil {
                if passing.isEmpty {
                    add("oneOf", "doesn't match any of the \(node.oneOf.count) allowed forms" + Self.closest(branches))
                    issues.append(
                        contentsOf: (branches.min { $0.count < $1.count } ?? []).prefix(max(0, cap - issues.count)))
                } else if passing.count > 1 {
                    add(
                        "oneOf",
                        "matches \(passing.count) of the allowed forms (\(passing.map { "#\($0 + 1)" }.joined(separator: ", "))) but must match exactly one"
                    )
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

    mutating func checkObject(
        _ node: ResultSchema.Node, _ fields: [String: JSONValue], path: String, into issues: inout [ResultIssue],
        cap: Int
    ) {
        func add(_ keyword: String, _ message: String, _ at: String) {
            Self.push(&issues, cap: cap, path: at, node: node, keyword: keyword, message: message)
        }
        for name in node.required where fields[name] == nil {
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
                check(names, .string(name), path: at, into: &issues, cap: cap)
            }
            var matched = false
            if let child = node.properties[name] {
                matched = true
                check(child, value, path: at, into: &issues, cap: cap)
            }
            for (pattern, child) in node.patternProperties {
                guard let hit = pattern.matches(name, deadline: deadline) else {
                    timedOut(at: at, pattern: pattern, node: node)
                    return
                }
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
        func add(_ keyword: String, _ message: String, _ at: String) {
            Self.push(&issues, cap: cap, path: at, node: node, keyword: keyword, message: message)
        }
        if let least = node.minItems, items.count < least {
            add("minItems", "must have at least \(least) items, has \(items.count)", path)
        }
        if let most = node.maxItems, items.count > most {
            add("maxItems", "must have at most \(most) items, has \(items.count)", path)
        }
        for (i, item) in items.enumerated() {
            guard descend(at: path + "/\(i)", node: node) else { return }
            defer { depth -= 1 }
            let child = i < node.prefixItems.count ? node.prefixItems[i] : node.items
            if let child { check(child, item, path: path + "/\(i)", into: &issues, cap: cap) }
            if stopped != nil || issues.count >= cap { return }
        }
        if node.uniqueItems {
            // One pass over each item's canonical form (JSON equality: 1 and 1.0 alike, keys in order), not every
            // pair: a long array stays linear.
            var seen: [String: Int] = [:]
            for (i, item) in items.enumerated() {
                checksLeft -= 1
                if checksLeft < 0 {
                    stopped = ResultIssue(
                        path: path, keyword: "limit",
                        message: "the value is too large or complex to check within Agneta's limits",
                        schemaPath: node.pointer + "/uniqueItems")
                    return
                }
                let key = JSONEquality.canonical(item)
                if let first = seen[key] {
                    add("uniqueItems", "items \(first) and \(i) are the same; every item must be different", path)
                    break
                }
                seen[key] = i
            }
        }
    }

    func checkNumber(
        _ node: ResultSchema.Node, _ value: JSONValue, path: String, into issues: inout [ResultIssue], cap: Int
    ) {
        func add(_ keyword: String, _ message: String, _ at: String) {
            Self.push(&issues, cap: cap, path: path, node: node, keyword: keyword, message: message)
        }
        let shown = Self.preview(value)
        if let bound = node.minimum, JSONNumber.compare(value, bound) < 0 {
            add("minimum", "must be at least \(Self.preview(bound)), is \(shown)", "")
        }
        if let bound = node.maximum, JSONNumber.compare(value, bound) > 0 {
            add("maximum", "must be at most \(Self.preview(bound)), is \(shown)", "")
        }
        if let bound = node.exclusiveMinimum, JSONNumber.compare(value, bound) <= 0 {
            add("exclusiveMinimum", "must be more than \(Self.preview(bound)), is \(shown)", "")
        }
        if let bound = node.exclusiveMaximum, JSONNumber.compare(value, bound) >= 0 {
            add("exclusiveMaximum", "must be less than \(Self.preview(bound)), is \(shown)", "")
        }
        if let step = node.multipleOf, !JSONNumber.isMultiple(value, of: step) {
            add("multipleOf", "must be a multiple of \(Self.preview(step)), is \(shown)", "")
        }
    }

    mutating func checkString(
        _ node: ResultSchema.Node, _ string: String, path: String, into issues: inout [ResultIssue], cap: Int
    ) {
        func add(_ keyword: String, _ message: String, _ at: String) {
            Self.push(&issues, cap: cap, path: path, node: node, keyword: keyword, message: message)
        }
        // JSON Schema counts characters as Unicode code points.
        let length = string.unicodeScalars.count
        if let least = node.minLength, length < least {
            add("minLength", "must be at least \(least) characters long, is \(length)", "")
        }
        if let most = node.maxLength, length > most {
            add("maxLength", "must be at most \(most) characters long, is \(length)", "")
        }
        if let pattern = node.pattern {
            switch pattern.matches(string, deadline: deadline) {
            case true?: break
            case false?: add("pattern", "must match the pattern \(Self.quoted(pattern.source, limit: 200))", "")
            case nil: timedOut(at: path, pattern: pattern, node: node)
            }
        }
    }

    /// One level deeper into the value, or false (and checking stopped) past the bound.
    mutating func descend(at: String, node: ResultSchema.Node) -> Bool {
        depth += 1
        guard depth <= maxDepth else {
            depth -= 1
            stopped = ResultIssue(
                path: at, keyword: "limit",
                message: "the value nests more than \(maxDepth) levels deep, more than Agneta checks",
                schemaPath: node.pointer)
            return false
        }
        return true
    }

    mutating func timedOut(at: String?, pattern: Pattern, node: ResultSchema.Node) {
        stopped = ResultIssue(
            path: at ?? "", keyword: "limit",
            message: "checking the pattern \(Self.quoted(pattern.source, limit: 200)) took longer than Agneta allows",
            schemaPath: node.pointer)
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
            case _ where scalar.value < 0x20 || scalar.value == 0x7f || scalar.value == 0x2028 || scalar.value == 0x2029:
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

    /// For anyOf and oneOf: which form came closest, whose issues follow.
    static func closest(_ branches: [[ResultIssue]]) -> String {
        guard let best = branches.indices.min(by: { branches[$0].count < branches[$1].count }) else { return "" }
        return "; the closest, form #\(best + 1), fails as follows"
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

    /// Whether `value` is a whole multiple of `step` (> 0). Decimal arithmetic where it can represent both, so 0.0075
    /// is a multiple of 0.0001; a quotient too large for any number is not a multiple.
    static func isMultiple(_ value: JSONValue, of step: JSONValue) -> Bool {
        if case .int(let x) = value, case .int(let s) = step { return x % s == 0 }
        guard let x = double(value), let s = double(step), s > 0 else { return false }
        if let dx = Decimal(string: text(value)), let ds = Decimal(string: text(step)), !dx.isNaN, !ds.isNaN, ds != 0 {
            var quotient = dx / ds, rounded = Decimal()
            if !quotient.isNaN {
                NSDecimalRound(&rounded, &quotient, 0, .plain)
                return rounded == quotient
            }
        }
        let quotient = x / s
        guard quotient.isFinite else { return false }
        return quotient.rounded() == quotient
    }

    private static func double(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let n): Double(n)
        case .double(let d): d
        default: nil
        }
    }

    private static func text(_ value: JSONValue) -> String {
        switch value {
        case .int(let n): "\(n)"
        case .double(let d): "\(d)"
        default: ""
        }
    }
}

/// JSON equality as JSON Schema means it: 1 and 1.0 are equal, objects regardless of key order.
enum JSONEquality {
    static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.int, .int), (.int, .double), (.double, .int), (.double, .double): JSONNumber.compare(a, b) == 0
        case (.array(let x), .array(let y)): x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case (.object(let x), .object(let y)):
            x.count == y.count && x.allSatisfy { key, value in y[key].map { equal(value, $0) } ?? false }
        default: a == b
        }
    }

    /// A string equal for exactly the values `equal` calls equal: numbers in one form, keys sorted.
    static func canonical(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let n): return "\(n)"
        case .double(let d):
            if d.rounded() == d, abs(d) < 9_223_372_036_854_775_808.0 { return "\(Int64(d))" }
            return "\(d)"
        case .string(let s):
            return (try? JSONCoding.encode(JSONValue.string(s))).flatMap { String(data: $0, encoding: .utf8) } ?? s
        case .array(let items): return "[" + items.map(canonical).joined(separator: ",") + "]"
        case .object(let fields):
            return "{"
                + fields.keys.sorted().map { canonical(.string($0)) + ":" + canonical(fields[$0]!) }
                .joined(separator: ",") + "}"
        }
    }
}
