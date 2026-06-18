//
//  ReportPreviewView.swift
//  NexGenSpec
//
//  Quick PDF preview so inspectors can review before finalizing.
//

import SwiftUI
import PDFKit

struct ReportPreviewView: View {
    let version: InspectionVersion
    /// Whether to stamp the watermark on the preview PDF. Free (non-Pro)
    /// users see a watermarked preview that matches the watermarked export
    /// they'd actually produce, so the preview can't be used as a clean
    /// full-resolution report that bypasses the Pro paywall (B-0074).
    /// Defaults to false so non-gated call sites (e.g. debug screenshots)
    /// render clean.
    var watermark: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var pdfURL: URL?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Generating preview...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Preview Unavailable")
                            .font(.headline)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else if let pdfURL {
                    PDFKitView(url: pdfURL)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle("Report Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await generatePreview()
        }
    }

    @MainActor
    private func generatePreview() async {
        isLoading = true
        errorMessage = nil
        do {
            let url = try await PDFReportRenderer.generatePDF(for: version, watermark: watermark)
            pdfURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
