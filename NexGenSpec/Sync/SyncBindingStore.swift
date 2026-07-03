//
//  SyncBindingStore.swift
//  NexGenSpec
//
//  The local, Keychain-backed identity binding table (build 22, landmine 1).
//
//  CloudKit keys off the iCloud Apple ID; the local store keys off the Firebase
//  UID. These are DIFFERENT identity systems. This table is the explicit,
//  locally-persisted bridge: per Firebase UID it records which iCloud user
//  (an opaque hash of CKContainer.userRecordID — never the raw Apple ID) and
//  which CloudKit zone that UID is bound to, plus seeding state.
//
//  It mirrors the `AuthManager` fallback-email Keychain pattern: a generic
//  password item per UID (kSecAttrAccount = firebaseUID), accessible only
//  `AfterFirstUnlockThisDeviceOnly` so it is never in an unencrypted backup and
//  never migrates to another device. The LOCAL store path NEVER keys on the
//  Apple ID; this table is read only to decide whether sync may bind (and to
//  detect an Apple-ID change under a UID → refuse-and-isolate).
//  See docs/design/build-22-cloudkit-sync.md §2.
//

import Foundation
import Security

/// One device-local binding row, per Firebase UID. Codable so it round-trips as
/// the Keychain item's data blob. Additive `schemaVersion` for forward-compat.
public struct SyncBinding: Codable, Equatable {
    /// Local store key. Never changes meaning.
    public var firebaseUID: String
    /// Opaque hash of CKContainer.userRecordID — identifies the bound iCloud user
    /// WITHOUT storing the Apple ID. A mismatch on bind ⇒ refuse-and-isolate.
    public var cloudUserToken: String
    /// CloudKit custom zone bound to this UID (per-UID isolation within one iCloud).
    public var zoneName: String
    public var boundAt: Date
    /// Set once one-time seeding completes; nil means "not yet seeded" (idempotency).
    public var seededAt: Date?
    /// Per-zone CloudKit server change token (opaque), for incremental two-way pulls.
    public var changeToken: Data?
    public var schemaVersion: Int

    public init(
        firebaseUID: String,
        cloudUserToken: String,
        zoneName: String,
        boundAt: Date,
        seededAt: Date? = nil,
        changeToken: Data? = nil,
        schemaVersion: Int = 1
    ) {
        self.firebaseUID = firebaseUID
        self.cloudUserToken = cloudUserToken
        self.zoneName = zoneName
        self.boundAt = boundAt
        self.seededAt = seededAt
        self.changeToken = changeToken
        self.schemaVersion = schemaVersion
    }
}

public enum SyncBindingStore {

    /// Default Keychain service for binding rows, scoped per CloudKit environment.
    /// Debug builds sync against the Development environment and TestFlight/App
    /// Store builds against Production (fixed by code signing), but both read the
    /// same device Keychain — an unscoped shared row alternates its `changeToken`
    /// between the two environments' token spaces, and CloudKit answers the foreign
    /// token with `changeTokenExpired` = a full resync on every Debug↔TestFlight
    /// swap (dev machines only; T-01618). Scoping the service gives each
    /// environment its own row; a fresh row re-seeds idempotently, so no migration.
    /// Overridable (param) so tests use a unique service and never collide with the
    /// real store.
    public static let defaultService: String = {
        #if DEBUG
        return "com.nexgenspec.syncBinding.dev"
        #else
        return "com.nexgenspec.syncBinding.prod"
        #endif
    }()

    /// Pre-scoping service name (builds ≤28, both environments). Purged on the
    /// first scoped save so a stale shared row can't linger on dev machines.
    private static let legacyService = "com.nexgenspec.syncBinding"

    /// Reads the binding for a UID, or nil if none / undecodable.
    public static func load(forUID uid: String, service: String = defaultService) -> SyncBinding? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: uid,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let binding = try? JSONDecoder().decode(SyncBinding.self, from: data) else {
            return nil
        }
        return binding
    }

    /// Writes (or replaces) the binding for its UID. `AfterFirstUnlockThisDeviceOnly`
    /// so it never lands in a backup or migrates devices. Returns true on success.
    @discardableResult
    public static func save(_ binding: SyncBinding, service: String = defaultService) -> Bool {
        guard let data = try? JSONEncoder().encode(binding) else { return false }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: binding.firebaseUID
        ]
        // Delete-then-add so SecItemAdd can't fail with errSecDuplicateItem.
        SecItemDelete(baseQuery as CFDictionary)
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            Diagnostics.logError(context: "SyncBindingStore.save failed (\(status))", persistToDisk: false)
        }
        // One-time cleanup of the pre-scoping shared row (see `legacyService`).
        // Only when writing the real store — a test's injected service must never
        // reach outside its own namespace.
        if status == errSecSuccess && service == defaultService {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: binding.firebaseUID
            ]
            SecItemDelete(legacyQuery as CFDictionary)
        }
        return status == errSecSuccess
    }

    /// Removes the binding for a UID (e.g. account deletion). Ignores "not found".
    @discardableResult
    public static func delete(forUID uid: String, service: String = defaultService) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: uid
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
