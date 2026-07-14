//
//  SyncAssetRecord.swift
//  NexGenSpec
//
//  Pure (no CloudKit import) transport model + path classifier for D-0203 asset
//  sync (build 29): report PDFs, thumbnails, LiDAR floor-plan PNGs, LiDAR scan
//  records, and CapturedRoom JSON mirror to the user's private CloudKit zone —
//  plus (sync data completeness pass) cover photos, signature PNGs, and the
//  per-inspection side-state document (invoice/archived).
//  Full-res photos/videos, USDZ 3D scans, and the derived whole-home cache are
//  deliberately EXCLUDED. Kept CloudKit-free so the classifier + record shape are
//  unit-testable and the push/pull code has one place to derive an asset's kind.
//

import Foundation

/// Classifies a synced asset. `rawValue` is persisted in the CloudKit `assetKind`
/// field; additive only (never rename/remove a case).
enum SyncAssetKind: String {
    case reportPDF
    case thumbnail
    case lidarFloorplan
    case lidarScan
    case lidarRoom
    /// The inspection's cover photo (`Inspections/<id>/cover.jpg`) — small (downscaled
    /// to 1600pt + JPEG-compressed at the write site), so unlike full-res `photos/`
    /// it is cheap enough to mirror; without it a receiver renders a permanent
    /// loading spinner because the synced model references a file that never arrives.
    case coverPhoto
    /// Signature PNGs (`Inspections/<id>/signatures/<sigId>.png`). The synced model
    /// carries only the signature METADATA (name/date/fileName); the strokes image
    /// must ride along or a receiver's report silently omits the signatures.
    case signature
    /// The per-inspection side-state document (`Inspections/<id>/sidestate.json`):
    /// invoice amounts/sent/paid + archivedAt. See `InspectionSideStateStore`.
    case sideState
}

/// Transport projection of one synced asset (mirrors `InspectionVersionRecord`).
/// Carries identifiers + payload bytes; CloudKit-free so it is unit-testable.
struct SyncAssetRecord {
    let recordName: String
    let jobId: UUID
    let relativePath: String   // root-relative
    let kind: SyncAssetKind
    // LWW clock. On PUSH it carries the source-file mtime; on PULL the receiver fills
    // it from CloudKit's SERVER modificationDate so last-writer-wins arbitrates on one
    // authoritative clock instead of a skewed cross-device client mtime (D-0203 review).
    let modifiedAt: Date
    let schemaVersion: Int
    let payload: Data
}

enum SyncAssetPaths {
    /// The kind of a root-relative path IFF it is an ALLOWED synced asset, else nil.
    /// Defense-in-depth: used on push to derive the kind AND on pull to reject
    /// foreign/excluded/traversal paths before writing to disk. Excludes `photos/`,
    /// `videos/`, USDZ, and `whole_home_*.png`; rejects "..", absolute, and empty
    /// paths.
    static func kind(forRelativePath path: String) -> SyncAssetKind? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else { return nil }
        let lower = path.lowercased()
        if lower.hasPrefix("reports/") && lower.hasSuffix(".pdf") { return .reportPDF }
        if path.hasPrefix("Inspections/") {
            let components = path.split(separator: "/")
            // Cover photo + side state live at the inspection folder ROOT with FIXED
            // names ("Inspections/<id>/cover.jpg|sidestate.json"), so require exactly
            // 3 components — a "cover.jpg" nested anywhere else stays excluded.
            if components.count == 3 {
                if components[2] == FilePaths.defaultCoverPhotoFileName { return .coverPhoto }
                if components[2] == FilePaths.sideStateFileName { return .sideState }
            }
            if path.contains("/signatures/") && lower.hasSuffix(".png") { return .signature }
            if path.contains("/thumbnails/") && lower.hasSuffix(".jpg") { return .thumbnail }
            if path.contains("/lidar/") {
                let name = (path as NSString).lastPathComponent
                if name.hasSuffix("_floorplan.png") { return .lidarFloorplan }
                if name.hasSuffix("_room.json") { return .lidarRoom }
                if lower.hasSuffix(".usdz") { return nil }            // USDZ excluded
                if name.hasPrefix("whole_home_") { return nil }       // derived cache excluded
                if name.hasSuffix(".png") { return nil }              // any other png (guard)
                if lower.hasSuffix(".json") { return .lidarScan }     // <scanId>.json
            }
        }
        return nil   // photos/, videos/, anything else → not synced
    }
}
