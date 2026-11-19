// JSON-RPC 2.0 messages as ACP uses them. The router remaps request IDs per
// hop, so IDs from different apps and engines never collide.
import Foundation

public enum RPCID: Sendable, Hashable, CustomStringConvertible {
    case int(Int64)
    case string(String)

    public init?(_ value: JSONValue?) {
        switch value {
        case .int(let id)?: self = .int(id)
        // Exactly representable or malformed: Int64(1e300) would trap.
        case .double(let id)?: guard let exact = Int64(exactly: id) else { return nil }; self = .int(exact)
        case .string(let id)?: self = .string(id)
        default: return nil
        }
    }

    public var json: JSONValue {
        switch self {
        case .int(let id): .int(id)
        case .string(let id): .string(id)
        }
    }

    public var description: String {
        switch self {
        case .int(let id): String(id)
        case .string(let id): id
        }
    }
}

public struct RPCError: Error, Sendable, Hashable {
    public var code: Int64
    public var message: String
    public var data: JSONValue?

    public init(code: Int64, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static let parseError: Int64 = -32700
    public static let invalidRequest: Int64 = -32600
    public static let methodNotFound: Int64 = -32601
    public static let invalidParams: Int64 = -32602
    public static let internalError: Int64 = -32603
    /// ACP's request-cancelled code.
    public static let requestCancelled: Int64 = -32800

    public var json: JSONValue {
        var fields: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { fields["data"] = data }
        return .object(fields)
    }

    public init?(_ value: JSONValue?) {
        guard let code = value?["code"]?.intValue, let message = value?["message"]?.stringValue else { return nil }
        self.init(code: code, message: message, data: value?["data"])
    }
}

public enum RPCMessage: Sendable, Hashable {
    case request(id: RPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: RPCID, result: Result<JSONValue, RPCError>)

    public enum ParseFailure: Error, Equatable {
        case notJSON
        case notObject
        case wrongVersion
        case malformed(String)
    }

    public static func parse(_ data: Data) throws -> RPCMessage {
        let value: JSONValue
        do { value = try JSONCoding.decode(data) } catch { throw ParseFailure.notJSON }
        return try parse(value)
    }

    public static func parse(_ value: JSONValue) throws -> RPCMessage {
        guard let fields = value.objectValue else { throw ParseFailure.notObject }
        guard fields["jsonrpc"]?.stringValue == "2.0" else { throw ParseFailure.wrongVersion }
        if let method = fields["method"]?.stringValue {
            if let rawID = fields["id"] {
                guard let id = RPCID(rawID) else { throw ParseFailure.malformed("id") }
                return .request(id: id, method: method, params: fields["params"])
            }
            return .notification(method: method, params: fields["params"])
        }
        guard let id = RPCID(fields["id"]) else { throw ParseFailure.malformed("response id") }
        if let error = RPCError(fields["error"]) { return .response(id: id, result: .failure(error)) }
        let error = fields["error"].flatMap { $0 == .null ? nil : $0 }
        if error == nil, let result = fields["result"] { return .response(id: id, result: .success(result)) }
        // An error that isn't well formed (no message, a string code) is still an error: dropped as malformed, the
        // request it answers would wait for ever.
        guard let error = error ?? fields["error"] else {
            throw ParseFailure.malformed("response without result or error")
        }
        let message =
            error["message"]?.stringValue ?? error.stringValue ?? "The other side answered with a malformed error"
        // A usable code stays: -32000 (sign-in required) and -32601 (method not found) are acted on by code.
        return .response(
            id: id,
            result: .failure(
                RPCError(code: error["code"]?.intValue ?? RPCError.internalError, message: message, data: error)))
    }

    public var json: JSONValue {
        switch self {
        case .request(let id, let method, let params):
            var fields: [String: JSONValue] = ["jsonrpc": "2.0", "id": id.json, "method": .string(method)]
            if let params { fields["params"] = params }
            return .object(fields)
        case .notification(let method, let params):
            var fields: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
            if let params { fields["params"] = params }
            return .object(fields)
        case .response(let id, .success(let result)):
            return ["jsonrpc": "2.0", "id": id.json, "result": result]
        case .response(let id, .failure(let error)):
            return ["jsonrpc": "2.0", "id": id.json, "error": error.json]
        }
    }

    public func encoded() throws -> Data { try JSONCoding.encode(json) }

    public var method: String? {
        switch self {
        case .request(_, let method, _), .notification(let method, _): method
        case .response: nil
        }
    }
}

/// Maps IDs on one hop to fresh IDs on the next, and back. One table per
/// outgoing peer; entries are removed when the response passes back.
public struct RPCIDMap: Sendable {
    private var next: Int64 = 1
    private var originals: [Int64: RPCID] = [:]

    public init() {}

    public mutating func forward(_ original: RPCID) -> RPCID {
        let mapped = next
        next += 1
        originals[mapped] = original
        return .int(mapped)
    }

    /// The original ID for a response coming back, or nil if unknown.
    public mutating func reverse(_ mapped: RPCID) -> RPCID? {
        guard case .int(let key) = mapped else { return nil }
        return originals.removeValue(forKey: key)
    }

    public var pending: Int { originals.count }
}
