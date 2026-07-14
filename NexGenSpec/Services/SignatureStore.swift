//
//  SignatureStore.swift
//  NexGenSpec
//
//  Signature images on disk. Model holds id; image loaded via this store.
//

import Foundation
import UIKit

enum SignatureStore {

    /// Writes the signature PNG to protected storage. Returns true only if the
    /// bytes actually reached disk. Callers MUST check this before recording an
    /// InspectionSignature model entry — a swallowed write left the finalized
    /// (legally-binding) report referencing a signature file that didn't exist,
    /// with the pad already locked so it couldn't be re-signed.
    @discardableResult
    static func saveImage(_ imageData: Data, jobId: UUID, signatureId: UUID) -> Bool {
        let url = FilePaths.signatureFile(jobId: jobId, signatureId: signatureId)
        do {
            try FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
            try FileSecurity.writeProtected(imageData, to: url)
            // Mirror the signature PNG to CloudKit (sync data completeness): the
            // synced model carries only the signature metadata + fileName, so
            // without these bytes a receiving device renders reports with the
            // signatures silently missing. Emitted only after a durable write.
            SyncCoordinator.noteMediaUpserted(
                jobId: jobId,
                relativePath: relativePath(jobId: jobId, signatureId: signatureId)
            )
            return true
        } catch {
            Diagnostics.logError(context: "Signature image save failed", error: error)
            return false
        }
    }

    /// Canonical root-relative path of a signature PNG — matches
    /// `FilePaths.signatureFile` and the `SyncAssetPaths` allowlist.
    static func relativePath(jobId: UUID, signatureId: UUID) -> String {
        "Inspections/\(jobId.uuidString)/signatures/\(signatureId.uuidString).png"
    }

    static func loadImageData(jobId: UUID, signatureId: UUID) -> Data? {
        let url = FilePaths.signatureFile(jobId: jobId, signatureId: signatureId)
        return try? Data(contentsOf: url)
    }
}
