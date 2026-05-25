//
//  FilesAppPublisher.swift
//  NexGenSpec
//
//  Mirrors a finalized inspection into a clean, Files-app-friendly folder so
//  the inspector gets one-tap PDF access organized by property address:
//
//      Files → On My iPhone → NexGenSpec
//        └── [Property Address]/
//            ├── Inspection_Report.pdf
//            └── _data/
//                └── (inspection.json, photos, videos, lidar, signatures, …)
//
//  The app's working storage stays where it is (NexGenSpec/Inspections/<uuid>/),
//  which remains the source of truth. This published folder is a convenience
//  mirror, rebuilt on each export, so it never diverges from the canonical data
//  and a same-address re-export simply refreshes it. Visibility in the Files app
//  is granted by UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace in
//  Info.plist (the app's Documents directory is what Files surfaces).
//

import Foundation

enum FilesAppPublisher {

    /// Publishes `version` into `NexGenSpec/[Property Address]/`, copying the
    /// exported PDF to the top level and the inspection's raw data into `_data/`.
    /// Idempotent — the address folder is rebuilt each call. Returns the folder
    /// URL on success, or nil on failure (failures are logged, never thrown, so
    /// publishing can never block an export the inspector already completed).
    @discardableResult
    static func publish(version: InspectionVersion, pdfURL: URL?) -> URL? {
        let jobId = UUID(uuidString: version.inspection.inspectionId) ?? version.id
        let destFolder = FilePaths.appRoot.appendingPathComponent(
            folderName(for: version.inspection, jobId: jobId),
            isDirectory: true
        )
        let dataFolder = destFolder.appendingPathComponent("_data", isDirectory: true)
        let fm = FileManager.default

        do {
            // Rebuild cleanly so stale files from a prior export don't linger
            // (e.g. a photo deleted between exports).
            if fm.fileExists(atPath: destFolder.path) {
                try fm.removeItem(at: destFolder)
            }
            try FileSecurity.ensureProtectedDirectory(destFolder)

            // 1. PDF at the top level — the inspector's one-tap deliverable.
            if let pdfURL, fm.fileExists(atPath: pdfURL.path) {
                let pdfDest = destFolder.appendingPathComponent("Inspection_Report.pdf")
                try FileSecurity.copyProtectedItem(from: pdfURL, to: pdfDest)
            }

            // 2. Raw supporting data into _data/. Copy the whole canonical
            //    inspection folder (json, photos, videos, lidar, signatures).
            let srcFolder = FilePaths.inspectionFolder(jobId: jobId)
            if fm.fileExists(atPath: srcFolder.path) {
                try FileSecurity.copyProtectedItem(from: srcFolder, to: dataFolder)
            } else {
                try FileSecurity.ensureProtectedDirectory(dataFolder)
            }

            return destFolder
        } catch {
            Diagnostics.logError(context: "FilesAppPublisher.publish failed", error: error)
            return nil
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
