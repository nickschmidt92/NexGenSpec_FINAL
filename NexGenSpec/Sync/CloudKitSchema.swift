//
//  CloudKitSchema.swift
//  NexGenSpec
//
//  CloudKit schema v1 (build 22). Record types, field keys, and per-firebaseUID
//  zone naming. Additive-only: never rename/retype/remove a field; add new
//  optional fields and bump `schemaVersion`. Pure (no CloudKit import) so it is
//  unit-testable; the live port references these constants when building
//  CKRecords. See docs/design/build-22-cloudkit-sync.md §4.
//

import Foundation
import CryptoKit

enum CloudKitSchema {

    /// Matches the entitlement `com.apple.developer.icloud-container-identifiers`.
    static let containerIdentifier = "iCloud.com.nexgenspec.app"

    /// Bumped only for additive, forward-compatible schema changes.
    /// v2 (build 29): additive asset-sync fields (D-0203 — PDFs, thumbnails, LiDAR
    /// floor plans, scan records, CapturedRoom JSON).
    static let schemaVersion = 2

    enum RecordType {
        static let inspectionVersion = "InspectionVersion"
        static let reportPDF = "ReportPDF"
        static let mediaAsset = "MediaAsset"
        static let syncMeta = "SyncMeta"
    }

    /// The fixed recordName of the per-zone `SyncMeta` singleton that holds the
    /// deletion log (§8 tombstones). One per zone; read-modify-written under optimistic
    /// concurrency.
    static let syncMetaRecordName = "syncMeta"

    enum Field {
        static let inspectionId = "inspectionId"
        static let versionNumber = "versionNumber"
        static let status = "status"
        static let locked = "locked"
        static let finalizedAt = "finalizedAt"
        static let schemaVersion = "schemaVersion"
        static let modifiedAt = "modifiedAt"
        /// CKAsset carrying the encoded InspectionVersion JSON (the current.json
        /// bytes). All client PII lives here, inside the user's encrypted-at-rest
        /// private DB — never in a queryable metadata field.
        static let payload = "payload"
        /// SyncMeta deletion log: the list of deleted versionId strings (§8 tombstones)
        /// that stop a stale offline device from resurrecting a deleted draft.
        static let deletedIds = "deletedIds"

        // MARK: - Asset sync (D-0203, schema v2). All additive.
        /// String, queryable — the inspection folder UUID string an asset belongs to.
        static let assetJobId = "assetJobId"
        /// String, queryable — root-relative path (the asset's natural key).
        static let assetRelativePath = "assetRelativePath"
        /// String — one of `SyncAssetKind.rawValue`.
        static let assetKind = "assetKind"
        /// Date — the LWW clock (source file mtime at push time).
        static let assetModifiedAt = "assetModifiedAt"
        /// SyncMeta asset-deletion log: deleted asset keys ("<jobId>/<relativePath>").
        /// Independent of `deletedIds` so an asset-tombstone write that fails on a
        /// Prod schema still missing this field never breaks version-deletion sync.
        static let deletedAssets = "deletedAssets"
    }

    /// Deterministic custom-zone name for a Firebase UID. One zone per UID gives
    /// per-account isolation WITHIN a single iCloud private DB (identity edge C:
    /// two app accounts on one iCloud never read each other's zone). The UID is
    /// hashed so it is not exposed verbatim as a zone name.
    static func zoneName(forFirebaseUID uid: String) -> String {
        "ngs-" + String(sha256Hex(uid).prefix(32))
    }

    /// Stable CloudKit recordName for a synced asset. The (jobId, root-relative
    /// path) pair is the natural key; hashing keeps it opaque and length-bounded.
    /// The "asset-" prefix guarantees it never collides with a versionId.uuidString
    /// InspectionVersion recordName. Idempotent: a re-push (thumbnail regen, PDF
    /// re-export, scan rename) overwrites the SAME record.
    static func assetRecordName(jobId: UUID, relativePath: String) -> String {
        "asset-" + String(sha256Hex("\(jobId.uuidString)|\(relativePath)").prefix(40))
    }

    /// The record type carrying a given asset kind. `reportPDF` gets its own type
    /// (dashboard legibility); every other synced asset shares `MediaAsset`. Both
    /// types carry an identical field set, so push/pull is one parameterized path.
    static func recordType(forAssetKind kind: String) -> String {
        kind == SyncAssetKind.reportPDF.rawValue ? RecordType.reportPDF : RecordType.mediaAsset
    }

    /// Lowercase hex SHA-256 of a string. Used for zone names and the opaque
    /// cloud-user token (never reversible to the Apple ID / UID).
    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
