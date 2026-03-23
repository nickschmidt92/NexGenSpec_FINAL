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

    /// Fallback: generates a single-page PDF from version (can truncate long reports). Use export’s HTML file when possible.
    static func generatePDF(for version: InspectionVersion) -> URL? {
        let html = HTMLReportRenderer.renderHTML(for: version)
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            formatter.draw(in: ctx.pdfContextBounds, forPageAt: 0)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("InspectionReport-\(UUID().uuidString).pdf")
        do {
            try FileSecurity.writeProtected(data, to: url)
            return url
        } catch {
            Diagnostics.logError(context: "Failed to write fallback PDF", error: error)
            return nil
        }
    }
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
