//
//  CoverPhotoSupport.swift
//  NexGenSpec
//
//  Shared helpers for cover-photo handling: an aspect-preserving image
//  resize + a notification name the dashboard observes so its in-memory
//  thumbnail cache invalidates when an inspection's cover changes.
//

import Foundation
import UIKit

extension UIImage {

    /// Returns a copy of this image scaled so that the longer side equals
    /// `maxSide` points (using the receiver's `scale`). If the image is
    /// already smaller in both dimensions, the original is returned
    /// unchanged.
    ///
    /// Uses `UIGraphicsImageRenderer` so the output preserves the same
    /// scale and respects orientation. Designed for one-shot downscale
    /// before JPEG encoding — not for live UI updates.
    func resizedKeepingAspect(maxSide: CGFloat) -> UIImage {
        let width = size.width
        let height = size.height
        let longest = max(width, height)
        guard longest > maxSide, longest > 0 else { return self }

        let ratio = maxSide / longest
        let newSize = CGSize(width: floor(width * ratio),
                             height: floor(height * ratio))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

extension Notification.Name {
    /// Posted whenever an inspection's cover photo file is written or
    /// removed. `userInfo["jobId"]` is the inspection's UUID. Listeners
    /// (e.g. the dashboard thumbnail cache) should drop any cached
    /// image for that jobId and re-render. Also posted when a SYNCED-IN
    /// cover photo lands on disk (InspectionStoreVersionWriter), so the
    /// receiver's placeholder resolves without a relaunch.
    static let coverPhotoDidUpdate = Notification.Name("NexGenSpec.coverPhotoDidUpdate")
}

/// CloudKit-mirror emits for the cover photo (sync data completeness pass).
/// One place derives the canonical root-relative path, so the write-site emit,
/// the removal emit, and the `SyncAssetPaths` allowlist can never drift.
enum CoverPhotoSync {

    static func relativePath(jobId: UUID, fileName: String) -> String {
        "Inspections/\(jobId.uuidString)/\(fileName)"
    }

    /// Call after the cover JPEG's bytes have durably reached disk.
    static func noteCoverWritten(jobId: UUID, fileName: String) {
        SyncCoordinator.noteMediaUpserted(jobId: jobId, relativePath: relativePath(jobId: jobId, fileName: fileName))
    }

    /// Call after the cover file was removed locally, so other devices'
    /// mirrored copies are tombstoned rather than resurrecting on pull.
    static func noteCoverRemoved(jobId: UUID, fileName: String) {
        SyncCoordinator.noteMediaDeleted(jobId: jobId, relativePath: relativePath(jobId: jobId, fileName: fileName))
    }
}
