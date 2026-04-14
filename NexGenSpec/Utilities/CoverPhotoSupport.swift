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
    /// image for that jobId and re-render.
    static let coverPhotoDidUpdate = Notification.Name("NexGenSpec.coverPhotoDidUpdate")
}
