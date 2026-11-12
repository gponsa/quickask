import Foundation
import Security

/// Stores the Anthropic API key in the macOS Keychain (login keychain).
/// The key is never written to a file, UserDefaults or logs.
enum Keychain {
    private static let service = "com.guillem.quickask"
    private static let account = "anthropic-api-key"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func apiKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    /// Saves (or replaces) the key. Passing an empty string deletes it.
    @discardableResult
    static func setAPIKey(_ key: String) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var item = baseQuery
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
