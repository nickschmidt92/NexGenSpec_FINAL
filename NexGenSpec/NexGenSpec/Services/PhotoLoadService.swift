//
//  PhotoLoadService.swift
//  NexGenSpec
//
//  Async, off-main-thread photo and thumbnail loading. No main-thread disk I/O.
//

import Foundation
import UIKit

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
                if let data = try? Data(contentsOf: thumbURL), let img = UIImage(data: data) {
                    self.thumbCache.setObject(img, forKey: key, cost: self.imageCost(img))
                    continuation.resume(returning: img)
                    return
                }
                guard let fullData = try? Data(contentsOf: fullURL), let full = UIImage(data: fullData) else {
                    continuation.resume(returning: nil)
                    return
                }
                let thumb = self.resizedForThumbnail(full, maxSize: self.thumbMaxSize)
                if let jpeg = thumb.jpegData(compressionQuality: 0.8) {
                    try? FileManager.default.createDirectory(at: thumbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? jpeg.write(to: thumbURL)
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
                guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else {
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
            guard let data = try? Data(contentsOf: fullURL), let full = UIImage(data: data) else { return }
            let thumb = self.resizedForThumbnail(full, maxSize: self.thumbMaxSize)
            if let jpeg = thumb.jpegData(compressionQuality: 0.8) {
                try? FileManager.default.createDirectory(at: thumbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? jpeg.write(to: thumbURL)
            }
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
}
