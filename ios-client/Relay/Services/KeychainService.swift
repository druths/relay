import Foundation
import Security

enum KeychainService {
    private static let service = "com.relay.token"
    private static let account = "jwt"

    // On Mac Catalyst the Keychain API defaults to the file-based
    // macOS keychain, which stores items separately from the iOS
    // data-protection keychain, honors a different accessibility
    // vocabulary, and may require user approval. Setting
    // `kSecUseDataProtectionKeychain` forces the iOS-style keychain
    // on every platform, so Catalyst behaves like iOS.
    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func save(token: String) throws {
        guard let data = token.data(using: .utf8) else { return }

        // Delete existing item first
        delete()

        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            print("[Keychain] save token failed: OSStatus=\(status)")
            throw KeychainError.saveFailed(status)
        }
    }

    static func load() -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("[Keychain] load token failed: OSStatus=\(status)")
        }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query = baseQuery(service: service, account: account)
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Keyed credential storage (for saved accounts)

    private static let accountsService = "com.relay.accounts"

    static func savePassword(_ password: String, forKey key: String) throws {
        guard let data = password.data(using: .utf8) else { return }
        deletePassword(forKey: key)
        var query = baseQuery(service: accountsService, account: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            print("[Keychain] savePassword failed: OSStatus=\(status) key=\(key)")
            throw KeychainError.saveFailed(status)
        }
    }

    static func loadPassword(forKey key: String) -> String? {
        var query = baseQuery(service: accountsService, account: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(forKey key: String) {
        let query = baseQuery(service: accountsService, account: key)
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: Error {
        case saveFailed(OSStatus)
    }
}
