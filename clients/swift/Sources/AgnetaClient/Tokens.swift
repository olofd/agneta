import Foundation
import Security

/// One store per app and Agneta endpoint. Errors are surfaced rather than silently discarding credentials.
@MainActor public protocol TokenStore: AnyObject, Sendable {
    func load() async throws -> String?
    func save(_ token: String) async throws
    func clear() async throws
}
@MainActor public final class MemoryTokenStore: TokenStore {
    private var token: String?
    public init(_ token: String? = nil) { self.token = token }
    public func load() -> String? { token }
    public func save(_ token: String) { self.token = token }
    public func clear() { token = nil }
}

/// Stores only pairing tokens, never provider credentials. Use your app's own service identifier.
/// Data Protection Keychain items are local to this device and never synchronised through iCloud.
@MainActor public final class KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String
    public init(service: String, account: String = "agneta-release") {
        self.service = service; self.account = account
    }
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false
        ]
    }
    public func load() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw AgnetaError(.keychain, "The saved Agneta token is not valid UTF-8.")
        }
        return token
    }
    public func save(_ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }
    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw AgnetaError(
                .keychain, (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)",
                code: Int(status))
        }
    }
}
