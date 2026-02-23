//
//  FilePaths.swift
//  NexGenSpec
//

import Foundation

enum FilePaths {

    static var documentDirectory: URL {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Documents directory unavailable")
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

    static func ensureAppStructure(jobId: UUID) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: appRoot, withIntermediateDirectories: true)
        let folder = inspectionFolder(jobId: jobId)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: photosFolder(jobId: jobId), withIntermediateDirectories: true)
        try fm.createDirectory(at: thumbnailsFolder(jobId: jobId), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("annotations", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: lidarFolder(jobId: jobId), withIntermediateDirectories: true)
        try fm.createDirectory(at: videosFolder(jobId: jobId), withIntermediateDirectories: true)
        try fm.createDirectory(at: versionsFolder(jobId: jobId), withIntermediateDirectories: true)
        try fm.createDirectory(at: signaturesFolder(jobId: jobId), withIntermediateDirectories: true)
    }
}
