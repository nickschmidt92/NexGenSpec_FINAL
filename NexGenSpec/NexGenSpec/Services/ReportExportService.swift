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
    public func export(version: InspectionVersion) async {
        guard !isExporting else { return }
        isExporting = true
        progress = 0
        result = nil
        errorMessage = nil
        let versionCopy = version
        let task = Task {
            // Heavy work (HTML + write) off main thread; then PDF on main (WKWebView needs main).
            let htmlResult: (htmlURL: URL?, reportDir: URL, tempHTML: URL)? = await Task.detached(priority: .userInitiated) {
                await Task.yield()
                if Task.isCancelled { return nil }
                var htmlURL: URL?
                do {
                    let reportDir = FileManager.default.temporaryDirectory.appendingPathComponent("report-\(versionCopy.id.uuidString)", isDirectory: true)
                    let imagesDir = reportDir.appendingPathComponent("images", isDirectory: true)
                    let videosDir = reportDir.appendingPathComponent("videos", isDirectory: true)
                    try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
                    if Task.isCancelled { return nil }
                    let html = HTMLReportRenderer.renderHTML(for: versionCopy, imageFolderURL: imagesDir, videosFolderURL: videosDir)
                    let tempHTML = reportDir.appendingPathComponent("index.html")
                    try html.write(to: tempHTML, atomically: true, encoding: .utf8)
                    htmlURL = tempHTML
                    return (htmlURL, reportDir, tempHTML)
                } catch {
                    return nil
                }
            }.value
            guard !Task.isCancelled else {
                finishExport(cancelled: true)
                return
            }
            progress = 0.7
            var finalResult: ReportExportResult
            if let htmlResult {
                let pdfURL = await PDFReportRenderer.generatePDF(fromHTMLFile: htmlResult.tempHTML, baseURL: htmlResult.reportDir)
                guard !Task.isCancelled else {
                    finishExport(cancelled: true)
                    return
                }
                let resolvedPDF = pdfURL ?? PDFReportRenderer.generatePDF(for: versionCopy)
                progress = 1
                if let resolvedPDF {
                    finalResult = .success(htmlURL: htmlResult.htmlURL, pdfURL: resolvedPDF)
                } else {
                    finalResult = .failure(NSError(domain: "ReportExport", code: -1, userInfo: [NSLocalizedDescriptionKey: "PDF could not be generated. The report may be too large."]))
                }
            } else {
                progress = 1
                finalResult = .failure(NSError(domain: "ReportExport", code: -2, userInfo: [NSLocalizedDescriptionKey: "Report export failed."]))
            }
            finishExport(result: finalResult)
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
}
