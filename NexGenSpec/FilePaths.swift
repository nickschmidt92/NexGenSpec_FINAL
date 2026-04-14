//
//  FilePaths.swift
//  NexGenSpec
//

import Foundation

enum FilePaths {

    static var documentDirectory: URL {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            // Fallback to temp directory — should never happen on iOS but avoids a crash
            return URL(fileURLWithPath: NSTemporaryDirectory())
        }
        return url
    }

    static var appRoot: URL {
        documentDirectory.appendingPathComponent("NexGenSpec", isDirectory: true)
    }

    static var inspectionsIndex: URL {
        appRoot.appendingPathComponent("inspections.json", isDirectory: false)
    }

    static func inspectionFolder(jobId: UUID) -> URL {
        appRoot
            .appendingPathComponent("Inspections", isDirectory: true)
            .appendingPathComponent(jobId.uuidString, isDirectory: true)
    }

    static func inspectionFile(jobId: UUID) -> URL {
        inspectionFolder(jobId: jobId).appendingPathComponent("inspection.json", isDirectory: false)
    }

    static func photosFolder(jobId: UUID) -> URL {
        inspectionFolder(jobId: jobId).appendingPathComponent("photos", isDirectory: true)
    }

    static func thumbnailsFolder(jobId: UUID) -> URL {
        inspectionFolder(jobId: jobId).appendingPathComponent("thumbnails", isDirectory: true)
    }

    static func annotationFile(jobId: UUID, photoId: UUID) -> URL {
        inspectionFolder(jobId: jobId)
            .appendingPathComponent("annotations", isDirectory: true)
            .appendingPathComponent("\(photoId.uuidString).json", isDirectory: false)
    }

    static func lidarFolder(jobId: UUID) -> URL {
        inspectionFolder(jobId: jobId).appendingPathComponent("lidar", isDirectory: true)
    }

    static func videosFolder(jobId: UUID) -> URL {
        inspectionFolder(jobId: jobId).appendingPathComponent("videos", isDirectory: true)
    }

    /// Immutable finalized version snapshots. One file per version.
    static func versionsFolder(jobId: UUID) -> URL {
        inspectionFolder(jobId: jobId).appendingPathComponent("versions", isDirectory: true)
    }

    static func versionSnapshotFile(jobId: UUID, versionId: UUID) -> URL {
        versionsFolder(jobId: jobId).appendingPathComponent("\(versionId.uuidString).json", isDirectory: false)
    }

    /// Current (editable or last) full version for an inspection. Used for metadata-only index.
    static func currentVersionFile(jobId: UUID) -> URL {
        inspectionFolder(jobId: jobId).appendingPathComponent("current.json", isDirectory: false)
    }

    static var auditLog: URL {
        appRoot.appendingPathComponent("audit_log.txt", isDirectory: false)
    }

    static var inspectionsIndexBackup: URL {
        appRoot.appendingPathComponent("inspections.json.backup", isDirectory: false)
    }

    static func signaturesFolder(jobId: UUID) -> URL {
        inspectionFolder(jobId: jobId).appendingPathComponent("signatures", isDirectory: true)
    }

    static func signatureFile(jobId: UUID, signatureId: UUID) -> URL {
        signaturesFolder(jobId: jobId).appendingPathComponent("\(signatureId.uuidString).png", isDirectory: false)
    }

    /// Cover photo lives at the inspection root (not under photos/) so it
    /// can't be confused with item photos and so a single fixed filename
    /// is enough to find it. Always JPEG.
    static func coverPhotoFile(jobId: UUID, fileName: String) -> URL {
        inspectionFolder(jobId: jobId).appendingPathComponent(fileName, isDirectory: false)
    }

    /// Conventional default cover photo filename. Stored in
    /// `Inspection.coverPhotoFileName` so the model can detect "no cover" by nil.
    static let defaultCoverPhotoFileName = "cover.jpg"

    static func ensureAppStructure(jobId: UUID) throws {
        try FileSecurity.ensureProtectedDirectory(appRoot)
        let folder = inspectionFolder(jobId: jobId)
        try FileSecurity.ensureProtectedDirectory(folder)
        try FileSecurity.ensureProtectedDirectory(photosFolder(jobId: jobId))
        try FileSecurity.ensureProtectedDirectory(thumbnailsFolder(jobId: jobId))
        try FileSecurity.ensureProtectedDirectory(folder.appendingPathComponent("annotations", isDirectory: true))
        try FileSecurity.ensureProtectedDirectory(lidarFolder(jobId: jobId))
        try FileSecurity.ensureProtectedDirectory(videosFolder(jobId: jobId))
        try FileSecurity.ensureProtectedDirectory(versionsFolder(jobId: jobId))
        try FileSecurity.ensureProtectedDirectory(signaturesFolder(jobId: jobId))
    }
}
