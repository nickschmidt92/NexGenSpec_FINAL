//
//  PhotoLoadService.swift
//  NexGenSpec
//
//  Async, off-main-thread photo and thumbnail loading. No main-thread disk I/O.
//

import Foundation
import UIKit
import ImageIO
import PencilKit

extension Notification.Name {
    /// Posted when an annotated thumbnail is regenerated. `userInfo` contains "photoId" (UUID).
    static let thumbnailDidUpdate = Notification.Name("com.nexgenspec.thumbnailDidUpdate")
}

/// Loads photos from disk on a background queue. Use for UI to avoid freezing with 300+ images.
/// In-memory thumbnail cache (bounded) to avoid re-decoding when scrolling back.
public final class PhotoLoadService: @unchecked Sendable {

    public static let shared = PhotoLoadService()

    private let queue = DispatchQueue(label: "com.nexgenspec.photoLoad", qos: .userInitiated)
    private let thumbMaxSize: CGFloat = 200
    private let thumbCache = NSCache<NSString, UIImage>()
    private let thumbCacheCostLimit = 80 * 1024 * 1024 // ~80 MB

    public init() {
        thumbCache.totalCostLimit = thumbCacheCostLimit
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.thumbCache.removeAllObjects()
        }
    }

    /// Loads a thumbnail (memory cache → disk cache or full). Call from View; result delivered on MainActor.
    public func loadThumbnail(jobId: UUID, photo: InspectionPhoto) async -> UIImage? {
        let cacheKeyString = "\(jobId.uuidString)-\(photo.id.uuidString)"
        let cacheKey = cacheKeyString as NSString
        if let cached = thumbCache.object(forKey: cacheKey) {
            return cached
        }
        let photoFileName = photo.fileName
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else { continuation.resume(returning: nil); return }
                let key = cacheKeyString as NSString
                if let cached = self.thumbCache.object(forKey: key) {
                    continuation.resume(returning: cached)
                    return
                }
                let thumbURL = FilePaths.thumbnailsFolder(jobId: jobId).appendingPathComponent(photoFileName)
                let fullURL = FilePaths.photosFolder(jobId: jobId).appendingPathComponent(photoFileName)
                if let img = Self.decodeImageFromURL(thumbURL, maxPixelSize: Int(self.thumbMaxSize * 2)) {
                    self.thumbCache.setObject(img, forKey: key, cost: self.imageCost(img))
                    continuation.resume(returning: img)
                    return
                }
                guard let full = Self.decodeImageFromURL(fullURL, maxPixelSize: 2048) else {
                    continuation.resume(returning: nil)
                    return
                }
                let thumb = self.resizedForThumbnail(full, maxSize: self.thumbMaxSize)
                if let jpeg = thumb.jpegData(compressionQuality: 0.8) {
                    try? FileSecurity.ensureProtectedDirectory(thumbURL.deletingLastPathComponent())
                    if (try? FileSecurity.writeProtected(jpeg, to: thumbURL, options: [.atomic])) != nil {
                        // Mirror the thumbnail to CloudKit (D-0203). The on-disk name is
                        // photo.fileName (a "<uuid>.jpg"), so use it verbatim.
                        SyncCoordinator.noteMediaUpserted(
                            jobId: jobId,
                            relativePath: "Inspections/\(jobId.uuidString)/thumbnails/\(photoFileName)")
                    }
                }
                self.thumbCache.setObject(thumb, forKey: key, cost: self.imageCost(thumb))
                continuation.resume(returning: thumb)
            }
        }
    }

    private func imageCost(_ image: UIImage) -> Int {
        let scale = image.scale
        let size = image.size
        return Int(size.width * scale * size.height * scale * 4)
    }

    /// Loads full-size image for annotation or export. Off main thread.
    public func loadFullImage(jobId: UUID, photo: InspectionPhoto) async -> UIImage? {
        let photoFileName = photo.fileName
        return await withCheckedContinuation { continuation in
            queue.async {
                let url = FilePaths.photosFolder(jobId: jobId).appendingPathComponent(photoFileName)
                guard let img = Self.decodeImageFromURL(url, maxPixelSize: 4096) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: img)
            }
        }
    }

    /// Generates thumbnail on background after saving a new photo. Call after savePhoto.
    public func generateThumbnailIfNeeded(jobId: UUID, fileName: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let thumbURL = FilePaths.thumbnailsFolder(jobId: jobId).appendingPathComponent(fileName)
            if (try? thumbURL.checkResourceIsReachable()) == true { return }
            let fullURL = FilePaths.photosFolder(jobId: jobId).appendingPathComponent(fileName)
            guard let full = Self.decodeImageFromURL(fullURL, maxPixelSize: 2048) else { return }
            let thumb = self.resizedForThumbnail(full, maxSize: self.thumbMaxSize)
            if let jpeg = thumb.jpegData(compressionQuality: 0.8) {
                try? FileSecurity.ensureProtectedDirectory(thumbURL.deletingLastPathComponent())
                if (try? FileSecurity.writeProtected(jpeg, to: thumbURL, options: [.atomic])) != nil {
                    // Mirror the thumbnail to CloudKit (D-0203); on-disk name is fileName.
                    SyncCoordinator.noteMediaUpserted(
                        jobId: jobId,
                        relativePath: "Inspections/\(jobId.uuidString)/thumbnails/\(fileName)")
                }
            }
        }
    }

    /// Regenerates the thumbnail for a photo with annotations composited on top.
    /// Call after saving annotations so thumbnails reflect the current markup.
    public func regenerateAnnotatedThumbnail(jobId: UUID, photo: InspectionPhoto) {
        let photoFileName = photo.fileName
        let photoId = photo.id
        let cacheKey = "\(jobId.uuidString)-\(photoId.uuidString)" as NSString
        queue.async { [weak self] in
            guard let self = self else { return }
            let fullURL = FilePaths.photosFolder(jobId: jobId).appendingPathComponent(photoFileName)
            guard let fullImage = Self.decodeImageFromURL(fullURL, maxPixelSize: 2048) else { return }

            // Composite annotations onto the full image, then resize to thumbnail
            let imageToThumbnail: UIImage
            if let overlay = AnnotationStore.load(jobId: jobId, photoId: photoId) {
                imageToThumbnail = Self.compositeOverlay(overlay, onto: fullImage)
            } else {
                imageToThumbnail = fullImage
            }

            let thumb = self.resizedForThumbnail(imageToThumbnail, maxSize: self.thumbMaxSize)
            let thumbURL = FilePaths.thumbnailsFolder(jobId: jobId).appendingPathComponent(photoFileName)
            if let jpeg = thumb.jpegData(compressionQuality: 0.8) {
                try? FileSecurity.ensureProtectedDirectory(thumbURL.deletingLastPathComponent())
                if (try? FileSecurity.writeProtected(jpeg, to: thumbURL, options: [.atomic])) != nil {
                    // Mirror the regenerated (annotated) thumbnail to CloudKit (D-0203);
                    // re-upserts the same recordName, overwriting the prior copy.
                    SyncCoordinator.noteMediaUpserted(
                        jobId: jobId,
                        relativePath: "Inspections/\(jobId.uuidString)/thumbnails/\(photoFileName)")
                }
            }
            self.thumbCache.setObject(thumb, forKey: cacheKey, cost: self.imageCost(thumb))
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .thumbnailDidUpdate, object: nil, userInfo: ["photoId": photoId])
            }
        }
    }

    /// Composites an AnnotationOverlay onto a base image for the thumbnail.
    /// Uses AnnotationBakeService's shared letterbox-aware transform so the
    /// thumbnail bakes identically to the exported PDF — previously this
    /// duplicated the buggy separate-scaleX/scaleY math that squashed circles
    /// into ellipses and offset every mark (B-0071).
    private static func compositeOverlay(_ overlay: AnnotationOverlay, onto image: UIImage) -> UIImage {
        let t = AnnotationBakeService.overlayTransform(overlay: overlay, imageSize: image.size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { context in
            image.draw(at: .zero)
            let cg = context.cgContext
            if let data = overlay.drawingData, let drawing = try? PKDrawing(data: data) {
                cg.saveGState()
                cg.scaleBy(x: t.scale, y: t.scale)
                cg.translateBy(x: -t.offsetX, y: -t.offsetY)
                drawing.image(from: drawing.bounds, scale: 1).draw(at: drawing.bounds.origin)
                cg.restoreGState()
            }
            for arrow in overlay.arrows {
                let color = Self.annotationColor(name: arrow.colorName)
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(t.lineWidth)
                cg.beginPath()
                cg.move(to: t.point(arrow.startX, arrow.startY))
                cg.addLine(to: t.point(arrow.endX, arrow.endY))
                cg.strokePath()
            }
            for circle in overlay.circles {
                let color = Self.annotationColor(name: circle.colorName)
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(t.lineWidth)
                let c = t.point(circle.centerX, circle.centerY)
                let r = CGFloat(circle.radius) * t.scale
                cg.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
        }
    }

    private static func annotationColor(name: String) -> UIColor {
        switch name {
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        default: return .systemRed
        }
    }

    private func resizedForThumbnail(_ image: UIImage, maxSize: CGFloat) -> UIImage {
        let size = image.size
        let ratio = min(maxSize / size.width, maxSize / size.height, 1)
        guard ratio < 1 else { return image }
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Decodes an image from a file URL without loading the full file into memory.
    /// Uses CGImageSourceCreateWithURL to stream directly from disk, avoiding
    /// the memory spike of Data(contentsOf:) on 48MP+ ProRAW photos (~100MB).
    private static func decodeImageFromURL(_ url: URL, maxPixelSize: Int) -> UIImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
