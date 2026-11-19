// JSON lines for task traces: a fixed header order (v, seq, t, mono, task,
// turn, type) so a trace reads well in `tail`, then the record's own fields in
// sorted order. And secret masking, applied to every value before it's written.
import Foundation

enum TraceJSON {
    static let header = ["v", "seq", "t", "mono", "task", "turn", "type"]

    /// One line, header keys first. `fields` must not repeat a header key.
    static func line(header values: [(String, JSONValue)], fields: [String: JSONValue]) -> Data {
        var out = "{"
        var first = true
        for (key, value) in values {
            if !first { out += "," }
            first = false
            write(key, value, into: &out)
        }
        for key in fields.keys.sorted() {
            if !first { out += "," }
            first = false
            write(key, fields[key]!, into: &out)
        }
        out += "}\n"
        return Data(out.utf8)
    }

    private static func write(_ key: String, _ value: JSONValue, into out: inout String) {
        string(key, into: &out)
        out += ":"
        encode(value, into: &out)
    }

    static func encode(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .int(let number): out += String(number)
        case .double(let number): out += number.isFinite ? String(number) : "null"
        case .string(let text): string(text, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                encode(item, into: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            for (index, key) in fields.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                write(key, fields[key]!, into: &out)
            }
            out += "}"
        }
    }

    static func string(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

/// Masks secrets in trace values: registered exact values (Agneta's tokens, an app's MCP
/// bearer, API keys), values under secret-named keys, and known key shapes in any string.
public final class SecretMask: @unchecked Sendable {
    public static let replacement = "‹masked›"
    private let lock = NSLock()
    private var exact: Set<String> = []

    public init() {}

    /// Registers a value to mask wherever it appears. Short values are ignored (too likely to collide).
    public func register(_ secret: String) {
        guard secret.count >= 12 else { return }
        lock.withLock { _ = exact.insert(secret) }
    }

    static let secretKeys: Set<String> = [
        "authorization", "proxy-authorization", "token", "access_token", "refresh_token", "id_token",
        "api_key", "apikey", "x-api-key", "password", "secret", "client_secret", "bearer", "cookie"
    ]

    static func isSecretKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return secretKeys.contains(lower) || lower.hasSuffix("_token") || lower.hasSuffix("api_key")
            || lower.hasSuffix("apikey")
    }

    // sk-… (OpenAI, Anthropic), Bearer values, JWTs.
    static let patterns: [NSRegularExpression] = [
        "sk-[A-Za-z0-9_\\-]{16,}",
        "(?i)bearer\\s+[A-Za-z0-9._~+/=\\-]{8,}",
        "eyJ[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}"
    ].map { try! NSRegularExpression(pattern: $0) }

    public func mask(_ value: JSONValue) -> JSONValue {
        let exact = lock.withLock { self.exact }
        return Self.mask(value, exact: exact)
    }

    public func mask(_ text: String) -> String {
        let exact = lock.withLock { self.exact }
        return Self.mask(text, exact: exact)
    }

    static func mask(_ value: JSONValue, exact: Set<String>) -> JSONValue {
        switch value {
        case .string(let text): return .string(mask(text, exact: exact))
        case .array(let items): return .array(items.map { mask($0, exact: exact) })
        case .object(let fields):
            var masked: [String: JSONValue] = [:]
            for (key, field) in fields {
                if isSecretKey(key), case .string(let text) = field, !text.isEmpty {
                    masked[key] = .string(replacement)
                } else {
                    masked[key] = mask(field, exact: exact)
                }
            }
            // MCP headers: [{"name": "Authorization", "value": "…"}]
            if let name = fields["name"]?.stringValue, isSecretKey(name), case .string? = fields["value"] {
                masked["value"] = .string(replacement)
            }
            return .object(masked)
        default: return value
        }
    }

    static func mask(_ text: String, exact: Set<String>) -> String {
        var result = text
        for secret in exact where result.contains(secret) {
            result = result.replacingOccurrences(of: secret, with: replacement)
        }
        guard
            result.contains("sk-") || result.range(of: "bearer", options: .caseInsensitive) != nil
                || result.contains("eyJ")
        else { return result }
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }
}
