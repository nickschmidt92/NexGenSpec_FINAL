//
//  HTMLReportRenderer.swift
//  NexGenSpec
//
//  HTML report with card layout, summary, and report hash footer. Run on background for large exports.
//

import Foundation

/// Generates HTML for inspection report. For 300+ photos, call from background queue.
/// If imageFolderURL is set, images are written there and HTML references them (reduces memory for large reports).
enum HTMLReportRenderer {

    static func renderHTML(for version: InspectionVersion, imageFolderURL: URL? = nil, videosFolderURL: URL? = nil) -> String {
        let inspection = version.inspection
        let counts = inspection.summaryCounts()
        let jobId = UUID(uuidString: inspection.inspectionId) ?? version.id
        let reportHash = version.state.isFinalized ? FinalizationService.loadReportHash(jobId: jobId, versionId: version.id) : nil
        let isDraft = version.state.isEditable
        if let folder = imageFolderURL {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if let vFolder = videosFolderURL {
            try? FileManager.default.createDirectory(at: vFolder, withIntermediateDirectories: true)
            for video in inspection.videos {
                let src = FilePaths.videosFolder(jobId: jobId).appendingPathComponent(video.fileName)
                let dest = vFolder.appendingPathComponent(video.fileName)
                try? FileManager.default.copyItem(at: src, to: dest)
            }
        }

        var emailPhoneMeta = ""
        if !inspection.clientEmail.isEmpty { emailPhoneMeta += "<p class=\"meta\"><strong>Email:</strong> \(inspection.clientEmail)</p>\n" }
        if !inspection.clientPhone.isEmpty { emailPhoneMeta += "<p class=\"meta\"><strong>Phone:</strong> \(inspection.clientPhone)</p>\n" }

        var html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Inspection Report – \(inspection.clientName)</title>
        <style>
        :root { --card-shadow: 0 2px 8px rgba(0,0,0,0.08); --radius: 12px; }
        * { box-sizing: border-box; }
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
        .item-card .photo { max-width: 100%; height: auto; border-radius: 8px; margin-top: 8px; }
        .signatures { margin-top: 24px; }
        .signatures img { max-width: 200px; height: auto; border: 1px solid #dee2e6; border-radius: 8px; }
        .footer { margin-top: 32px; padding-top: 16px; border-top: 1px solid #dee2e6; font-size: 0.8rem; color: #666; }
        .footer .hash { font-family: ui-monospace, monospace; word-break: break-all; }
        @media (prefers-color-scheme: dark) { body { background: #1a1a1a; color: #e0e0e0; } .card { background: #2d2d2d; } .meta, .footer { color: #aaa; } }
        </style>
        </head>
        <body>
        \(isDraft ? "<div class=\"draft-watermark\">DRAFT — NOT FINAL</div>" : "")
        <div class="container">
        <div class="card header-card">
        <h1>Inspection Report</h1>
        <p class="meta"><strong>Client:</strong> \(inspection.clientName)</p>
        \(emailPhoneMeta)
        <p class="meta"><strong>Property:</strong> \(inspection.propertyAddress)</p>
        <p class="meta"><strong>Date:</strong> \(htmlDateFormatter.string(from: inspection.inspectionDate))</p>
        <p class="meta"><strong>Inspector:</strong> \(inspection.inspectorName)</p>
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
                html += "<li>\(scan.usdzFileName) — \(htmlDateFormatter.string(from: scan.capturedAt))</li>"
            }
            html += "</ul><p class=\"meta\">3D models (USDZ) are saved with this inspection.</p></div>"
        }

        // Videos (drone / footage)
        if !inspection.videos.isEmpty {
            html += "<div class=\"card\"><h2 class=\"section-title\">Videos (drone / footage)</h2>"
            for video in inspection.videos {
                let label = video.caption.isEmpty ? video.fileName : video.caption
                if videosFolderURL != nil {
                    let relPath = "videos/\(video.fileName)"
                    html += "<p><a href=\"\(relPath)\" target=\"_blank\">\(label)</a> \(video.source ?? "")</p>"
                } else {
                    html += "<p class=\"meta\">\(label) \(video.source ?? "")</p>"
                }
            }
            html += "</div>"
        }

        for section in inspection.sections {
            let defectItems = section.items.filter(\.isDefect)
            guard !defectItems.isEmpty else { continue }
            html += "<h2 class=\"section-title\">\(section.title)</h2>"
            for item in defectItems {
                guard let severity = item.defectSeverity else { continue }
                var imagesHTML = ""
                for photo in item.photos {
                    if let data = loadPhotoData(jobId: jobId, fileName: photo.fileName),
                       let reportData = AnnotationBakeService.bakedImageData(jobId: jobId, photo: photo, photoData: data) {
                        if let folder = imageFolderURL {
                            let fileURL = folder.appendingPathComponent("\(photo.id.uuidString).png")
                            try? reportData.write(to: fileURL)
                            imagesHTML += "<img class=\"photo\" src=\"images/\(photo.id.uuidString).png\" alt=\"\" loading=\"lazy\"/>"
                        } else {
                            imagesHTML += "<img class=\"photo\" src=\"data:image/png;base64,\(reportData.base64EncodedString())\" alt=\"\" loading=\"lazy\"/>"
                        }
                    }
                }
                html += """
                <div class="card item-card \(severity.rawValue.lowercased())">
                <h3>\(item.title) <span class="badge \(severity.rawValue.lowercased())">\(severity.rawValue)</span></h3>
                <p><strong>Observed:</strong> \(item.observed)</p>
                <p><strong>Implication:</strong> \(item.implication)</p>
                <p><strong>Recommendation:</strong> \(item.recommendation)</p>
                \(imagesHTML)
                </div>
                """
            }
        }

        if !inspection.signatures.isEmpty {
            html += "<div class=\"card signatures\"><h2 class=\"section-title\">Signatures</h2>"
            for sig in inspection.signatures {
                if let data = sig.loadImageData(jobId: jobId) {
                    let base64 = data.base64EncodedString()
                    html += "<p><strong>\(sig.name)</strong> — \(htmlDateFormatter.string(from: sig.date))<br/><img src=\"data:image/png;base64,\(base64)\" alt=\"Signature\"/></p>"
                }
            }
            html += "</div>"
        }

        html += "<div class=\"footer\">"
        if let hash = reportHash {
            html += "Report hash (SHA-256): <span class=\"hash\">\(hash)</span>"
        } else if isDraft {
            html += "This is a draft. Finalized reports include a verification hash."
        }
        html += "</div></div></body></html>"
        return html
    }
}

private let htmlDateFormatter = DateFormatters.mediumDateTime

private func loadPhotoData(jobId: UUID, fileName: String) -> Data? {
    let url = FilePaths.photosFolder(jobId: jobId).appendingPathComponent(fileName)
    return try? Data(contentsOf: url)
}
