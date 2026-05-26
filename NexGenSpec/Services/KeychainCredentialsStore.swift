import Foundation
import Security
import CryptoKit

/// Stores a SHA-256 digest of the user's password in the Keychain only.
///
/// There is deliberately no UserDefaults (or any other device-readable)
/// fallback: a plist-backed credential digest is exposed in device backups
/// and is not protected by the Secure Enclave / Data Protection class the way
/// a Keychain item is. If the Keychain write or read fails, the correct
/// recovery is full re-authentication against Firebase — callers must treat a
/// `false` from `save`/`verify` as "credential unavailable", never as a cue to
/// consult a softer store.
enum KeychainCredentialsStore {
    private static let service = "com.nexgenspec.credentials"

    /// Persists the password digest in the Keychain. Returns `true` only when
    /// the Keychain write succeeds; on failure the caller should require
    /// re-authentication rather than persisting the credential anywhere else.
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
        if status != errSecSuccess {
            Diagnostics.logError(context: "Failed to save credentials for account", error: KeychainError(status: status))
        }
        return status == errSecSuccess
    }

    /// Verifies a password against the Keychain-stored digest. Returns `false`
    /// when nothing is stored or the Keychain read fails — the caller resolves
    /// that by re-authenticating, not by trusting a fallback copy.
    static func verify(username: String, password: String) -> Bool {
        guard let stored = readDigest(username: username) else {
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
}

private struct KeychainError: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error (\(status))"
    }
}
