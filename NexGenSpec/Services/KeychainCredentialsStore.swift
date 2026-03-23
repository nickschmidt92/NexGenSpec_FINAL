import Foundation
import Security
import CryptoKit

enum KeychainCredentialsStore {
    private static let service = "com.nexgenspec.credentials"
    private static let fallbackKey = "com.nexgenspec.credentials.fallback"

    static func save(username: String, password: String) -> Bool {
        guard !username.isEmpty, !password.isEmpty else { return false }
        let digest = SHA256.hash(data: Data(password.utf8))
        let digestData = Data(digest)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: digestData
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        let fallbackSaved = saveFallbackDigest(digestData, for: username)

        if status != errSecSuccess {
            Diagnostics.logError(context: "Failed to save credentials for account", error: KeychainError(status: status))
        }
        return status == errSecSuccess || fallbackSaved
    }

    static func verify(username: String, password: String) -> Bool {
        guard let stored = readDigest(username: username) ?? readFallbackDigest(username: username) else {
            return false
        }
        let candidate = Data(SHA256.hash(data: Data(password.utf8)))
        return stored == candidate
    }

    private static func readDigest(username: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func saveFallbackDigest(_ digest: Data, for username: String) -> Bool {
        var storedDigests = UserDefaults.standard.dictionary(forKey: fallbackKey) as? [String: String] ?? [:]
        storedDigests[username] = digest.base64EncodedString()
        UserDefaults.standard.set(storedDigests, forKey: fallbackKey)
        return true
    }

    private static func readFallbackDigest(username: String) -> Data? {
        guard
            let storedDigests = UserDefaults.standard.dictionary(forKey: fallbackKey) as? [String: String],
            let encoded = storedDigests[username]
        else {
            return nil
        }

        return Data(base64Encoded: encoded)
    }
}

private struct KeychainError: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error (\(status))"
    }
}
