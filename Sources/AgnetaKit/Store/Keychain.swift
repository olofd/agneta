// API keys live in Agneta's Keychain items (service = bundle ID). They reach
// an engine only as environment variables at start; never files, logs or arguments.
import Foundation
import Security

public struct Keychain: Sendable {
    public let service: String
    public init(service: String) { self.service = service }

    public func set(_ secret: String, for account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }

    /// Removes every item under this service (Reset Agneta). Returns the Security status.
    @discardableResult
    public func deleteAll() -> OSStatus {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        var status = SecItemDelete(query as CFDictionary)
        // SecItemDelete can stop after one match in the file-based keychain; repeat until none is left.
        while status == errSecSuccess { status = SecItemDelete(query as CFDictionary) }
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}
