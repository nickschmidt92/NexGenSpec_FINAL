//
//  HTMLReportRenderer.swift
//  NexGenSpec
//
//  HTML report with card layout, summary, and report hash footer. Run on background for large exports.
//

import Foundation
import UIKit
import ImageIO

/// Generates HTML for inspection report. For 300+ photos, call from background queue.
/// If imageFolderURL is set, images are written there and HTML references them (reduces memory for large reports).
enum HTMLReportRenderer {

    static func renderHTML(
        for version: InspectionVersion,
        imageFolderURL: URL? = nil,
        videosFolderURL: URL? = nil,
        absoluteAssetFileURLs: Bool = false
    ) -> String {
        let inspection = version.inspection
        let counts = inspection.summaryCounts()
        let jobId = UUID(uuidString: inspection.inspectionId) ?? version.id
        let reportHash = version.state.isFinalized ? FinalizationService.loadReportHash(jobId: jobId, versionId: version.id) : nil
        let isDraft = version.state.isEditable
        if let folder = imageFolderURL {
            try? FileSecurity.ensureProtectedDirectory(folder)
        }
        if let vFolder = videosFolderURL {
            try? FileSecurity.ensureProtectedDirectory(vFolder)
            for video in inspection.videos {
                let src = FilePaths.videosFolder(jobId: jobId).appendingPathComponent(video.fileName)
                let dest = vFolder.appendingPathComponent(video.fileName)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                try? FileManager.default.copyItem(at: src, to: dest)
            }
        }

        var emailPhoneMeta = ""
        if !inspection.clientEmail.isEmpty { emailPhoneMeta += "<p class=\"meta\"><strong>Email:</strong> \(escapeHTML(inspection.clientEmail))</p>\n" }
        if !inspection.clientPhone.isEmpty { emailPhoneMeta += "<p class=\"meta\"><strong>Phone:</strong> \(escapeHTML(inspection.clientPhone))</p>\n" }

        var html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light">
        <title>Inspection Report – \(escapeHTML(inspection.clientName))</title>
        <style>
        :root { --card-shadow: 0 2px 8px rgba(0,0,0,0.08); --radius: 12px; color-scheme: light; }
        @page { size: A4 portrait; margin: 24px; }
        * { box-sizing: border-box; }
        html, body { background: #f4f7fb; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 0; padding: 20px; color: #1a1a1a; line-height: 1.5; }
        .draft-watermark { position: fixed; top: 50%; left: 50%; transform: translate(-50%,-50%) rotate(-25deg); font-size: 48px; font-weight: bold; color: rgba(0,0,0,0.08); pointer-events: none; z-index: 0; }
        .container { position: relative; z-index: 1; max-width: 900px; margin: 0 auto; }
        .card { background: #fff; border-radius: var(--radius); box-shadow: var(--card-shadow); padding: 20px; margin-bottom: 20px; }
        .header-card { margin-bottom: 24px; }
        h1 { margin: 0 0 8px; font-size: 1.75rem; }
        .meta { color: #666; font-size: 0.95rem; }
        .summary { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 16px; }
        .badge { padding: 8px 14px; border-radius: 8px; color: #fff; font-weight: 600; font-size: 0.9rem; }
        .badge.safety { background: #dc3545; }
        .badge.major { background: #fd7e14; }
        .badge.marginal { background: #ffc107; color: #1a1a1a; }
        .badge.minor { background: #198754; }
        .section-title { font-size: 1.25rem; margin: 24px 0 12px; color: #333; }
        .item-card { border-left: 4px solid #dee2e6; }
        .item-card.safety { border-left-color: #dc3545; }
        .item-card.major { border-left-color: #fd7e14; }
        .item-card.marginal { border-left-color: #ffc107; }
        .item-card.minor { border-left-color: #198754; }
        .item-card h3 { margin: 0 0 8px; font-size: 1.1rem; }
        .item-card .badge { display: inline-block; margin-left: 8px; }
        .item-card p { margin: 6px 0; }
        .item-card .photo { display: block; max-width: 100%; height: auto; border-radius: 8px; margin-top: 8px; page-break-inside: avoid; break-inside: avoid; }
        .signatures { margin-top: 24px; }
        .signatures img { max-width: 200px; height: auto; border: 1px solid #dee2e6; border-radius: 8px; }
        .footer { margin-top: 32px; padding: 16px 20px; border-top: 2px solid #dee2e6; font-size: 0.8rem; color: #666; background: #f8f9fa; border-radius: 0 0 var(--radius) var(--radius); }
        .footer .hash-label { font-weight: 600; color: #444; margin-bottom: 4px; }
        .footer .hash { font-family: ui-monospace, monospace; word-break: break-all; font-size: 0.7rem; color: #888; background: #eef1f5; padding: 6px 10px; border-radius: 6px; display: block; margin-top: 4px; letter-spacing: 0.5px; }
        @media print {
          html, body { background: #fff !important; color: #111 !important; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
          .card { background: #fff !important; box-shadow: none !important; break-inside: avoid-page; page-break-inside: avoid; }
          .meta, .footer { color: #555 !important; }
          .badge { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        }
        </style>
        </head>
        <body>
        \(isDraft ? "<div class=\"draft-watermark\">DRAFT — NOT FINAL</div>" : "")
        <div class="container">
        <div class="card header-card">
        <h1>Inspection Report</h1>
        <p class="meta"><strong>Client:</strong> \(escapeHTML(inspection.clientName))</p>
        \(emailPhoneMeta)
        <p class="meta"><strong>Property:</strong> \(escapeHTML(inspection.propertyAddress))</p>
        <p class="meta"><strong>Date:</strong> \(htmlDateFormatter.string(from: inspection.inspectionDate))</p>
        <p class="meta"><strong>Inspector:</strong> \(escapeHTML(inspection.inspectorName))</p>
        <div class="summary">
        <span class="badge safety">Safety: \(counts.safety)</span>
        <span class="badge major">Major: \(counts.major)</span>
        <span class="badge marginal">Marginal: \(counts.marginal)</span>
        <span class="badge minor">Minor: \(counts.minor)</span>
        </div>
        </div>
        """

        // Room scans (LiDAR)
        let lidarScans = LiDARScanStore.loadScans(jobId: jobId)
        if !lidarScans.isEmpty {
            html += "<div class=\"card\"><h2 class=\"section-title\">Room scans (LiDAR)</h2><ul class=\"meta\">"
            for scan in lidarScans {
                html += "<li>\(escapeHTML(scan.usdzFileName)) — \(htmlDateFormatter.string(from: scan.capturedAt))</li>"
            }
            html += "</ul><p class=\"meta\">3D models (USDZ) are saved with this inspection.</p></div>"
        }

        // Videos (drone / footage)
        if !inspection.videos.isEmpty {
            html += "<div class=\"card\"><h2 class=\"section-title\">Videos (drone / footage)</h2>"
            for video in inspection.videos {
                let label = escapeHTML(video.caption.isEmpty ? video.fileName : video.caption)
                if let videosFolderURL {
                    let fileURL = videosFolderURL.appendingPathComponent(video.fileName)
                    let videoPath = absoluteAssetFileURLs ? fileURL.absoluteString : "videos/\(escapeHTML(video.fileName))"
                    html += "<p><a href=\"\(videoPath)\" target=\"_blank\">\(label)</a> \(escapeHTML(video.source ?? ""))</p>"
                } else {
                    html += "<p class=\"meta\">\(label) \(escapeHTML(video.source ?? ""))</p>"
                }
            }
            html += "</div>"
        }

        for section in inspection.sections {
            let reportItems = section.items.filter { $0.isDefect && $0.includeInReport }
            guard !reportItems.isEmpty else { continue }
            html += "<h2 class=\"section-title\">\(escapeHTML(section.title))</h2>"
            for item in reportItems {
                guard let severity = item.defectSeverity else { continue }
                var imagesHTML = ""
                for photo in item.photos {
                    if let data = loadPhotoData(jobId: jobId, fileName: photo.fileName),
                       let reportData = AnnotationBakeService.bakedImageData(jobId: jobId, photo: photo, photoData: data) {
                        if let folder = imageFolderURL {
                            let fileURL = folder.appendingPathComponent("\(photo.id.uuidString).png")
                            try? FileSecurity.writeProtected(reportData, to: fileURL)
                            let imagePath = absoluteAssetFileURLs ? fileURL.absoluteString : "images/\(photo.id.uuidString).png"
                            imagesHTML += "<img class=\"photo\" src=\"\(imagePath)\" alt=\"Inspection photo\"/>"
                        } else {
                            imagesHTML += "<img class=\"photo\" src=\"data:image/png;base64,\(reportData.base64EncodedString())\" alt=\"Inspection photo\"/>"
                        }
                    }
                }
                var extraFields = ""
                if !item.location.isEmpty {
                    extraFields += "<p><strong>Location:</strong> \(escapeHTML(item.location))</p>\n"
                }
                if !item.inspectorComments.isEmpty {
                    extraFields += "<p><strong>Inspector Comments:</strong> \(escapeHTML(item.inspectorComments))</p>\n"
                }
                if !item.contractorTag.isEmpty {
                    extraFields += "<p><strong>Contractor:</strong> \(escapeHTML(item.contractorTag))</p>\n"
                }
                html += """
                <div class="card item-card \(severity.rawValue.lowercased())">
                <h3>\(escapeHTML(item.title)) <span class="badge \(severity.rawValue.lowercased())">\(severity.rawValue)</span></h3>
                <p><strong>Observed:</strong> \(escapeHTML(item.observed))</p>
                <p><strong>Implication:</strong> \(escapeHTML(item.implication))</p>
                <p><strong>Recommendation:</strong> \(escapeHTML(item.recommendation))</p>
                \(extraFields)\(imagesHTML)
                </div>
                """
            }
        }

        if !inspection.signatures.isEmpty {
            html += "<div class=\"card signatures\"><h2 class=\"section-title\">Signatures</h2>"
            for sig in inspection.signatures {
                if let data = sig.loadImageData(jobId: jobId) {
                    let base64 = data.base64EncodedString()
                    html += "<p><strong>\(escapeHTML(sig.name))</strong> — \(htmlDateFormatter.string(from: sig.date))<br/><img src=\"data:image/png;base64,\(base64)\" alt=\"Signature\"/></p>"
                }
            }
            html += "</div>"
        }

        html += "<div class=\"footer\">"
        if let hash = reportHash {
            html += "<div class=\"hash-label\">Report Verification</div>"
            html += "<span class=\"hash\">SHA-256: \(hash)</span>"
        } else if isDraft {
            html += "This is a draft. Finalized reports include a verification hash."
        }
        html += "</div></div></body></html>"
        return html
    }
}

private let htmlDateFormatter = DateFormatters.mediumDateTime

/// Loads photo data downsampled to a max dimension of 2048px to prevent OOM on 48MP+ images.
private func loadPhotoData(jobId: UUID, fileName: String) -> Data? {
    let url = FilePaths.photosFolder(jobId: jobId).appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return try? Data(contentsOf: url)
    }
    let maxPixelSize: CGFloat = 2048
    let options: [CFString: Any] = [
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return try? Data(contentsOf: url)
    }
    let uiImage = UIImage(cgImage: cgImage)
    return uiImage.pngData()
}

private func escapeHTML(_ input: String) -> String {
    input
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}
