// Any JSON value, carried losslessly. Agneta models only the ACP messages it
// inspects; everything else travels as JSONValue so new protocol or engine
// fields pass through untouched.
import Foundation

public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value: return Int64(exactly: value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// Returns a copy with `key` set; non-objects become an object holding only `key`.
    /// How deeply its arrays and objects nest (a scalar is 0), found without recursing.
    public var nestingDepth: Int {
        var deepest = 0
        var stack: [(JSONValue, Int)] = [(self, 0)]
        while let (value, level) = stack.popLast() {
            switch value {
            case .array(let items):
                deepest = max(deepest, level + 1)
                for item in items { stack.append((item, level + 1)) }
            case .object(let fields):
                deepest = max(deepest, level + 1)
                for item in fields.values { stack.append((item, level + 1)) }
            default: break
            }
        }
        return deepest
    }

    public func setting(_ key: String, to value: JSONValue?) -> JSONValue {
        var fields = objectValue ?? [:]
        fields[key] = value
        return .object(fields)
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

public enum JSONCoding {
    /// Compact, key-sorted output: one message per line and stable snapshots.
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// How deeply arrays and objects may nest in JSON Agneta reads. Decoding recurses once per level, so a small
    /// message nested thousands deep (from an app, an engine, or a model's tool call) would overflow the stack and stop
    /// Agneta: it's refused before decoding. Real messages nest a few dozen levels at most.
    public static let maxDepth = 128

    public static func decode(_ data: Data) throws -> JSONValue {
        guard nesting(of: data) <= maxDepth else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "JSON nested more than \(maxDepth) levels deep"))
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// A message's top-level `id` and `method` (scalars only), read without decoding the rest: for a message nested
    /// too deep to decode, so it can still be answered instead of left waiting. Nil when it isn't a JSON object.
    static func topLevel(of data: Data) -> (id: JSONValue?, method: String?)? {
        let bytes = [UInt8](data)
        var i = 0
        func skipSpace() { while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }
        /// The end (exclusive) of the string starting at `start` (its opening quote).
        func stringEnd(_ start: Int) -> Int? {
            var j = start + 1, escaped = false
            while j < bytes.count {
                if escaped {
                    escaped = false
                } else if bytes[j] == UInt8(ascii: "\\") {
                    escaped = true
                } else if bytes[j] == UInt8(ascii: "\"") {
                    return j + 1
                }
                j += 1
            }
            return nil
        }
        /// The end (exclusive) of any value starting at `start`, nested or not, without recursing.
        func valueEnd(_ start: Int) -> Int? {
            var j = start, depth = 0
            while j < bytes.count {
                switch bytes[j] {
                case UInt8(ascii: "\""):
                    guard let end = stringEnd(j) else { return nil }
                    j = end
                    if depth == 0 { return j }
                    continue
                case UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    depth -= 1
                    if depth == 0 { return j + 1 }
                    if depth < 0 { return j }
                case UInt8(ascii: ","): if depth == 0 { return j }
                default: break
                }
                j += 1
            }
            return depth == 0 ? j : nil
        }
        skipSpace()
        guard i < bytes.count, bytes[i] == UInt8(ascii: "{") else { return nil }
        i += 1
        var id: JSONValue?, method: String?
        while i < bytes.count {
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { break }
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\""), let keyEnd = stringEnd(i),
                let key = try? JSONDecoder().decode(String.self, from: Data(bytes[i..<keyEnd]))
            else { return nil }
            i = keyEnd
            skipSpace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
            i += 1
            skipSpace()
            guard let end = valueEnd(i) else { return nil }
            if key == "id" || key == "method", let scalar = try? decode(Data(bytes[i..<end])) {
                if key == "id" { id = scalar } else { method = scalar.stringValue }
            }
            i = end
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: ",") { i += 1 }
        }
        return (id, method)
    }

    /// The deepest nesting of arrays and objects in `data`, read byte by byte (brackets inside strings don't count),
    /// stopping as soon as it's past `maxDepth`.
    static func nesting(of data: Data) -> Int {
        var depth = 0, deepest = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth > deepest {
                    deepest = depth
                    if deepest > maxDepth { return deepest }
                }
            case UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
            default: break
            }
        }
        return deepest
    }
}
