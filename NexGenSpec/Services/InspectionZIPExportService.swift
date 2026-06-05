//
//  InspectionZIPExportService.swift
//  NexGenSpec
//
//  Bundles a finalized inspection into a single ZIP suitable for client
//  delivery and the inspector's own 5-year retention obligation. Output lives
//  at Documents/NexGenSpecExports/ — outside `FilePaths.appRoot`, surfaced via
//  UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace so the inspector
//  can grab it from the Files app and copy it to iCloud Drive / Google Drive.
//
//  Bundle contents:
//    - report.pdf            paginated, signed, integrity-hashed
//    - report.html           canonical HTML the PDF was rendered from
//    - images/               photos referenced by report.html
//    - videos/               inspection videos (if any)
//    - manifest.json         metadata + integrity SHA-256
//    - integrity.txt         human-readable verification instructions
//

import Foundation
import UIKit

public enum InspectionZIPExportError: LocalizedError {
    case zipCoordinationFailed(Error)
    case unknown
    public var errorDescription: String? {
        switch self {
        case .zipCoordinationFailed(let e): return "Could not zip inspection: \(e.localizedDescription)"
        case .unknown:                       return "Inspection ZIP export failed for an unknown reason."
        }
    }
}

public enum InspectionZIPExportService {

    /// Folder where exported ZIPs land. Lives at Documents/NexGenSpecExports/
    /// so it is OUTSIDE `FilePaths.appRoot` and reachable from the Files app.
    public static var exportFolder: URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            // Documents is guaranteed present on iOS; fall back to tmp rather
            // than force-unwrap so a missing directory can never crash export.
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("NexGenSpecExports", isDirectory: true)
        }
        return docs.appendingPathComponent("NexGenSpecExports", isDirectory: true)
    }

    /// Recursively removes the entire exports folder. Called from the Account
    /// Deletion wipe: exported ZIPs (full report + photos + videos + client PII)
    /// live OUTSIDE `FilePaths.appRoot`, so the appRoot-only wipe leaves them
    /// behind — a 5.1.1(v) "no copies retained" gap (T-01447). Best effort: logs
    /// (off-disk) but never throws, so a stuck file can't block deletion.
    static func removeAllExports() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: exportFolder.path) else { return }
        do {
            try fm.removeItem(at: exportFolder)
        } catch {
            Diagnostics.logError(context: "InspectionZIPExportService.removeAllExports failed",
                                 error: error, persistToDisk: false)
        }
    }

    /// Generates a ZIP containing the finalized report + assets. Returns the URL
    /// of the ZIP under `exportFolder`. Caller is responsible for sharing it
    /// (e.g. via `ShareSheet`) and informing the user where it landed.
    ///
    /// `watermark` gates the branded PDF/HTML the same way the in-app export
    /// does: callers must pass `!subscriptionManager.hasFeatureAccess` so free
    /// users get a watermarked report inside the ZIP (B-0065). No default is
    /// provided on purpose — every call site has to make the entitlement
    /// decision explicit.
    @MainActor
    public static func exportZIP(for version: InspectionVersion, watermark: Bool) async throws -> URL {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-staging-\(version.id.uuidString)", isDirectory: true)
        if FileManager.default.fileExists(atPath: stagingRoot.path) {
            try? FileManager.default.removeItem(at: stagingRoot)
        }
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        let imagesDir = stagingRoot.appendingPathComponent("images", isDirectory: true)
        let videosDir = stagingRoot.appendingPathComponent("videos", isDirectory: true)
        try FileSecurity.ensureProtectedDirectory(imagesDir)
        try FileSecurity.ensureProtectedDirectory(videosDir)

        // 1. Render canonical HTML with relative file paths so the bundled images
        //    are reachable inside the ZIP.
        let html = HTMLReportRenderer.renderHTML(
            for: version,
            imageFolderURL: imagesDir,
            videosFolderURL: videosDir,
            absoluteAssetFileURLs: false,
            watermark: watermark
        )
        let htmlURL = stagingRoot.appendingPathComponent("report.html")
        try Data(html.utf8).write(to: htmlURL, options: .atomic)

        // 2. Generate the paginated PDF from the same HTML.
        let pdfTempURL = try await PDFReportRenderer.generatePDF(
            fromHTMLFile: htmlURL,
            baseURL: stagingRoot,
            clientName: version.inspection.clientName
        )
        let pdfDest = stagingRoot.appendingPathComponent("report.pdf")
        if FileManager.default.fileExists(atPath: pdfDest.path) {
            try? FileManager.default.removeItem(at: pdfDest)
        }
        try FileManager.default.copyItem(at: pdfTempURL, to: pdfDest)
        try? FileManager.default.removeItem(at: pdfTempURL)

        // 3. Manifest + integrity sidecar.
        let jobId = UUID(uuidString: version.inspection.inspectionId) ?? version.id
        let hash = FinalizationService.loadReportHash(jobId: jobId, versionId: version.id) ?? ""
        let iso = ISO8601DateFormatter()

        let manifest: [String: Any] = [
            "exportFormat": "1.0",
            "client": version.inspection.clientName,
            "address": version.inspection.propertyAddress,
            "inspector": version.inspection.inspectorName,
            "inspectionDate": iso.string(from: version.inspection.inspectionDate),
            "finalizedAt": version.finalizedAt.map { iso.string(from: $0) } ?? "",
            "versionId": version.id.uuidString,
            "versionNumber": version.versionNumber,
            "integritySHA256": hash,
            "exportedAt": iso.string(from: Date())
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: stagingRoot.appendingPathComponent("manifest.json"), options: .atomic)

        let integrityText = """
        NexGenSpec — Report Integrity

        SHA-256 (canonical inspection JSON, captured at finalization):
        \(hash.isEmpty ? "(unavailable — version not finalized)" : hash)

        How to verify:
        1. Open report.pdf or report.html. The hash printed in the footer must
           match the value above.
        2. To verify against the canonical record, send the Report ID and hash
           to contact@nexgenspec.com — we will confirm the report was generated
           by NexGenSpec and that no edits were made to the inspection data
           after finalization.
        """
        try Data(integrityText.utf8).write(
            to: stagingRoot.appendingPathComponent("integrity.txt"),
            options: .atomic
        )

        // 4. Coordinate the directory into a ZIP. iOS surfaces this via the
        //    NSFileCoordinator `.forUploading` option, which produces a
        //    standard ZIP archive at a transient URL.
        try FileManager.default.createDirectory(
            at: exportFolder,
            withIntermediateDirectories: true
        )
        let stamp = Self.filenameDateFormatter.string(from: Date())
        let safeClient = sanitize(version.inspection.clientName, fallback: "Inspection")
        let outURL = exportFolder.appendingPathComponent("NexGenSpec_\(safeClient)_\(stamp).zip")
        if FileManager.default.fileExists(atPath: outURL.path) {
            try? FileManager.default.removeItem(at: outURL)
        }

        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var copyError: Error?
        coordinator.coordinate(
            readingItemAt: stagingRoot,
            options: .forUploading,
            error: &coordError
        ) { tempZipURL in
            do {
                try FileManager.default.copyItem(at: tempZipURL, to: outURL)
            } catch {
                copyError = error
            }
        }
        if let coordError {
            throw InspectionZIPExportError.zipCoordinationFailed(coordError)
        }
        if let copyError {
            throw InspectionZIPExportError.zipCoordinationFailed(copyError)
        }

        try? FileManager.default.removeItem(at: stagingRoot)

        AuditLog.log(
            event: "Inspection ZIP exported (sha256: \(hash))",
            versionId: version.id,
            inspectionId: jobId
        )
        return outURL
    }

    // MARK: - Helpers

    private static func sanitize(_ raw: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let cleaned = raw.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
            .replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static let filenameDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt
    }()
}
