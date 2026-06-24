//
//  SyncTeardownOwed.swift
//  NexGenSpec
//
//  Durable retry for account-deletion zone teardown (build 22 fix C / edge G,
//  5.1.1(v)). `SyncAccountTeardown` is one-shot best-effort: a transient
//  `deleteZone` failure — or iCloud being unavailable at the exact deletion moment —
//  leaves the deleted account's CloudKit zone (with payload CKAssets = client PII) as
//  a residual in the user's OWN private iCloud, with no retry, because the
//  deletion-pin recovery path can't re-fire (a normal completed deletion clears the
//  pin before the detached teardown runs).
//
//  This adds a persisted "teardown-owed" marker plus a cold-launch sweep that is
//  INDEPENDENT of the deletion pin: on a failed/unreachable teardown we record what is
//  owed, and at the next launch (under the owning iCloud account) the sweep retries
//  the zone delete. The marker is Keychain-backed (mirroring SyncBindingStore) so it
//  survives the app being killed and never lands in a backup. See
//  docs/design/build-22-p6-remediation.md (Round-3 — C teardown).
//
//  Internal access (like CloudDatabase / SyncAccountTeardown): used within the module
//  and reached from tests via `@testable import`.
//

import Foundation
import Security

/// What a prior account deletion still owes the user's private iCloud: the zone to
/// drop, plus the iCloud user that OWNS it (so the sweep never issues deleteZone
/// against the wrong/unknown DB after an account switch — finding #4). Keyed by
/// firebaseUID. The cloudUserToken is already an opaque hash (never the Apple ID).
struct SyncTeardownOwed: Codable, Equatable {
    let firebaseUID: String
    let zoneName: String
    let cloudUserToken: String
}

/// Persists outstanding teardown-owed markers. Real impl is Keychain-backed; tests
/// use an in-memory fake.
protocol TeardownOwedStoring: Sendable {
    /// Record (or replace) an owed teardown for its UID.
    func record(_ owed: SyncTeardownOwed)
    /// Every outstanding owed teardown (for the cold-launch sweep).
    func loadAll() -> [SyncTeardownOwed]
    /// Clear the owed marker for a UID once its zone is actually gone.
    func remove(forUID uid: String)
}

/// Keychain-backed owed store, mirroring `SyncBindingStore`: one generic-password
/// item per UID, `AfterFirstUnlockThisDeviceOnly` so it never lands in a backup or
/// migrates devices.
struct KeychainTeardownOwedStore: TeardownOwedStoring {

    static let defaultService = "com.nexgenspec.syncTeardownOwed"
    private let service: String

    init(service: String = KeychainTeardownOwedStore.defaultService) {
        self.service = service
    }

    func record(_ owed: SyncTeardownOwed) {
        guard let data = try? JSONEncoder().encode(owed) else {
            Diagnostics.logError(context: "KeychainTeardownOwedStore.record: encode failed; teardown-owed NOT persisted for \(owed.firebaseUID)", persistToDisk: false)
            return
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: owed.firebaseUID
        ]
        // Delete-then-add so SecItemAdd can't fail with errSecDuplicateItem.
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            Diagnostics.logError(context: "KeychainTeardownOwedStore.record failed (\(status))", persistToDisk: false)
        }
    }

    func loadAll() -> [SyncTeardownOwed] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnData as String: true
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess, let datas = items as? [Data] else { return [] }
        return datas.compactMap { try? JSONDecoder().decode(SyncTeardownOwed.self, from: $0) }
    }

    func remove(forUID uid: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: uid
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// The cold-launch sweep: retries zone teardowns a prior account deletion couldn't
/// complete. Pure/injectable (takes the database, account, and owed store) so it is
/// unit-testable with the in-memory fakes — no CloudKit at the call site.
enum SyncTeardownSweep {

    /// For each owed teardown, ONLY deleteZone when THIS device's current iCloud user
    /// still owns it (token match — finding #4, never hit the wrong DB); on success
    /// clear the owed marker, on failure/unreachable leave it for a later launch. A
    /// strict no-op when sync is disabled.
    static func run(
        database: CloudDatabase,
        account: CloudAccountProviding,
        owed: TeardownOwedStoring,
        isEnabled: Bool
    ) async {
        guard isEnabled else { return }
        let entries = owed.loadAll()
        guard !entries.isEmpty else { return }
        let currentToken = await account.currentUserToken()
        for entry in entries {
            // Not reachable from the current iCloud user (account changed / iCloud
            // unavailable) — leave it owed; a later launch under the right account
            // sweeps it. Never deleteZone against another/unknown DB.
            guard currentToken == entry.cloudUserToken else { continue }
            do {
                try await database.deleteZone(entry.zoneName)
                owed.remove(forUID: entry.firebaseUID)
            } catch {
                Diagnostics.logError(context: "SyncTeardownSweep: deleteZone retry failed for \(entry.firebaseUID); left owed", error: error)
            }
        }
    }
}
