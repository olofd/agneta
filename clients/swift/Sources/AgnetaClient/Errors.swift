import Foundation

/// Transport and RPC failures share one typed error; the original code, data and method stay available.
public struct AgnetaError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case notRunning, refused, networkBlocked, connectionClosed, timeout, protocolViolation
        case needsSignIn, rateLimited, needsPairing, notAllowed, noTurnRunning, turnBusy, queueFull, paused,
            unsupportedByEngine
        case engineDownloading, appLimit, methodNotFound, unenforceable, engineRefused, accessChanged, stateChanged
        case invalidParams, internalError, rpc, keychain, notInstalled, outdated, declined
        case unsupportedByAgneta, bufferOverflow
    }
    public let kind: Kind
    public let message: String
    public let code: Int?
    public let data: JSONValue?
    public let method: String?

    public init(_ kind: Kind, _ message: String, code: Int? = nil, data: JSONValue? = nil, method: String? = nil) {
        self.kind = kind; self.message = message; self.code = code; self.data = data; self.method = method
    }
    public var errorDescription: String? { message }
    public var agneta: JSONValue? { data?["agneta"] }
    public var account: String? {
        agneta?["needsSignIn"]?.string ?? agneta?["rateLimited"]?["account"]?.string ?? agneta?["paused"]?.string
            ?? agneta?["account"]?.string
    }
    public var download: DownloadProgress? { agneta?["engineDownloading"].flatMap { try? $0.decode() } }
    public var fields: [String] { agneta?["unenforceable"]?.array?.compactMap(\.string) ?? [] }
    public var structured: StructuredResult? { agneta?["result"].flatMap { try? StructuredResult(raw: $0) } }
    public var reason: String? { agneta?["reason"]?.string }
    public var resetsAt: String? {
        agneta?["rateLimited"]?["resetsAt"]?.string ?? agneta?["resetsAt"]?.string
            ?? agneta?["appLimit"]?["resetsAt"]?.string
    }

    public static func rpc(code: Int, message: String, data: JSONValue? = nil, method: String? = nil) -> Self {
        let details = data?["agneta"]
        let kind: Kind
        if details?["needsSignIn"]?.string != nil {
            kind = .needsSignIn
        } else if details?["rateLimited"]?.object != nil {
            kind = .rateLimited
        } else {
            switch code {
            case -32001: kind = .needsPairing
            case -32002: kind = .notAllowed
            case -32010: kind = .noTurnRunning
            case -32011: kind = .turnBusy
            case -32012: kind = .queueFull
            case -32013: kind = .paused
            case -32014: kind = .unsupportedByEngine
            case -32015: kind = .engineDownloading
            case -32016: kind = .appLimit
            case -32601: kind = .methodNotFound
            case -32602:
                if details?["unenforceable"] != nil {
                    kind = .unenforceable
                } else if details?["access"] != nil {
                    kind = .engineRefused
                } else if details?["accessChanged"]?.bool == true {
                    kind = .accessChanged
                } else if details?["stateChanged"]?.object != nil {
                    kind = .stateChanged
                } else {
                    kind = .invalidParams
                }
            case -32603: kind = .internalError
            default: kind = .rpc
            }
        }
        return Self(kind, message, code: code, data: data, method: method)
    }
}
