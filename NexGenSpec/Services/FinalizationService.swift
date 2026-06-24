//
//  FinalizationService.swift
//  NexGenSpec
//
//  Atomic finalization: immutable snapshot + SHA256 hash. Crash-safe.
//

import Foundation
import CryptoKit

/// Wrapper for persisted finalized version + hash. Written atomically.
struct FinalizedVersionSnapshot: Codable {
    var version: InspectionVersion
    var reportHash: String
    var finalizedAt: Date
}

enum FinalizationService {

    /// Writes immutable snapshot and returns report hash. Call after state machine allows finalize.
    /// Uses canonical JSON (sorted keys) for deterministic hash.
    static func writeSnapshot(_ version: InspectionVersion) throws -> String {
        let jobId = UUID(uuidString: version.inspection.inspectionId) ?? version.id
        try FileSecurity.ensureProtectedDirectory(FilePaths.versionsFolder(jobId: jobId))
        let snapshot = FinalizedVersionSnapshot(
            version: version,
            reportHash: "", // filled below
            finalizedAt: version.finalizedAt ?? Date()
        )
        let hexHash = try canonicalHash(snapshot.version)
        var snapshotWithHash = snapshot
        snapshotWithHash.reportHash = hexHash
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshotData = try encoder.encode(snapshotWithHash)
        let url = FilePaths.versionSnapshotFile(jobId: jobId, versionId: version.id)
        try FileSecurity.writeProtected(snapshotData, to: url)
        return hexHash
    }

    /// Loads report hash for a finalized version (e.g. for report footer).
    static func loadReportHash(jobId: UUID, versionId: UUID) -> String? {
        let url = FilePaths.versionSnapshotFile(jobId: jobId, versionId: versionId)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(FinalizedVersionSnapshot.self, from: data) else { return nil }
        return snapshot.reportHash
    }

    /// Canonical SHA-256 of a version — the SINGLE hashing path shared by sealing
    /// (writeSnapshot) and re-verification (verify), so the two can never drift
    /// and yield a false "tampered" result.
    static func canonicalHash(_ version: InspectionVersion) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(version)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    enum IntegrityResult { case verified, mismatch, unavailable }

    /// Re-checks a finalized version's live data against the hash sealed at
    /// finalization. Pre-build-23 the sealed hash was written + verified once,
    /// then only displayed — never re-checked — so altered bytes (a bad restore,
    /// partial write, or sync divergence) would show the original hash over
    /// changed data (audit H1). Uses canonicalHash on both sides → no false positive.
    static func verify(_ version: InspectionVersion) -> IntegrityResult {
        let jobId = UUID(uuidString: version.inspection.inspectionId) ?? version.id
        guard let sealed = loadReportHash(jobId: jobId, versionId: version.id), !sealed.isEmpty else {
            return .unavailable
        }
        guard let live = try? canonicalHash(version) else { return .unavailable }
        return live == sealed ? .verified : .mismatch
    }
}
