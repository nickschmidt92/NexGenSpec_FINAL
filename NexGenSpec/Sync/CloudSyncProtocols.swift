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
    /// Upsert one inspection-version record into the zone. When `ifAbsent` is true
    /// (a finalized/locked version) the save must NEVER overwrite an existing
    /// record — finalized reports are immutable (§8).
    func save(_ record: InspectionVersionRecord, inZone zoneName: String, ifAbsent: Bool) async throws
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
        let url = FilePaths.currentVersionFile(jobId: id)
        // Legitimate absence (e.g. a just-deleted version) is a silent nil; a real
        // read failure (I/O, data-protection) is logged so it can't masquerade as
        // absence (review finding: swallowed errors).
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            Diagnostics.logError(context: "DiskVersionReader.versionData read failed for \(id)", error: error)
            return nil
        }
    }

    func allLocalVersions() -> [LocalVersionSnapshot] {
        let root = FilePaths.appRoot.appendingPathComponent("Inspections", isDirectory: true)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        // No Inspections directory yet = clean install, not an error.
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            Diagnostics.logError(context: "DiskVersionReader.allLocalVersions: could not enumerate Inspections")
            return []
        }
        var snapshots: [LocalVersionSnapshot] = []
        for folder in entries {
            let current = folder.appendingPathComponent("current.json", isDirectory: false)
            guard fm.fileExists(atPath: current.path) else { continue }
            do {
                let data = try Data(contentsOf: current)
                let version = try JSONDecoder().decode(InspectionVersion.self, from: data)
                snapshots.append(LocalVersionSnapshot(meta: VersionMetadata(from: version), payload: data))
            } catch {
                // A current.json that exists but won't read/decode is a real problem
                // — it would be silently dropped from the seed otherwise.
                Diagnostics.logError(context: "DiskVersionReader.allLocalVersions read/decode failed for \(folder.lastPathComponent)", error: error)
            }
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
