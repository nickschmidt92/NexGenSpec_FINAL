//
//  InspectionVersionRecord.swift
//  NexGenSpec
//
//  The CloudKit-bound projection of one inspection version, plus the mapper from
//  the local model. A pure value type so the mapping is unit-testable without
//  CloudKit; the live port (slice 2b) turns this into a CKRecord — queryable
//  metadata fields + a CKAsset for `payload`. Client PII lives ONLY in `payload`
//  (encrypted at rest in the user's private DB), never in a queryable field.
//  See docs/design/build-22-cloudkit-sync.md §4.
//

import Foundation

struct InspectionVersionRecord: Equatable {
    /// = versionId.uuidString. Stable record name ⇒ re-pushes are idempotent and
    /// a finalized (locked) record is addressable for the immutability check.
    let recordName: String
    let inspectionId: String
    let versionNumber: Int
    /// `VersionStatus.rawValue` ("Draft" / "Final").
    let status: String
    /// True ⇒ finalized/immutable: the live port never overwrites a locked record.
    let locked: Bool
    let finalizedAt: Date?
    let schemaVersion: Int
    /// Last local-edit time (LWW clock, build 22 slice 4c). Pushed to the record's
    /// queryable `modifiedAt` field so a pull can arbitrate draft conflicts by edit
    /// time without downloading the payload. Optional: nil for legacy versions.
    let updatedAt: Date?
    /// Encoded InspectionVersion JSON (the current.json bytes). Becomes a CKAsset.
    let payload: Data
}

enum InspectionRecordMapper {

    /// Builds the record projection from the lightweight metadata + the version's
    /// JSON payload. Deliberately copies only non-PII metadata into queryable
    /// fields (versionNumber/status/locked/finalizedAt/schemaVersion); client
    /// name, address, and all inspection content stay inside `payload`.
    static func make(
        meta: VersionMetadata,
        payload: Data,
        schemaVersion: Int = CloudKitSchema.schemaVersion
    ) -> InspectionVersionRecord {
        InspectionVersionRecord(
            recordName: meta.id.uuidString,
            inspectionId: meta.inspectionId.uuidString,
            versionNumber: meta.versionNumber,
            status: meta.status.rawValue,
            locked: meta.locked,
            finalizedAt: meta.finalizedAt,
            schemaVersion: schemaVersion,
            updatedAt: meta.updatedAt,
            payload: payload
        )
    }
}
