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
    /// empty or ambiguous.
    private static func folderName(for inspection: Inspection, jobId: UUID) -> String {
        let address = sanitized(inspection.propertyAddress)
        if !address.isEmpty { return address }
        let client = sanitized(inspection.clientName)
        if !client.isEmpty { return client }
        return "Inspection-\(jobId.uuidString.prefix(8))"
    }

    /// Strips characters that are illegal or awkward in a folder name and
    /// collapses whitespace. Keeps it readable in the Files app.
    private static func sanitized(_ raw: String) -> String {
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
}
