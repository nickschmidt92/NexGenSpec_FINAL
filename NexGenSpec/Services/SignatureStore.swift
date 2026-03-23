//
//  SignatureStore.swift
//  NexGenSpec
//
//  Signature images on disk. Model holds id; image loaded via this store.
//

import Foundation
import UIKit

enum SignatureStore {

    static func saveImage(_ imageData: Data, jobId: UUID, signatureId: UUID) {
        let url = FilePaths.signatureFile(jobId: jobId, signatureId: signatureId)
        try? FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
        try? FileSecurity.writeProtected(imageData, to: url)
    }

    static func loadImageData(jobId: UUID, signatureId: UUID) -> Data? {
        let url = FilePaths.signatureFile(jobId: jobId, signatureId: signatureId)
        return try? Data(contentsOf: url)
    }
}
