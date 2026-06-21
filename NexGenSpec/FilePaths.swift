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

    /// Application Support is NOT exposed by `UIFileSharingEnabled` /
    /// `LSSupportsOpeningDocumentsInPlace`, so the sensitive working store lives
    /// here — out of the file-shared Documents directory (B-0045).
    static var applicationSupportDirectory: URL {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
        }
        return url
    }

    /// Name of the per-user container directory that holds every account's
    /// namespace. Sits inside `legacySharedRoot`; skipped by the B-0096 migration.
    static let usersContainerName = "Users"

    /// The pre-B-0096 shared root: `Application Support/NexGenSpec`. Before B-0096
    /// every account read and wrote the working store here, which leaked one
    /// user's inspections/PII to the next user on a shared device. Retained ONLY
    /// so `SessionMigration` can find legacy data and move it under the active
    /// user, and so an interrupted pre-fix account deletion can still be cleaned
    /// up. New code must use `appRoot`, never this.
    static var legacySharedRoot: URL {
        applicationSupportDirectory.appendingPathComponent("NexGenSpec", isDirectory: true)
    }

    /// Container holding all per-user namespaces: `…/NexGenSpec/Users`.
    static var usersContainer: URL {
        legacySharedRoot.appendingPathComponent(usersContainerName, isDirectory: true)
    }

    /// The private working-store root for an explicit Firebase UID:
    /// `…/NexGenSpec/Users/<uid>`. Used by paths that must target a specific user
    /// regardless of who is currently signed in (e.g. capturing a deletion target).
    static func userRoot(uid: String) -> URL {
        usersContainer.appendingPathComponent(uid, isDirectory: true)
    }

    /// Root of the private working store (inspections, photos, signatures, audit
    /// logs, index) for the CURRENTLY-active user. Lives in Application Support so
    /// it is never browsable via the Files app or USB file sharing (B-0045), and
    /// is namespaced per Firebase UID so accounts never share data on one device
    /// (B-0096). Every other path here derives from `appRoot`, so they all move
    /// with the active user. See `SessionScope.currentSegment` for how the active
    /// segment (signed-in UID / deletion pin / signed-out sentinel) is resolved.
    ///
    /// Backup: this store is INTENTIONALLY included in the user's iCloud /
    /// encrypted device backup (NOT excluded from backup), so a device restore
    /// brings their inspections back — the right behavior for a local-first app.
    /// That backup is scoped to the device owner's own Apple ID; it is not a
    /// cross-account on-device exposure, so it doesn't reopen the privacy concern
    /// the per-UID Application-Support design closes.
    static var appRoot: URL {
        usersContainer.appendingPathComponent(SessionScope.currentSegment, isDirectory: true)
    }

    /// One-time cleanup (B-0045): the working store and company logo used to live
    /// in the file-shared Documents directory. Delete that old exposed copy so no
    /// sensitive data lingers in a browsable location. STRICTLY scoped to the two
    /// NexGenSpec-owned paths below — never the Documents directory itself, and
    /// never anything the app did not create.
    static func cleanupLegacyExposedStore() {
        let fm = FileManager.default
        let legacyStore = documentDirectory.appendingPathComponent("NexGenSpec", isDirectory: true)
        let legacyLogo = documentDirectory.appendingPathComponent("company_logo.png", isDirectory: false)
        for url in [legacyStore, legacyLogo] where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
            } catch {
                Diagnostics.logError(
                    context: "cleanupLegacyExposedStore: failed to remove \(url.lastPathComponent)",
                    error: error,
                    persistToDisk: false
                )
            }
        }
    }

    /// One-time cleanup of the OLD file-shared deliverable copies. Pre-fix builds
    /// wrote exported ZIPs (`Documents/NexGenSpecExports`), mirrored report PDFs
    /// (`Documents/NexGenSpecReports`), and deletion receipts
    /// (`Documents/NexGenSpecReceipts`) into the file-shared Documents directory,
    /// where the next inspector on a shared device could browse a previous
    /// account's client PII via the Files app. Deliverables now live in the
    /// per-UID private store under Application Support; this removes any
    /// pre-existing exposed copies on launch (and again at Account Deletion as a
    /// belt-and-suspenders sweep). STRICTLY scoped to the three NexGenSpec-owned
    /// folders below — never the Documents directory itself, never anything the
    /// app did not create. Idempotent: a no-op once the old copies are gone.
    static func cleanupLegacyDocumentsDeliverables() {
        let fm = FileManager.default
        let legacyDeliverables = [
            documentDirectory.appendingPathComponent("NexGenSpecExports", isDirectory: true),
            documentDirectory.appendingPathComponent("NexGenSpecReports", isDirectory: true),
            documentDirectory.appendingPathComponent("NexGenSpecReceipts", isDirectory: true)
        ]
        for url in legacyDeliverables where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
            } catch {
                Diagnostics.logError(
                    context: "cleanupLegacyDocumentsDeliverables: failed to remove \(url.lastPathComponent)",
                    error: error,
                    persistToDisk: false
                )
            }
        }
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

    // MARK: - Deliverables (per-UID, NOT file-shared)
    //
    // Client deliverables (exported ZIP bundles, mirrored report PDFs) live UNDER
    // the per-UID `appRoot` in Application Support — never the file-shared
    // Documents directory. iOS surfaces only Documents in the Files app
    // (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace), app-globally, so
    // keeping deliverables under `appRoot` means one account's client PII is never
    // browsable by the next account on a shared device. They persist across logout
    // (per-UID) and are removed only by the Account Deletion `appRoot` wipe. The
    // inspector still gets any report into the Files app / iCloud / Drive on demand
    // via the existing share sheet ("Save to Files").

    /// Per-UID folder for exported inspection ZIP bundles (report + photos +
    /// videos + manifest). Under `appRoot`, so it is private, persists across
    /// logout, and is wiped only by Account Deletion.
    static var exportsFolder: URL {
        appRoot.appendingPathComponent("Exports", isDirectory: true)
    }

    /// Per-UID folder for mirrored finalized-report PDFs (organized by property
    /// address). Under `appRoot` — same guarantees as `exportsFolder`.
    static var reportsFolder: URL {
        appRoot.appendingPathComponent("Reports", isDirectory: true)
    }

    /// Folder for account-deletion receipts: `Application Support/NexGenSpecReceipts/`.
    /// NOT under `appRoot` (so it survives the Account Deletion wipe — outliving the
    /// wipe is the whole point of a receipt) and NOT in the file-shared Documents
    /// directory (so a previous account's email / recovery-email / UID is never
    /// browsable by the next inspector via the Files app). The user receives the
    /// receipt at deletion time via the share sheet.
    static var receiptsFolder: URL {
        applicationSupportDirectory.appendingPathComponent("NexGenSpecReceipts", isDirectory: true)
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
