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
            let url = try await PDFReportRenderer.generatePDF(for: version, watermark: false)
            pdfURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
