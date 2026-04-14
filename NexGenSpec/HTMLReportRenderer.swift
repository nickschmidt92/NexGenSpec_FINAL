//
//  HTMLReportRenderer.swift
//  NexGenSpec
//
//  HTML report with card layout, summary, and report hash footer. Run on background for large exports.
//

import Foundation
import UIKit
import ImageIO
import CoreImage

/// Generates HTML for inspection report. For 300+ photos, call from background queue.
/// If imageFolderURL is set, images are written there and HTML references them (reduces memory for large reports).
enum HTMLReportRenderer {

    private static let reportIdDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    static func renderHTML(
        for version: InspectionVersion,
        imageFolderURL: URL? = nil,
        videosFolderURL: URL? = nil,
        absoluteAssetFileURLs: Bool = false,
        watermark: Bool = false
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

        // Embed company logo (or fallback to app icon) as base64 for report header
        let customLogo = InspectorProfile.shared.companyLogoBase64
        let logoBase64: String = customLogo ?? {
            if let asset = UIImage(named: "AppIcon"),
               let data = asset.pngData() {
                return data.base64EncodedString()
            }
            if let url = Bundle.main.url(forResource: "AppIcon60x60@2x", withExtension: "png"),
               let data = try? Data(contentsOf: url) {
                return data.base64EncodedString()
            }
            return ""
        }()
        let logoAlt = customLogo != nil ? escapeHTML(InspectorProfile.shared.companyName.isEmpty ? "Company Logo" : InspectorProfile.shared.companyName) : "NexGenSpec"
        let logoLabel = customLogo != nil ? escapeHTML(InspectorProfile.shared.companyName) : "NexGenSpec"

        // NexGenSpecLogo for cover page (prefer bundle asset, fall back to company logo / app icon)
        let coverLogoBase64: String = {
            if let ngsLogo = UIImage(named: "NexGenSpecLogo"),
               let data = ngsLogo.pngData() {
                return data.base64EncodedString()
            }
            return logoBase64
        }()

        // Build report ID for cover page
        let coverReportId: String? = {
            if let hash = reportHash {
                let datePart = Self.reportIdDateFormatter.string(from: Date())
                let shortHash = String(hash.prefix(4)).uppercased()
                return "NGS-\(datePart)-\(shortHash)"
            }
            return nil
        }()

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
        .free-watermark { position: fixed; top: 50%; left: 50%; transform: translate(-50%,-50%) rotate(-30deg); font-size: 56px; font-weight: 900; color: rgba(0,100,200,0.10); pointer-events: none; z-index: 9999; letter-spacing: 4px; white-space: nowrap; }
        .free-banner { background: linear-gradient(135deg, #0066cc, #00aaff); color: #fff; text-align: center; padding: 10px 16px; border-radius: var(--radius); margin-bottom: 16px; font-size: 0.9rem; font-weight: 600; }
        .container { position: relative; z-index: 1; max-width: 900px; margin: 0 auto; }
        .card { background: #fff; border-radius: var(--radius); box-shadow: var(--card-shadow); padding: 20px; margin-bottom: 20px; }
        .header-card { margin-bottom: 24px; border-top: 4px solid #0066cc; }
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
        .item-card .photo { display: block; max-width: 100%; width: 5in; height: auto; border-radius: 8px; margin-top: 8px; page-break-inside: avoid; break-inside: avoid; }
        .signatures { margin-top: 24px; }
        .signatures img { max-width: 200px; height: auto; border: 1px solid #dee2e6; border-radius: 8px; }
        .footer { margin-top: 32px; padding: 16px 20px; border-top: 2px solid #dee2e6; font-size: 0.8rem; color: #666; background: #f8f9fa; border-radius: 0 0 var(--radius) var(--radius); }
        .footer .hash-label { font-weight: 600; color: #444; margin-bottom: 4px; }
        .footer .hash { font-family: ui-monospace, monospace; word-break: break-all; font-size: 0.7rem; color: #888; background: #eef1f5; padding: 6px 10px; border-radius: 6px; display: block; margin-top: 4px; letter-spacing: 0.5px; }
        .cover-page { page-break-after: always; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 95vh; text-align: center; position: relative; padding: 60px 40px; }
        .cover-page::before { content: ''; position: absolute; top: 0; left: 0; right: 0; height: 6px; background: linear-gradient(90deg, #1F6EF5, #26D1EE); border-radius: 3px 3px 0 0; }
        .cover-page::after { content: ''; position: absolute; bottom: 0; left: 0; right: 0; height: 6px; background: linear-gradient(90deg, #26D1EE, #1F6EF5); border-radius: 0 0 3px 3px; }
        .cover-border { position: absolute; top: 0; left: 0; right: 0; bottom: 0; border: 2px solid transparent; border-image: linear-gradient(180deg, #1F6EF5, #26D1EE) 1; pointer-events: none; }
        .cover-logo { width: 120px; height: 120px; object-fit: contain; margin-bottom: 32px; border-radius: 20px; }
        .cover-title { font-size: 2.2rem; font-weight: 800; color: #1a1a1a; margin: 0 0 8px; letter-spacing: -0.5px; }
        .cover-subtitle { font-size: 1.1rem; font-weight: 500; color: #1F6EF5; margin: 0 0 48px; text-transform: uppercase; letter-spacing: 2px; }
        .cover-address { font-size: 1.6rem; font-weight: 700; color: #1a1a1a; margin: 0 0 40px; line-height: 1.3; }
        .cover-details { list-style: none; padding: 0; margin: 0 0 40px; }
        .cover-details li { font-size: 1.05rem; color: #444; padding: 6px 0; }
        .cover-details li strong { color: #1a1a1a; }
        .cover-report-id { font-family: ui-monospace, monospace; font-size: 0.85rem; color: #888; background: #f0f4f8; padding: 8px 20px; border-radius: 8px; display: inline-block; letter-spacing: 1px; }
        @media print {
          html, body { background: #fff !important; color: #111 !important; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
          .card { background: #fff !important; box-shadow: none !important; break-inside: avoid-page; page-break-inside: avoid; }
          .meta, .footer { color: #555 !important; }
          .badge { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
          .cover-page { min-height: 100vh; }
        }
        </style>
        </head>
        <body>
        \(isDraft ? "<div class=\"draft-watermark\">DRAFT — NOT FINAL</div>" : "")
        \(watermark ? "<div class=\"free-watermark\">NEXGENSPEC FREE</div>" : "")
        <div class="container">
        <div class="cover-page">
        <div class="cover-border"></div>
        \(!coverLogoBase64.isEmpty ? "<img class=\"cover-logo\" src=\"data:image/png;base64,\(coverLogoBase64)\" alt=\"NexGenSpec\"/>" : "")
        <h1 class="cover-title">Inspection Report</h1>
        <p class="cover-subtitle">Property Inspection</p>
        <p class="cover-address">\(escapeHTML(inspection.propertyAddress))</p>
        <ul class="cover-details">
        <li><strong>Client:</strong> \(escapeHTML(inspection.clientName))</li>
        <li><strong>Inspector:</strong> \(escapeHTML(inspection.inspectorName))\(!InspectorProfile.shared.companyName.isEmpty ? " — \(escapeHTML(InspectorProfile.shared.companyName))" : "")</li>
        <li><strong>Date:</strong> \(htmlDateFormatter.string(from: inspection.inspectionDate))</li>
        </ul>
        \(coverReportId != nil ? "<div class=\"cover-report-id\">\(coverReportId!)</div>" : "")
        </div>
        \(watermark ? "<div class=\"free-banner\">Generated with NexGenSpec Free — Upgrade to Pro for clean, branded reports</div>" : "")
        <div class="card header-card">
        \(!logoBase64.isEmpty ? "<div style=\"display:flex;align-items:center;gap:12px;margin-bottom:12px;\"><img src=\"data:image/png;base64,\(logoBase64)\" style=\"width:48px;height:48px;border-radius:10px;object-fit:contain;\" alt=\"\(logoAlt)\"/>\(!logoLabel.isEmpty ? "<span style=\"font-size:1.1rem;font-weight:700;color:#0066cc;\">\(logoLabel)</span>" : "")</div>" : "")
        <h1>Inspection Report</h1>
        <p class="meta"><strong>Client:</strong> \(escapeHTML(inspection.clientName))</p>
        \(emailPhoneMeta)
        <p class="meta"><strong>Property:</strong> \(escapeHTML(inspection.propertyAddress))</p>
        <p class="meta"><strong>Date:</strong> \(htmlDateFormatter.string(from: inspection.inspectionDate))</p>
        <p class="meta"><strong>Inspector:</strong> \(escapeHTML(inspection.inspectorName))\(!InspectorProfile.shared.companyName.isEmpty ? " — \(escapeHTML(InspectorProfile.shared.companyName))" : "")\(!InspectorProfile.shared.licenseNumber.isEmpty ? " (License: \(escapeHTML(InspectorProfile.shared.licenseNumber)))" : "")</p>
        <div class="summary">
        <span class="badge safety">Safety: \(counts.safety)</span>
        <span class="badge major">Major: \(counts.major)</span>
        <span class="badge marginal">Marginal: \(counts.marginal)</span>
        <span class="badge minor">Minor: \(counts.minor)</span>
        </div>
        \(Self.renderWeatherAndTimerSection(inspection: inspection))
        </div>
        """

        // Defect Summary page
        html += Self.renderDefectSummary(inspection: inspection, jobId: jobId, imageFolderURL: imageFolderURL, absoluteAssetFileURLs: absoluteAssetFileURLs)

        // Room scans (LiDAR)
        let lidarScans = LiDARScanStore.loadScans(jobId: jobId)
        if !lidarScans.isEmpty {
            let lidarDir = FilePaths.lidarFolder(jobId: jobId)
            html += "<div class=\"card\"><h2 class=\"section-title\">Room scans (LiDAR)</h2>"
            for scan in lidarScans {
                html += "<div style=\"margin-bottom:18px;\">"
                html += "<p class=\"meta\"><strong>\(escapeHTML(scan.displayName))</strong> — \(htmlDateFormatter.string(from: scan.capturedAt))</p>"
                if let pngName = scan.floorplanPNGFileName {
                    let pngURL = lidarDir.appendingPathComponent(pngName)
                    if let pngData = try? Data(contentsOf: pngURL) {
                        let b64 = pngData.base64EncodedString()
                        html += "<img src=\"data:image/png;base64,\(b64)\" alt=\"Floor plan\" style=\"max-width:100%;height:auto;border:1px solid #ccc;border-radius:6px;\" />"
                    }
                }
                html += "</div>"
            }
            html += "<p class=\"meta\">3D models (USDZ) are saved with this inspection.</p></div>"
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
                            let fileURL = folder.appendingPathComponent("\(photo.id.uuidString).jpg")
                            try? FileSecurity.writeProtected(reportData, to: fileURL)
                            let imagePath = absoluteAssetFileURLs ? fileURL.absoluteString : "images/\(photo.id.uuidString).jpg"
                            imagesHTML += "<img class=\"photo\" src=\"\(imagePath)\" alt=\"Inspection photo\"/>"
                        } else {
                            imagesHTML += "<img class=\"photo\" src=\"data:image/jpeg;base64,\(reportData.base64EncodedString())\" alt=\"Inspection photo\"/>"
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
            let datePart = Self.reportIdDateFormatter.string(from: Date())
            let shortHash = String(hash.prefix(4)).uppercased()
            let reportId = "NGS-\(datePart)-\(shortHash)"
            html += "<div style=\"display:flex;align-items:center;gap:16px;\">"
            html += "<div>"
            html += "<div class=\"hash-label\">Report ID</div>"
            html += "<span class=\"hash\">\(reportId)</span>"
            html += "</div>"
            // QR Code
            let verifyURL = "https://nexgenspec.com/verify/\(reportId)"
            if let qrBase64 = Self.generateQRCodeBase64(for: verifyURL) {
                html += "<img src=\"data:image/png;base64,\(qrBase64)\" style=\"width:72px;height:72px;\" alt=\"Verification QR Code\"/>"
            }
            html += "</div>"
        } else if isDraft {
            html += "This is a draft. Finalized reports include a verification hash."
        }
        html += "</div></div></body></html>"
        return html
    }

    // MARK: - Defect Summary Page

    /// Builds an HTML "Defect Summary" section that lists every defect item
    /// across all sections in a table with Room/Section, Description, Severity,
    /// and Photo reference columns.  Uses `page-break-after` so it prints on
    /// its own page.
    private static func renderDefectSummary(
        inspection: Inspection,
        jobId: UUID,
        imageFolderURL: URL?,
        absoluteAssetFileURLs: Bool
    ) -> String {
        struct DefectRow {
            let section: String
            let title: String
            let observed: String
            let severity: Severity
            let photoRef: String      // first photo thumbnail or "—"
            let defectTags: [String]
        }

        var rows: [DefectRow] = []
        for section in inspection.sections {
            for item in section.items where item.isDefect && item.includeInReport {
                guard let sev = item.defectSeverity else { continue }

                // Build a small thumbnail reference for the first photo
                var photoHTML = "—"
                if let firstPhoto = item.photos.first {
                    if let data = loadPhotoData(jobId: jobId, fileName: firstPhoto.fileName),
                       let reportData = AnnotationBakeService.bakedImageData(jobId: jobId, photo: firstPhoto, photoData: data) {
                        if let folder = imageFolderURL {
                            let fileURL = folder.appendingPathComponent("\(firstPhoto.id.uuidString).jpg")
                            // Image may already be written by the main loop; write if missing
                            if !FileManager.default.fileExists(atPath: fileURL.path) {
                                try? FileSecurity.writeProtected(reportData, to: fileURL)
                            }
                            let imagePath = absoluteAssetFileURLs ? fileURL.absoluteString : "images/\(firstPhoto.id.uuidString).jpg"
                            photoHTML = "<img src=\"\(imagePath)\" style=\"width:60px;height:60px;object-fit:cover;border-radius:6px;\" alt=\"Photo\"/>"
                        } else {
                            photoHTML = "<img src=\"data:image/jpeg;base64,\(reportData.base64EncodedString())\" style=\"width:60px;height:60px;object-fit:cover;border-radius:6px;\" alt=\"Photo\"/>"
                        }
                    }
                }

                // Collect defect tags from all photos on this item
                let tags = item.photos.flatMap(\.defectTags)
                let uniqueTags = Array(Set(tags)).sorted()

                rows.append(DefectRow(
                    section: section.title,
                    title: item.title,
                    observed: item.observed,
                    severity: sev,
                    photoRef: photoHTML,
                    defectTags: uniqueTags
                ))
            }
        }

        // If no defects, show a brief note
        guard !rows.isEmpty else {
            return """
            <div class="card defect-summary-page" style="page-break-after:always;">
            <h2 class="section-title" style="color:#0066cc;">Defect Summary</h2>
            <p class="meta" style="padding:24px 0;text-align:center;font-size:1.1rem;">No defects identified in this inspection.</p>
            </div>
            """
        }

        var html = """
        <div class="card defect-summary-page" style="page-break-after:always;">
        <h2 class="section-title" style="color:#0066cc;margin-top:0;">Defect Summary</h2>
        <p class="meta" style="margin-bottom:12px;">\(rows.count) defect\(rows.count == 1 ? "" : "s") identified across all sections.</p>
        <table style="width:100%;border-collapse:collapse;font-size:0.9rem;">
        <thead>
        <tr style="background:#0066cc;color:#fff;text-align:left;">
        <th style="padding:10px 8px;border-radius:8px 0 0 0;">Room / Section</th>
        <th style="padding:10px 8px;">Defect Description</th>
        <th style="padding:10px 8px;">Severity</th>
        <th style="padding:10px 8px;border-radius:0 8px 0 0;">Photo</th>
        </tr>
        </thead>
        <tbody>
        """

        for (index, row) in rows.enumerated() {
            let bgColor = index % 2 == 0 ? "#f8fafd" : "#ffffff"
            let sevColor: String
            switch row.severity {
            case .safety:  sevColor = "#dc3545"
            case .major:   sevColor = "#fd7e14"
            case .marginal: sevColor = "#ffc107"
            case .minor:   sevColor = "#198754"
            }

            var description = escapeHTML(row.title)
            if !row.observed.isEmpty {
                description += "<br/><span style=\"color:#666;font-size:0.85rem;\">\(escapeHTML(row.observed))</span>"
            }
            if !row.defectTags.isEmpty {
                let tagsHTML = row.defectTags.map { tag in
                    "<span style=\"display:inline-block;background:#e8f0fe;color:#1a56db;padding:2px 8px;border-radius:10px;font-size:0.75rem;margin:2px;\">\(escapeHTML(tag))</span>"
                }.joined()
                description += "<br/>\(tagsHTML)"
            }

            html += """
            <tr style="background:\(bgColor);border-bottom:1px solid #eee;">
            <td style="padding:10px 8px;vertical-align:top;font-weight:600;">\(escapeHTML(row.section))</td>
            <td style="padding:10px 8px;vertical-align:top;">\(description)</td>
            <td style="padding:10px 8px;vertical-align:top;"><span style="display:inline-block;padding:4px 10px;border-radius:6px;color:#fff;background:\(sevColor);font-weight:600;font-size:0.85rem;">\(row.severity.rawValue)</span></td>
            <td style="padding:10px 8px;vertical-align:top;text-align:center;">\(row.photoRef)</td>
            </tr>
            """
        }

        html += """
        </tbody>
        </table>
        </div>
        """

        return html
    }

    // MARK: - Weather & Timer Section

    private static func renderWeatherAndTimerSection(inspection: Inspection) -> String {
        var parts: [String] = []

        if let w = inspection.weather {
            parts.append("""
            <div style="display:flex;flex-wrap:wrap;gap:12px;margin-top:16px;padding:12px 16px;background:#f0f7ff;border-radius:8px;font-size:0.9rem;">
            <span style="font-weight:600;color:#0066cc;">Weather at Inspection:</span>
            <span>\(escapeHTML(w.conditions))</span>
            <span>\(escapeHTML(w.temperatureString))</span>
            <span>Humidity: \(escapeHTML(w.humidityString))</span>
            <span>Wind: \(escapeHTML(w.windSpeedString))</span>
            </div>
            """)
        }

        if inspection.timerElapsedSeconds > 0 {
            let total = Int(inspection.timerElapsedSeconds)
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            let seconds = total % 60
            let timeStr = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            parts.append("""
            <p class="meta" style="margin-top:8px;"><strong>Total Inspection Time:</strong> \(timeStr)</p>
            """)
        }

        return parts.joined()
    }

    // MARK: - QR Code Generation

    /// Generates a QR code image for the given string and returns it as a base64-encoded PNG.
    static func generateQRCodeBase64(for string: String) -> String? {
        guard let data = string.data(using: .ascii) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up from the tiny native size (~23x23) to ~288x288
        let scale = 288.0 / ciImage.extent.width
        let transformed = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        guard let pngData = uiImage.pngData() else { return nil }
        return pngData.base64EncodedString()
    }
}

private let htmlDateFormatter = DateFormatters.mediumDateTime

/// Loads photo data downsampled to a max dimension of 1024px to prevent OOM on 48MP+ images.
private func loadPhotoData(jobId: UUID, fileName: String) -> Data? {
    let url = FilePaths.photosFolder(jobId: jobId).appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return nil
    }
    let maxPixelSize: CGFloat = 1024
    let options: [CFString: Any] = [
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    let uiImage = UIImage(cgImage: cgImage)
    return uiImage.jpegData(compressionQuality: 0.6)
}

private func escapeHTML(_ input: String) -> String {
    input
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}
