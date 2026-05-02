//
//  ReportExportService.swift
//  NexGenSpec
//
//  Runs report generation on background. Use for large inspections to avoid UI freeze.
//

import Foundation
import UIKit

/// Result of background report export.
public enum ReportExportResult {
    case success(htmlURL: URL?, pdfURL: URL?)
    case failure(Error)
}

/// Runs HTML and PDF generation off the main thread. Report progress 0...1.
/// Images are written to a temp folder (imageFolderURL) and referenced by path in HTML to avoid loading all photos in memory (batch/stream-friendly for large reports).
@MainActor
public final class ReportExportService: ObservableObject {

    @Published public private(set) var isExporting = false
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var result: ReportExportResult?
    @Published public private(set) var errorMessage: String?

    private var exportTask: Task<Void, Never>?

    public init() {}

    /// Export report for version. Updates progress and result on main. Supports cancellation via cancelExport().
    /// Set `watermark` to true for free-tier exports (adds "NexGenSpec Free" overlay).
    public func export(version: InspectionVersion, watermark: Bool = false) async {
        guard !isExporting else { return }
        isExporting = true
        progress = 0
        result = nil
        errorMessage = nil
        let versionCopy = version
        let wm = watermark
        let task = Task {
            // Heavy work (HTML + write) off main thread; then PDF on main (WKWebView needs main).
            // Step 1: render HTML + assets off main. HTML is the source of truth and must always succeed.
            let htmlResult: (htmlURL: URL, reportDir: URL)? = await Task.detached(priority: .userInitiated) {
                await Task.yield()
                if Task.isCancelled { return nil }
                do {
                    let reportDir = FileManager.default.temporaryDirectory.appendingPathComponent("report-\(versionCopy.id.uuidString)", isDirectory: true)
                    let imagesDir = reportDir.appendingPathComponent("images", isDirectory: true)
                    let videosDir = reportDir.appendingPathComponent("videos", isDirectory: true)
                    ReportExportService.cleanupOldReportFolders()
                    if FileManager.default.fileExists(atPath: reportDir.path) {
                        try? FileManager.default.removeItem(at: reportDir)
                    }
                    try FileSecurity.ensureProtectedDirectory(imagesDir)
                    try FileSecurity.ensureProtectedDirectory(videosDir)
                    if Task.isCancelled { return nil }
                    let html = HTMLReportRenderer.renderHTML(
                        for: versionCopy,
                        imageFolderURL: imagesDir,
                        videosFolderURL: videosDir,
                        watermark: wm
                    )
                    let tempHTML = reportDir.appendingPathComponent("index.html")
                    try FileSecurity.writeProtected(Data(html.utf8), to: tempHTML)
                    return (tempHTML, reportDir)
                } catch {
                    Diagnostics.logError(context: "Report export HTML generation failed", error: error)
                    return nil
                }
            }.value

            guard !Task.isCancelled else {
                finishExport(cancelled: true)
                return
            }

            guard let htmlResult else {
                finishExport(result: .failure(NSError(
                    domain: "ReportExport",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Report HTML could not be generated."]
                )))
                return
            }

            progress = 0.7

            // Step 2: derive PDF from HTML. Single code path. If it throws, HTML still ships.
            var pdfURL: URL?
            do {
                pdfURL = try await PDFReportRenderer.generatePDF(
                    fromHTMLFile: htmlResult.htmlURL,
                    baseURL: htmlResult.reportDir,
                    clientName: versionCopy.inspection.clientName
                )
            } catch {
                Diagnostics.logError(context: "PDF generation failed; returning HTML-only export", error: error)
                pdfURL = nil
            }

            guard !Task.isCancelled else {
                finishExport(cancelled: true)
                return
            }

            if pdfURL != nil, versionCopy.state.isFinalized {
                let jobId = UUID(uuidString: versionCopy.inspection.inspectionId) ?? versionCopy.id
                let hash = FinalizationService.loadReportHash(jobId: jobId, versionId: versionCopy.id) ?? "unknown"
                AuditLog.log(
                    event: "Report exported to PDF (integrity SHA-256: \(hash))",
                    versionId: versionCopy.id,
                    inspectionId: jobId
                )
            }

            progress = 1
            finishExport(result: .success(htmlURL: htmlResult.htmlURL, pdfURL: pdfURL))
        }
        exportTask = task
        await task.value
        exportTask = nil
    }

    private func finishExport(result: ReportExportResult? = nil, cancelled: Bool = false) {
        self.result = result
        self.isExporting = false
        self.progress = cancelled ? 0 : 1
        if cancelled {
            self.errorMessage = nil
        } else if case .failure(let error)? = result {
            self.errorMessage = error.localizedDescription
        }
    }

    /// Cancels the in-progress export. No-op if not exporting.
    public func cancelExport() {
        exportTask?.cancel()
    }

    public func reset() {
        exportTask?.cancel()
        exportTask = nil
        result = nil
        progress = 0
        errorMessage = nil
    }

    nonisolated private static func cleanupOldReportFolders() {
        let tmp = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let prefixes = ["report-", "pdf-", "InspectionReport-", "InspectionReport_"]
        for url in files where prefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) {
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = vals?.contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
