//
//  PDFReportRenderer.swift
//  NexGenSpec
//
//  Single PDF generation path.
//  HTML is the source of truth; PDF is derived from HTML via WKWebView.pdf(configuration:).
//  Never uses UIPrintPageRenderer / UIMarkupTextPrintFormatter (OOM on photo-heavy reports).
//

import Foundation
import UIKit
import WebKit

public enum PDFRenderError: LocalizedError {
    case htmlLoadFailed
    case pdfCreationFailed(Error)
    case timeout
    case memoryPressure
    case writeFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .htmlLoadFailed:         return "Report HTML failed to load in the renderer."
        case .pdfCreationFailed(let e): return "PDF generation failed: \(e.localizedDescription)"
        case .timeout:                return "PDF generation timed out."
        case .memoryPressure:         return "Not enough free memory to generate PDF. Use HTML export instead."
        case .writeFailed(let e):     return "Could not write PDF file: \(e.localizedDescription)"
        }
    }
}

public enum PDFReportRenderer {

    /// Preferred entrypoint. Renders the version's HTML to a temp folder (with images on disk, not base64)
    /// and produces a paginated PDF using WKWebView.pdf(configuration:).
    /// Throws on failure so callers can fall back to the HTML file.
    @MainActor
    public static func generatePDF(for version: InspectionVersion, watermark: Bool = false) async throws -> URL {
        let reportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-\(version.id.uuidString)", isDirectory: true)
        let imagesDir = reportDir.appendingPathComponent("images", isDirectory: true)

        if FileManager.default.fileExists(atPath: reportDir.path) {
            try? FileManager.default.removeItem(at: reportDir)
        }
        try FileSecurity.ensureProtectedDirectory(imagesDir)

        // Render HTML off the main actor. Images are streamed to disk so we never hold
        // all photo bytes in memory simultaneously.
        let versionCopy = version
        let wm = watermark
        let html: String = await Task.detached(priority: .userInitiated) {
            HTMLReportRenderer.renderHTML(
                for: versionCopy,
                imageFolderURL: imagesDir,
                // PDF renders videos as plain-text labels only (never reads the
                // files), so copying the video bytes here was pure wasted disk
                // I/O on video-heavy inspections. The ZIP export path still
                // passes a real folder because it bundles the actual videos.
                videosFolderURL: nil,
                watermark: wm
            )
        }.value

        let indexURL = reportDir.appendingPathComponent("index.html")
        do {
            try FileSecurity.writeProtected(Data(html.utf8), to: indexURL)
        } catch {
            throw PDFRenderError.writeFailed(error)
        }

        return try await generatePDF(fromHTMLFile: indexURL, baseURL: reportDir, clientName: version.inspection.clientName)
    }

    /// Low-level: render an existing HTML file (with sibling asset folder) to a PDF.
    /// Memory-safe path using WKWebView.pdf(configuration:) (iOS 14+).
    /// `clientName` is used for the output filename; pass nil to fall back to a UUID-based name.
    @MainActor
    public static func generatePDF(fromHTMLFile htmlFileURL: URL, baseURL: URL, clientName: String? = nil) async throws -> URL {
        // Pre-flight: refuse to spin up WebKit if we're already under memory pressure.
        if availableMemoryBytes() < 120 * 1024 * 1024 {
            Diagnostics.logError(
                context: "PDFReportRenderer aborted: low memory",
                error: PDFRenderError.memoryPressure
            )
            throw PDFRenderError.memoryPressure
        }

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white

        let coordinator = LoadCoordinator()
        webView.navigationDelegate = coordinator

        // Load from file with read access scoped to the report folder so images resolve.
        webView.loadFileURL(htmlFileURL, allowingReadAccessTo: baseURL)

        // Wait for navigation to finish (or timeout). LoadCoordinator guarantees exactly-once resume.
        try await coordinator.waitForLoad(timeout: .seconds(60))

        // Let fonts + images settle before snapshotting. Best-effort.
        _ = try? await webView.evaluateJavaScript(
            "document.fonts ? document.fonts.ready.then(() => true) : true"
        )
        _ = try? await webView.evaluateJavaScript(
            """
            new Promise(resolve => {
              const imgs = Array.from(document.images || []);
              if (!imgs.length) { resolve(true); return; }
              let remaining = imgs.length;
              const done = () => { if (--remaining <= 0) resolve(true); };
              imgs.forEach(img => {
                if (img.complete) { done(); return; }
                img.addEventListener('load', done, { once: true });
                img.addEventListener('error', done, { once: true });
              });
            })
            """
        )
        webView.layoutIfNeeded()

        // Produce the PDF using Apple's supported API. The HTML's @page CSS drives pagination.
        let pdfData: Data
        do {
            pdfData = try await webView.pdf(configuration: WKPDFConfiguration())
        } catch {
            Diagnostics.logError(context: "WKWebView.pdf failed", error: error)
            throw PDFRenderError.pdfCreationFailed(error)
        }

        let sanitizedClient = Self.sanitizeFilenameComponent(clientName ?? "")
        let dateStamp = Self.filenameDateFormatter.string(from: Date())
        let filenameStem: String
        if sanitizedClient.isEmpty {
            filenameStem = "InspectionReport_\(dateStamp)"
        } else {
            filenameStem = "InspectionReport_\(sanitizedClient)_\(dateStamp)"
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filenameStem).pdf")
        do {
            try FileSecurity.writeProtected(pdfData, to: outURL)
        } catch {
            Diagnostics.logError(context: "PDF write failed", error: error)
            throw PDFRenderError.writeFailed(error)
        }
        return outURL
    }

    // MARK: - Filename helpers

    private static let filenameDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    /// Replaces spaces and non-alphanumeric characters with underscores, then collapses runs.
    private static func sanitizeFilenameComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let cleaned = raw.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
        // Collapse consecutive underscores and trim leading/trailing underscores
        return cleaned
            .replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    // MARK: - Memory

    /// Best-effort estimate of free memory available to this process.
    /// Returns .max on query failure so we never block on unknown state.
    private static func availableMemoryBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return .max }
        let limit = ProcessInfo.processInfo.physicalMemory
        let used = UInt64(info.phys_footprint)
        return used < limit ? (limit - used) : 0
    }
}

// MARK: - Load coordinator

/// Ensures the load continuation is resumed exactly once across both the didFinish callback
/// and the timeout task. Prevents CheckedContinuation leaks that crash in Swift concurrency.
@MainActor
private final class LoadCoordinator: NSObject, WKNavigationDelegate {

    private var continuation: CheckedContinuation<Void, Error>?
    private var didResume = false

    func waitForLoad(timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resume(throwing: PDFRenderError.timeout)
            }
        }
    }

    private func resume() {
        guard !didResume, let c = continuation else { return }
        didResume = true
        continuation = nil
        c.resume()
    }

    private func resume(throwing error: Error) {
        guard !didResume, let c = continuation else { return }
        didResume = true
        continuation = nil
        c.resume(throwing: error)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in self?.resume() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.resume(throwing: PDFRenderError.htmlLoadFailed) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.resume(throwing: PDFRenderError.htmlLoadFailed) }
    }
}
