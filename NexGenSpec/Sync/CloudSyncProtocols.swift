//
//  CloudSyncProtocols.swift
//  NexGenSpec
//
//  The injected seams the CloudKitSyncPort talks to (build 22, slice 2b). All
//  CloudKit access is behind these protocols so the port is unit-testable with
//  fakes and the port itself carries NO compile-time CloudKit dependency — only
//  the concrete backends (slice 2c) import CloudKit.
//

import Foundation

/// Push-only CloudKit operations the mirror needs.
protocol CloudDatabase: Sendable {
    /// Idempotently ensure the per-UID custom zone exists.
    func ensureZone(_ zoneName: String) async throws
    /// Upsert one inspection-version record into the zone.
    func save(_ record: InspectionVersionRecord, inZone zoneName: String) async throws
    /// Delete a record by name from the zone.
    func delete(recordName: String, inZone zoneName: String) async throws
}

/// Resolves the current iCloud user as an opaque token (nil ⇒ no iCloud account).
protocol CloudAccountProviding: Sendable {
    func currentUserToken() async -> String?
}

/// One local inspection version for seeding: its queryable metadata + the raw
/// `current.json` payload bytes.
struct LocalVersionSnapshot {
    let meta: VersionMetadata
    let payload: Data
}

/// Reads on-disk version payloads for mirroring. The local store stays the source
/// of truth; the mirror only ever reads from it.
protocol LocalVersionReader: Sendable {
    /// The `current.json` bytes for one version.
    func versionData(forVersionId id: UUID) -> Data?
    /// Every local inspection version, for one-time seeding (slice 3).
    func allLocalVersions() -> [LocalVersionSnapshot]
}

/// Default reader: the per-UID local store on disk.
struct DiskVersionReader: LocalVersionReader {
    func versionData(forVersionId id: UUID) -> Data? {
        try? Data(contentsOf: FilePaths.currentVersionFile(jobId: id))
    }

    func allLocalVersions() -> [LocalVersionSnapshot] {
        let root = FilePaths.appRoot.appendingPathComponent("Inspections", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var snapshots: [LocalVersionSnapshot] = []
        for folder in entries {
            let current = folder.appendingPathComponent("current.json", isDirectory: false)
            guard let data = try? Data(contentsOf: current),
                  let version = try? JSONDecoder().decode(InspectionVersion.self, from: data) else { continue }
            snapshots.append(LocalVersionSnapshot(meta: VersionMetadata(from: version), payload: data))
        }
        return snapshots
    }
}

/// Persists the identity binding. Real impl is the Keychain store; tests use an
/// in-memory fake.
protocol BindingStoring: Sendable {
    func load(forUID uid: String) -> SyncBinding?
    @discardableResult func save(_ binding: SyncBinding) -> Bool
    @discardableResult func delete(forUID uid: String) -> Bool
}

/// Default binding store: the Keychain-backed `SyncBindingStore`.
struct KeychainBindingStore: BindingStoring {
    func load(forUID uid: String) -> SyncBinding? { SyncBindingStore.load(forUID: uid) }
    @discardableResult func save(_ binding: SyncBinding) -> Bool { SyncBindingStore.save(binding) }
    @discardableResult func delete(forUID uid: String) -> Bool { SyncBindingStore.delete(forUID: uid) }
}
