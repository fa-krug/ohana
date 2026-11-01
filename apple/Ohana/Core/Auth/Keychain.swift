import Foundation
import Security

/// The device's API token, in the Keychain (never synced: each device pairs on its own).
/// Uses the data protection keychain; an unsigned development build of the Mac app has no
/// entitlement for it, and falls back to the login keychain. Also compiled into the Notification
/// Service Extension, which reads the push key (`PushKey`).
nonisolated enum Keychain {
    private static let service = "de.fa-krug.Ohana"

    static func save(_ value: String, for account: String) {
        delete(account)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if SecItemAdd(query as CFDictionary, nil) == errSecMissingEntitlement {
            query[kSecUseDataProtectionKeychain as String] = false
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func load(_ account: String) -> String? {
        load(account, dataProtection: true) ?? load(account, dataProtection: false)
    }

    private static func load(_ account: String, dataProtection: Bool) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: dataProtection,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        for dataProtection in [true, false] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: dataProtection,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
