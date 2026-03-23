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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot.version)
        let hash = SHA256.hash(data: data)
        let hexHash = hash.map { String(format: "%02x", $0) }.joined()
        var snapshotWithHash = snapshot
        snapshotWithHash.reportHash = hexHash
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
}
