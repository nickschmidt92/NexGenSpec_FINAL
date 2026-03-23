//
//  PDFReportRenderer.swift
//  InspectIQ
//
//  Created by ChatGPT on 2/5/26.
//

import Foundation
import UIKit
import WebKit

/// Generates PDF reports from inspection data. Prefer generatePDF(fromHTMLFile:baseURL:) when you have
/// an HTML file with images so the PDF is multi-page and images resolve correctly.
enum PDFReportRenderer {

    /// Generates a multi-page PDF from an HTML file (e.g. from report export). Images under baseURL (e.g. images/) resolve correctly.
    /// Main-actor isolated so WKWebView runs on the main thread; callers are switched to main when they await this.
    @MainActor
    static func generatePDF(fromHTMLFile htmlFileURL: URL, baseURL: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
            webView.isOpaque = false
            webView.backgroundColor = .white
            webView.scrollView.backgroundColor = .white
            let holder = Holder(continuation: continuation, webView: webView)
            webView.navigationDelegate = holder
            objc_setAssociatedObject(webView, &holderKey, holder, .OBJC_ASSOCIATION_RETAIN)
            webView.loadFileURL(htmlFileURL, allowingReadAccessTo: baseURL)
            // Timeout: if WKWebView never finishes (e.g. load error not reported), resume after 30s to avoid hanging.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                holder.resumeIfNeeded(returning: nil)
            }
        }
    }

    /// Generates a multi-page PDF from an HTML string rendered inside WKWebView.
    /// Use this for self-contained HTML that embeds its images as data URLs.
    @MainActor
    static func generatePDF(fromHTMLString html: String, baseURL: URL? = nil) async -> URL? {
        await withCheckedContinuation { continuation in
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
            webView.isOpaque = false
            webView.backgroundColor = .white
            webView.scrollView.backgroundColor = .white
            let holder = Holder(continuation: continuation, webView: webView)
            webView.navigationDelegate = holder
            objc_setAssociatedObject(webView, &holderKey, holder, .OBJC_ASSOCIATION_RETAIN)
            webView.loadHTMLString(html, baseURL: baseURL)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                holder.resumeIfNeeded(returning: nil)
            }
        }
    }

    static func generatePDF(fromHTML html: String) -> URL? {
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let printableRect = pageRect.insetBy(dx: 36, dy: 36)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        renderer.setValue(NSValue(cgRect: pageRect), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printableRect), forKey: "printableRect")

        let pdfData = NSMutableData()
        UIGraphicsBeginPDFContextToData(pdfData, pageRect, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for pageIndex in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: pageIndex, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("InspectionReport-\(UUID().uuidString).pdf")
        do {
            try FileSecurity.writeProtected(pdfData as Data, to: url)
            return url
        } catch {
            Diagnostics.logError(context: "Failed to write HTML formatter PDF", error: error)
            return nil
        }
    }

    /// Generates the shipping inspection PDF directly from the model so text and images do not depend on HTML/WebKit rendering.
    static func generatePDF(for version: InspectionVersion) -> URL? {
        let inspection = version.inspection
        let counts = inspection.summaryCounts()
        let jobId = UUID(uuidString: inspection.inspectionId) ?? version.id
        let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let margin: CGFloat = 36
        let contentWidth = pageRect.width - (margin * 2)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let titleFont = UIFont.systemFont(ofSize: 24, weight: .bold)
        let headingFont = UIFont.systemFont(ofSize: 18, weight: .semibold)
        let bodyFont = UIFont.systemFont(ofSize: 11, weight: .regular)
        let labelFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
        let smallFont = UIFont.systemFont(ofSize: 10, weight: .regular)

        do {
            let data = renderer.pdfData { context in
                var cursorY: CGFloat = margin

                func beginPage() {
                    context.beginPage()
                    cursorY = margin
                }

                func ensureSpace(_ height: CGFloat) {
                    if cursorY + height > pageRect.height - margin {
                        beginPage()
                    }
                }

                func drawText(_ text: String, font: UIFont, color: UIColor = .black, spacingAfter: CGFloat = 8) {
                    guard !text.isEmpty else { return }
                    let attributed = NSAttributedString(
                        string: text,
                        attributes: [
                            .font: font,
                            .foregroundColor: color
                        ]
                    )
                    let rect = attributed.boundingRect(
                        with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        context: nil
                    ).integral
                    ensureSpace(rect.height + spacingAfter)
                    attributed.draw(
                        with: CGRect(x: margin, y: cursorY, width: contentWidth, height: rect.height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        context: nil
                    )
                    cursorY += rect.height + spacingAfter
                }

                func drawDivider(spacing: CGFloat = 14) {
                    ensureSpace(spacing + 1)
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: margin, y: cursorY))
                    path.addLine(to: CGPoint(x: pageRect.width - margin, y: cursorY))
                    UIColor(white: 0.85, alpha: 1).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                    cursorY += spacing
                }

                func drawImage(_ image: UIImage, caption: String?) {
                    let maxHeight: CGFloat = 220
                    let aspectRatio = max(image.size.width, 1) / max(image.size.height, 1)
                    let width = contentWidth
                    let height = min(maxHeight, width / aspectRatio)
                    ensureSpace(height + (caption?.isEmpty == false ? 22 : 8))
                    image.draw(in: CGRect(x: margin, y: cursorY, width: width, height: height))
                    cursorY += height + 6
                    if let caption, !caption.isEmpty {
                        drawText(caption, font: smallFont, color: .darkGray, spacingAfter: 10)
                    } else {
                        cursorY += 6
                    }
                }

                beginPage()

                drawText("Inspection Report", font: titleFont, spacingAfter: 10)
                drawText("Client: \(inspection.clientName)", font: labelFont, spacingAfter: 4)
                if !inspection.clientEmail.isEmpty {
                    drawText("Email: \(inspection.clientEmail)", font: bodyFont, color: .darkGray, spacingAfter: 3)
                }
                if !inspection.clientPhone.isEmpty {
                    drawText("Phone: \(inspection.clientPhone)", font: bodyFont, color: .darkGray, spacingAfter: 3)
                }
                drawText("Property: \(inspection.propertyAddress)", font: bodyFont, color: .darkGray, spacingAfter: 3)
                drawText("Date: \(DateFormatters.mediumDateTime.string(from: inspection.inspectionDate))", font: bodyFont, color: .darkGray, spacingAfter: 3)
                drawText("Inspector: \(inspection.inspectorName)", font: bodyFont, color: .darkGray, spacingAfter: 10)
                drawText(
                    "Summary - Safety: \(counts.safety)  Major: \(counts.major)  Marginal: \(counts.marginal)  Minor: \(counts.minor)",
                    font: labelFont,
                    color: .black,
                    spacingAfter: 12
                )
                if version.status == .draft {
                    drawText("Draft report - not finalized", font: smallFont, color: .systemRed, spacingAfter: 14)
                }

                for section in inspection.sections {
                    let defectItems = section.items.filter(\.isDefect)
                    guard !defectItems.isEmpty else { continue }

                    drawDivider()
                    drawText(section.title, font: headingFont, spacingAfter: 10)

                    for item in defectItems {
                        let severityText = item.defectSeverity?.rawValue ?? "Defect"
                        let locationText = item.location.isEmpty ? "" : "Location: \(item.location)"

                        drawText("\(item.title) - \(severityText)", font: labelFont, color: .black, spacingAfter: 6)
                        if !locationText.isEmpty {
                            drawText(locationText, font: smallFont, color: .darkGray, spacingAfter: 4)
                        }
                        if !item.observed.isEmpty {
                            drawText("Observed: \(item.observed)", font: bodyFont, spacingAfter: 4)
                        }
                        if !item.implication.isEmpty {
                            drawText("Implication: \(item.implication)", font: bodyFont, spacingAfter: 4)
                        }
                        if !item.recommendation.isEmpty {
                            drawText("Recommendation: \(item.recommendation)", font: bodyFont, spacingAfter: 8)
                        }

                        for photo in item.photos {
                            guard
                                let data = loadPhotoData(jobId: jobId, fileName: photo.fileName),
                                let bakedData = AnnotationBakeService.bakedImageData(jobId: jobId, photo: photo, photoData: data),
                                let image = UIImage(data: bakedData)
                            else { continue }

                            drawImage(image, caption: photo.caption)
                        }

                        cursorY += 8
                    }
                }

                if !inspection.signatures.isEmpty {
                    drawDivider()
                    drawText("Signatures", font: headingFont, spacingAfter: 10)
                    for signature in inspection.signatures {
                        drawText("\(signature.name) - \(DateFormatters.mediumDateTime.string(from: signature.date))", font: smallFont, color: .darkGray, spacingAfter: 6)
                        if
                            let data = signature.loadImageData(jobId: jobId),
                            let image = UIImage(data: data)
                        {
                            drawImage(image, caption: nil)
                        }
                    }
                }
            }

            let url = FileManager.default.temporaryDirectory.appendingPathComponent("InspectionReport-\(UUID().uuidString).pdf")
            try FileSecurity.writeProtected(data, to: url)
            return url
        } catch {
            Diagnostics.logError(context: "Failed to write native inspection PDF", error: error)
            return nil
        }
    }
}

private func loadPhotoData(jobId: UUID, fileName: String) -> Data? {
    let url = FilePaths.photosFolder(jobId: jobId).appendingPathComponent(fileName)
    return try? Data(contentsOf: url)
}

private var holderKey: UInt8 = 0

private final class Holder: NSObject, WKNavigationDelegate {
    let continuation: CheckedContinuation<URL?, Never>
    weak var webView: WKWebView?
    private var didResume = false
    private let lock = NSLock()

    init(continuation: CheckedContinuation<URL?, Never>, webView: WKWebView) {
        self.continuation = continuation
        self.webView = webView
        super.init()
    }

    func resumeIfNeeded(returning url: URL?) {
        lock.lock()
        guard !didResume else { lock.unlock(); return }
        didResume = true
        lock.unlock()
        if let webView {
            objc_setAssociatedObject(webView, &holderKey, nil, .OBJC_ASSOCIATION_RETAIN)
        }
        continuation.resume(returning: url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }

            // Give the page a brief moment to finish layout and image decoding before printing.
            try? await Task.sleep(nanoseconds: 600_000_000)
            await self.exportPDF(from: webView)
        }
    }

    @MainActor
    private func exportPDF(from webView: WKWebView) async {
        _ = try? await webView.evaluateJavaScript("document.fonts ? document.fonts.ready.then(() => true) : true")
        let _ = try? await webView.evaluateJavaScript(
            """
            new Promise(resolve => {
              const images = Array.from(document.images || []);
              if (!images.length) { resolve(true); return; }
              let remaining = images.length;
              const done = () => { remaining -= 1; if (remaining <= 0) resolve(true); };
              images.forEach(img => {
                if (img.complete) { done(); return; }
                img.addEventListener('load', done, { once: true });
                img.addEventListener('error', done, { once: true });
              });
            })
            """
        )

        webView.layoutIfNeeded()

        let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let printFormatter = webView.viewPrintFormatter()
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(printFormatter, startingAtPageAt: 0)
        renderer.setValue(NSValue(cgRect: pageRect), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: pageRect.insetBy(dx: 36, dy: 36)), forKey: "printableRect")
        let pdfData = NSMutableData()
        UIGraphicsBeginPDFContextToData(pdfData, pageRect, nil)
        renderer.prepare(forDrawingPages: NSMakeRange(0, renderer.numberOfPages))
        for i in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("InspectionReport-\(UUID().uuidString).pdf")
        do {
            try FileSecurity.writeProtected(pdfData as Data, to: url)
            resumeIfNeeded(returning: url)
        } catch {
            Diagnostics.logError(context: "Failed to write WKWebView PDF", error: error)
            resumeIfNeeded(returning: nil)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resumeIfNeeded(returning: nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resumeIfNeeded(returning: nil)
    }
}
