//
//  FilesAppPublisher.swift
//  NexGenSpec
//
//  Mirrors a finalized inspection's PDF into a clean per-inspection folder,
//  organized by property address, in the per-UID private store
//  (`FilePaths.reportsFolder`, under `appRoot` in Application Support):
//
//      <appRoot>/Reports/[Property Address]/Inspection_Report.pdf
//
//  PDF ONLY. Raw inspection data (inspection.json, photos, videos, lidar,
//  signatures) is NEVER mirrored here — it stays elsewhere in the private store.
//  The folder is rebuilt on each export, so it never diverges from the canonical
//  data and a same-address re-export refreshes it.
//
//  These PDFs are deliberately NOT placed in the file-shared Documents directory:
//  iOS surfaces Documents to the Files app app-globally, which would let the next
//  inspector on a shared device read a previous account's client reports (the
//  cross-account PII leak this fix closes). The inspector still gets any report
//  into the Files app / iCloud / Drive on demand via the share sheet
//  ("Save to Files"). Mirrored reports persist across logout (per-UID) and are
//  removed only by the Account Deletion `appRoot` wipe.
//

import Foundation

enum FilesAppPublisher {

    /// Per-UID, private root for published report PDFs: `FilePaths.reportsFolder`
    /// (under `appRoot` in Application Support) — NOT the file-shared Documents
    /// directory — so a previous account's reports are never browsable by the next
    /// inspector via the Files app. Only finalized-report PDFs live here, never raw
    /// inspection data (B-0045).
    private static var publishRoot: URL {
        FilePaths.reportsFolder
    }

    /// Publishes `version`'s PDF into `<appRoot>/Reports/[Property Address]/`.
    /// Idempotent — the address folder is rebuilt each call. Returns the folder
    /// URL on success, or nil on failure (failures are logged, never thrown, so
    /// publishing can never block an export the inspector already completed).
    @discardableResult
    static func publish(version: InspectionVersion, pdfURL: URL?) -> URL? {
        let jobId = UUID(uuidString: version.inspection.inspectionId) ?? version.id
        let destFolder = publishRoot.appendingPathComponent(
            folderName(for: version.inspection, jobId: jobId),
            isDirectory: true
        )
        let fm = FileManager.default

        // Defense-in-depth (B-0117): `removeItem` below resolves any "." / ".."
        // in the path at the syscall layer, so a destFolder that standardizes
        // OUTSIDE the reports root would delete appRoot (the user's entire
        // per-UID store). `folderName` already rejects traversal components, but
        // refuse anything that escapes `publishRoot` here too, so no future
        // folderName change can ever turn this rebuild-delete into a store wipe.
        let rootPath = publishRoot.standardizedFileURL.path
        guard destFolder.standardizedFileURL.path.hasPrefix(rootPath + "/") else {
            Diagnostics.logError(
                context: "FilesAppPublisher.publish: refusing destFolder outside reportsFolder (\(destFolder.lastPathComponent))",
                error: NSError(domain: "FilesAppPublisher", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "unsafe destination folder"]),
                persistToDisk: false
            )
            return nil
        }

        do {
            // Rebuild cleanly so stale files from a prior export don't linger
            // (e.g. a photo deleted between exports).
            if fm.fileExists(atPath: destFolder.path) {
                try fm.removeItem(at: destFolder)
            }
            try FileSecurity.ensureProtectedDirectory(destFolder)

            // PDF only — the inspector's one-tap deliverable. Raw inspection data
            // (json, photos, videos, lidar, signatures) is deliberately NOT
            // mirrored: it stays in the private working store in Application
            // Support and is never placed in the file-shared Documents directory
            // (B-0045).
            if let pdfURL, fm.fileExists(atPath: pdfURL.path) {
                let pdfDest = destFolder.appendingPathComponent("Inspection_Report.pdf")
                try FileSecurity.copyProtectedItem(from: pdfURL, to: pdfDest)
                // Record the jobId in a hidden sidecar so a later delete can recover it
                // to emit the matching CloudKit asset tombstone even if the address /
                // client name (and thus this folder name) changed after export — without
                // it, recomputing folderName from current metadata orphans the tombstone
                // and the stale PDF persists on other devices (D-0203 review). Best-
                // effort: it must never break an export the inspector already completed.
                try? FileSecurity.writeProtected(
                    Data(jobId.uuidString.utf8),
                    to: destFolder.appendingPathComponent(jobIdSidecarName, isDirectory: false))
                // Mirror the finalized report PDF to CloudKit (D-0203). This is the
                // only persistent PDF (temp export folders are never published); a
                // same-address re-export overwrites the same recordName.
                SyncCoordinator.noteMediaUpserted(
                    jobId: jobId,
                    relativePath: "Reports/\(destFolder.lastPathComponent)/Inspection_Report.pdf")
            }

            return destFolder
        } catch {
            Diagnostics.logError(context: "FilesAppPublisher.publish failed", error: error)
            return nil
        }
    }

    /// The published folder URL for an inspection (<appRoot>/Reports/[Property Address]/).
    static func publishedFolderURL(for inspection: Inspection, jobId: UUID) -> URL {
        publishRoot.appendingPathComponent(
            folderName(for: inspection, jobId: jobId),
            isDirectory: true
        )
    }

    // MARK: - jobId sidecar (D-0203 delete propagation)

    /// Hidden per-folder sidecar recording the inspection jobId a published report
    /// belongs to. Dot-prefixed so it never surfaces in the Files app or the
    /// `scanReports` folder listing (which enumerates the reports root, not each
    /// folder's contents, and skips hidden entries). Lets a delete recover the jobId
    /// without recomputing folderName from possibly-renamed current metadata.
    static let jobIdSidecarName = ".report-jobid"

    /// The inspection jobId recorded in a published report folder's sidecar, or nil
    /// for a legacy folder published before the sidecar existed (the caller then
    /// falls back to name-matching current metadata).
    static func publishedJobId(inFolder folder: URL) -> UUID? {
        let sidecar = folder.appendingPathComponent(jobIdSidecarName, isDirectory: false)
        guard let raw = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }
        return UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The published report folder that belongs to `jobId`, located by its sidecar
    /// (rename-proof) rather than by recomputing a possibly-stale folder name. nil if
    /// no published folder currently maps to the jobId.
    static func publishedFolder(forJobId jobId: UUID) -> URL? {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: publishRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        return folders.first { publishedJobId(inFolder: $0) == jobId }
    }

    /// The root-relative path of the published report PDF for `jobId`, if one exists
    /// on disk — located by the folder's jobId sidecar (rename-proof), falling back to
    /// the folder computed from `inspection`'s current metadata for legacy exports.
    /// Used to emit the CloudKit asset tombstone when an inspection is deleted so its
    /// ReportPDF record doesn't outlive it and resurrect on a fresh device (D-0203
    /// review). nil when no published PDF exists.
    static func publishedReportRelativePath(forJobId jobId: UUID, inspection: Inspection?) -> String? {
        let fm = FileManager.default
        if let folder = publishedFolder(forJobId: jobId),
           fm.fileExists(atPath: folder.appendingPathComponent("Inspection_Report.pdf").path) {
            return "Reports/\(folder.lastPathComponent)/Inspection_Report.pdf"
        }
        if let inspection {
            let folder = publishedFolderURL(for: inspection, jobId: jobId)
            if fm.fileExists(atPath: folder.appendingPathComponent("Inspection_Report.pdf").path) {
                return "Reports/\(folder.lastPathComponent)/Inspection_Report.pdf"
            }
        }
        return nil
    }

    /// Removes the published Files-app folder for an inspection, if present.
    /// Called when an inspection is deleted so its mirror (PDF + _data) doesn't
    /// linger in the Files app after the inspection is gone.
    static func removePublished(for inspection: Inspection, jobId: UUID) {
        let folder = publishedFolderURL(for: inspection, jobId: jobId)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            Diagnostics.logError(context: "FilesAppPublisher.removePublished failed", error: error)
        }
    }

    /// Recursively removes the entire published-reports root (all property-address
    /// subfolders). The reports root now lives under `appRoot`, so the Account
    /// Deletion `appRoot` wipe already removes it; this remains as an explicit,
    /// targeted cleanup. Best effort: logs (off-disk) but never throws.
    static func removeAllPublished() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: publishRoot.path) else { return }
        do {
            try fm.removeItem(at: publishRoot)
        } catch {
            Diagnostics.logError(context: "FilesAppPublisher.removeAllPublished failed",
                                 error: error, persistToDisk: false)
        }
    }

    // MARK: - Folder naming

    /// Builds a filesystem-safe folder name from the property address, falling
    /// back to the client name and finally a short job ID so the folder is never
    /// empty, ambiguous, OR a path-traversal component.
    ///
    /// SECURITY (B-0117): the property address is free-text and `sanitized`
    /// removes path separators but NOT lone dots, so a raw address of "." or
    /// ".." survives sanitization. Because `publish()` does
    /// `removeItem(at: reportsFolder/<name>)` to rebuild cleanly,
    /// `reportsFolder/".."` resolves to `appRoot` and would silently wipe the
    /// user's ENTIRE per-UID store. `isSafeComponent` rejects those (and any
    /// separator-bearing name) so folderName can only return a single, contained
    /// subfolder name; the fallback chain guarantees it is never empty.
    static func folderName(for inspection: Inspection, jobId: UUID) -> String {
        folderName(propertyAddress: inspection.propertyAddress, clientName: inspection.clientName, jobId: jobId)
    }

    /// Field-level overload so callers that only hold `VersionMetadata` (e.g.
    /// MyReportsView resolving a report folder back to its jobId for a delete-sync
    /// emit) can compute the identical folder name without a full `Inspection`.
    static func folderName(propertyAddress: String, clientName: String, jobId: UUID) -> String {
        let address = sanitized(propertyAddress)
        if isSafeComponent(address) { return address }
        let client = sanitized(clientName)
        if isSafeComponent(client) { return client }
        return "Inspection-\(jobId.uuidString.prefix(8))"
    }

    /// A folder name is usable only if it is non-empty AND not a path-traversal
    /// component (".", "..") AND contains no path separator — so appending it to
    /// `reportsFolder` can never climb out of that directory.
    static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    /// Strips characters that are illegal or awkward in a folder name and
    /// collapses whitespace. Keeps it readable in the Files app. NOTE: this does
    /// NOT strip lone dots, so its output must be passed through
    /// `isSafeComponent` before use as a path component (see B-0117).
    static func sanitized(_ raw: String) -> String {
        // `/` and `:` are illegal on the underlying filesystem and HFS-visible
        // layer; the rest just keep folder names tidy.
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = raw
            .components(separatedBy: illegal)
            .joined(separator: " ")
        // Collapse runs of whitespace into single spaces and trim.
        let collapsed = cleaned
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Shared / exported file naming (T-01624)

    /// The client-facing file name for the report PDF handed to the RECIPIENT at
    /// share / export time (Save to Files, email, AirDrop):
    ///
    ///     "<Client> - <Address> - Inspection Report.pdf"
    ///     e.g. "Smith - 12147 Idalia St - Inspection Report.pdf"
    ///
    /// This is deliberately NOT the on-disk name of the synced mirror at
    /// `Reports/<folder>/Inspection_Report.pdf`. That mirror's CloudKit asset key
    /// is hashed over its exact root-relative path
    /// (`CloudKitSchema.assetRecordName` + `CloudKitSyncPort.seedableAssetPaths`),
    /// so renaming it on disk would change the key and drop it out of the sync
    /// allowlist. Callers therefore COPY the mirror to a temp file under this name
    /// (`makeShareCopy`) and share the copy, leaving the synced path untouched.
    ///
    /// Falls back gracefully: client-only or address-only when the other is empty,
    /// and a plain "Inspection Report.pdf" when both are empty (never an empty or
    /// ambiguous name). Each component is length-bounded so the assembled name
    /// stays well under filesystem / share-sheet limits.
    static func shareFileName(clientName: String, propertyAddress: String) -> String {
        let client = sanitizedShareComponent(clientName)
        let address = sanitizedShareComponent(propertyAddress)
        let stem: String
        switch (client.isEmpty, address.isEmpty) {
        case (false, false): stem = "\(client) - \(address) - Inspection Report"
        case (false, true):  stem = "\(client) - Inspection Report"
        case (true, false):  stem = "\(address) - Inspection Report"
        case (true, true):   stem = "Inspection Report"
        }
        return stem + ".pdf"
    }

    /// Copies `sourcePDF` to a fresh temp file named `shareFileName(...)` and
    /// returns that URL for the share sheet / mail composer, so the client sees a
    /// descriptive name instead of the generic on-disk "Inspection_Report.pdf"
    /// (which otherwise collides into "Inspection_Report 2.pdf" on repeated saves).
    ///
    /// CRITICAL — this NEVER renames or moves `sourcePDF`. When the source is the
    /// synced mirror (MyReportsView shares it directly), renaming it in place would
    /// change the root-relative path the CloudKit asset key hashes over
    /// (`CloudKitSchema.assetRecordName`) and drop it out of `seedableAssetPaths`,
    /// breaking cross-device asset sync (D-0203). Copying leaves the mirror's path
    /// and key intact.
    ///
    /// The copy lands in a `report-share-<uuid>` temp subfolder whose `report-`
    /// prefix is in `ReportExportService.tempExportPrefixes`, so both the 24h temp
    /// sweep and the Account-Deletion temp wipe reclaim it (the copy carries client
    /// PII in its name and bytes). A unique subfolder also lets the file keep the
    /// exact `shareFileName` even if two reports share the same name. Best effort:
    /// returns `sourcePDF` unchanged if the copy fails, so sharing is never blocked.
    static func makeShareCopy(of sourcePDF: URL, clientName: String, propertyAddress: String) -> URL {
        let name = shareFileName(clientName: clientName, propertyAddress: propertyAddress)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("report-share-\(UUID().uuidString)", isDirectory: true)
        let dest = dir.appendingPathComponent(name, isDirectory: false)
        do {
            try FileSecurity.copyProtectedItem(from: sourcePDF, to: dest)
            return dest
        } catch {
            Diagnostics.logError(context: "FilesAppPublisher.makeShareCopy failed",
                                 error: error, persistToDisk: false)
            return sourcePDF
        }
    }

    /// Sanitizes ONE component (client or address) for a shared FILE name: reuses
    /// `sanitized` (replace path-illegal / awkward chars with spaces, collapse
    /// whitespace, trim) and additionally bounds the length so the assembled name
    /// stays reasonable. Unlike a folder component this needs no `isSafeComponent`
    /// traversal guard: the result is only ever a file's lastPathComponent inside a
    /// freshly-created unique temp subfolder, never a directory that gets
    /// rebuilt/deleted (B-0117 concerns only the rebuilt reports folder).
    static func sanitizedShareComponent(_ raw: String, maxLength: Int = 60) -> String {
        let cleaned = sanitized(raw)
        guard cleaned.count > maxLength else { return cleaned }
        return String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }
}
