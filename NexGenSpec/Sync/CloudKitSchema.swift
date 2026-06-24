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
    static let schemaVersion = 1

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
    }

    /// Deterministic custom-zone name for a Firebase UID. One zone per UID gives
    /// per-account isolation WITHIN a single iCloud private DB (identity edge C:
    /// two app accounts on one iCloud never read each other's zone). The UID is
    /// hashed so it is not exposed verbatim as a zone name.
    static func zoneName(forFirebaseUID uid: String) -> String {
        "ngs-" + String(sha256Hex(uid).prefix(32))
    }

    /// Lowercase hex SHA-256 of a string. Used for zone names and the opaque
    /// cloud-user token (never reversible to the Apple ID / UID).
    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
