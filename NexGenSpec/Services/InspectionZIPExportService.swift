//
//  InspectionZIPExportService.swift
//  NexGenSpec
//
//  Bundles a finalized inspection into a single ZIP suitable for client
//  delivery and the inspector's own 5-year retention obligation. Output lives
//  under the per-UID private store (`FilePaths.exportsFolder`, inside `appRoot`
//  in Application Support) — NOT the file-shared Documents directory — so one
//  account's client-PII bundles are never browsable by the next inspector on a
//  shared device. The inspector shares each ZIP out to the Files app / iCloud /
//  Google Drive on demand via the share sheet at export time.
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

    /// Folder where exported ZIPs land: the per-UID `FilePaths.exportsFolder`
    /// (under `appRoot` in Application Support) — NOT the file-shared Documents
    /// directory — so one account's client-PII bundles are never browsable by the
    /// next inspector on a shared device. ZIPs persist across logout and are
    /// removed only by the Account Deletion `appRoot` wipe. The inspector shares
    /// each one out on demand via the share sheet.
    public static var exportFolder: URL {
        FilePaths.exportsFolder
    }

    /// Recursively removes the entire exports folder. The exports folder now
    /// lives under `appRoot`, so the Account Deletion `appRoot` wipe already
    /// removes it; this remains as an explicit, targeted cleanup. Best effort:
    /// logs (off-disk) but never throws, so a stuck file can't block deletion.
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
        // Outer temp dir keeps the `zip-staging-` prefix so the routine temp sweep
        // and the Account-Deletion wipe (ReportExportService.tempExportPrefixes)
        // still reap it. The client-facing PAYLOAD folder nests INSIDE and carries
        // the human-readable export name, so unzipping the delivered archive yields
        // a clean "<Company>_<Address>_<Date>/" folder — never the internal temp name.
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-staging-\(version.id.uuidString)", isDirectory: true)
        let baseStem = ExportNaming.baseStem(for: version.inspection)
        let payloadDir = stagingRoot.appendingPathComponent(baseStem, isDirectory: true)

        // Regenerate the cached whole-home floor plan (if the scan set changed)
        // BEFORE the synchronous HTML render, which only reads the cache.
        await WholeHomeFloorplanService.regenerateIfNeeded(
            jobId: UUID(uuidString: version.inspection.inspectionId) ?? version.id
        )

        // 1. Set up staging, render the canonical HTML, and copy the photo/video
        //    assets — all OFF the main thread. This is the CPU/IO-heavy step (it
        //    processes every photo) and would otherwise hang the UI for several
        //    seconds on a photo-heavy inspection. The PDF render (step 2) must
        //    stay on the main actor because it drives a WKWebView. Mirrors
        //    ReportExportService.export's main/off-main split.
        let htmlURL: URL = try await Task.detached(priority: .userInitiated) {
            if FileManager.default.fileExists(atPath: stagingRoot.path) {
                try? FileManager.default.removeItem(at: stagingRoot)
            }
            let imagesDir = payloadDir.appendingPathComponent("images", isDirectory: true)
            let videosDir = payloadDir.appendingPathComponent("videos", isDirectory: true)
            try FileSecurity.ensureProtectedDirectory(payloadDir)
            try FileSecurity.ensureProtectedDirectory(imagesDir)
            try FileSecurity.ensureProtectedDirectory(videosDir)

            // Relative file paths so the bundled images are reachable inside the ZIP.
            let html = HTMLReportRenderer.renderHTML(
                for: version,
                imageFolderURL: imagesDir,
                videosFolderURL: videosDir,
                absoluteAssetFileURLs: false,
                watermark: watermark
            )
            let url = payloadDir.appendingPathComponent("\(baseStem).html")
            try Data(html.utf8).write(to: url, options: .atomic)
            return url
        }.value

        // 2. Generate the paginated PDF from the same HTML.
        // Its temp name is irrelevant — we copy it into the payload folder under
        // the export stem below.
        let pdfTempURL = try await PDFReportRenderer.generatePDF(
            fromHTMLFile: htmlURL,
            baseURL: payloadDir,
            outputBaseName: nil
        )
        let pdfDest = payloadDir.appendingPathComponent("\(baseStem).pdf")
        if FileManager.default.fileExists(atPath: pdfDest.path) {
            try? FileManager.default.removeItem(at: pdfDest)
        }
        try FileManager.default.copyItem(at: pdfTempURL, to: pdfDest)
        try? FileManager.default.removeItem(at: pdfTempURL)

        // 3. Manifest + integrity sidecar.
        let jobId = UUID(uuidString: version.inspection.inspectionId) ?? version.id
        let hash = FinalizationService.loadReportHash(jobId: jobId, versionId: version.id) ?? ""
        let iso = ISO8601DateFormatter()

        // Branding for the manifest comes from the inspection's frozen snapshot
        // (set at creation), falling back to the live device-local profile ONLY
        // when the snapshot field is empty — i.e. for pre-build-26 inspections.
        // This keeps the manifest's company identity correct for an inspection
        // exported on a different device than the one it was created on.
        let profile = InspectorProfile.shared
        let manifestCompany = version.inspection.companyName.isEmpty ? profile.companyName : version.inspection.companyName
        let manifestLicense = version.inspection.licenseNumber.isEmpty ? profile.licenseNumber : version.inspection.licenseNumber
        let manifestPhone = version.inspection.companyPhone.isEmpty ? profile.phone : version.inspection.companyPhone
        let manifestEmail = version.inspection.companyEmail.isEmpty ? profile.email : version.inspection.companyEmail

        let manifest: [String: Any] = [
            "exportFormat": "1.0",
            "client": version.inspection.clientName,
            "address": version.inspection.propertyAddress,
            "inspector": version.inspection.inspectorName,
            "company": manifestCompany,
            "licenseNumber": manifestLicense,
            "companyPhone": manifestPhone,
            "companyEmail": manifestEmail,
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
        try manifestData.write(to: payloadDir.appendingPathComponent("manifest.json"), options: .atomic)

        let integrityText = """
        NexGenSpec — Report Integrity

        SHA-256 (canonical inspection JSON, captured at finalization):
        \(hash.isEmpty ? "(unavailable — version not finalized)" : hash)

        Scope: this hash seals the inspection's recorded DATA — findings, notes,
        severities, and metadata (the canonical JSON). The bundled photos, videos,
        and signature images are included exactly as captured at finalization, but
        are not individually covered by this hash.

        How to verify:
        1. Open \(baseStem).pdf or \(baseStem).html. The hash printed in the
           footer must match the value above.
        2. To verify against the canonical record, send the Report ID and hash
           to contact@nexgenspec.com — we will confirm the report was generated
           by NexGenSpec and that the inspection data was not altered after
           finalization.
        """
        try Data(integrityText.utf8).write(
            to: payloadDir.appendingPathComponent("integrity.txt"),
            options: .atomic
        )

        // 4. Coordinate the directory into a ZIP. iOS surfaces this via the
        //    NSFileCoordinator `.forUploading` option, which produces a
        //    standard ZIP archive at a transient URL.
        try FileSecurity.ensureProtectedDirectory(exportFolder)
        let outURL = exportFolder.appendingPathComponent("\(baseStem).zip")
        if FileManager.default.fileExists(atPath: outURL.path) {
            try? FileManager.default.removeItem(at: outURL)
        }

        // Zip the PAYLOAD folder (named with the export stem), NOT the outer
        // staging dir — so unzipping yields "<baseStem>/", never "zip-staging-…".
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var copyError: Error?
        coordinator.coordinate(
            readingItemAt: payloadDir,
            options: .forUploading,
            error: &coordError
        ) { tempZipURL in
            do {
                // Write with the same data-protection class as the rest of the
                // private store; the bundle carries full client PII.
                try FileSecurity.copyProtectedItem(from: tempZipURL, to: outURL)
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
}
