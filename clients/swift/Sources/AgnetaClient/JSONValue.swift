import Foundation

/// A sendable JSON value. Integers are kept as integers, including trace timestamps and sequence numbers.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let item = try? value.decode(Bool.self) {
            self = .bool(item)
        } else if let item = try? value.decode(Int64.self) {
            self = .integer(item)
        } else if let item = try? value.decode(Double.self) {
            self = .number(item)
        } else if let item = try? value.decode(String.self) {
            self = .string(item)
        } else if let item = try? value.decode([JSONValue].self) {
            self = .array(item)
        } else {
            self = .object(try value.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .integer(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }

    public init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    public subscript(_ key: String) -> JSONValue? { object?[key] }
    public var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
    public var double: Double? {
        switch self {
        case .integer(let value): Double(value);
        case .number(let value): value;
        default: nil
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// A JSON object retained verbatim, so new ACP fields and update kinds remain available.
public protocol JSONBacked: Codable, Sendable, Equatable {
    var raw: JSONValue { get }
    init(raw: JSONValue) throws
}
extension JSONBacked {
    public init(from decoder: any Decoder) throws { try self.init(raw: JSONValue(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
}

func requireObject(_ value: JSONValue) throws {
    guard value.object != nil else { throw AgnetaError(.protocolViolation, "Expected a JSON object.") }
}

// A conservative payload budget, independent of JSON escaping or encoder allocation.
extension JSONValue {
    var payloadSize: Int {
        switch self {
        case .null, .bool, .integer, .number: 32
        case .string(let value): value.utf8.count + 32
        case .array(let values): values.reduce(32) { $0 + $1.payloadSize }
        case .object(let values): values.reduce(64) { $0 + $1.key.utf8.count + $1.value.payloadSize + 32 }
        }
    }
}
