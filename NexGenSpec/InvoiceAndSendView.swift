//
//  InvoiceAndSendView.swift
//  NexGenSpec
//
//  Post-finalize: customer contact, report link/PDF, invoice form, send to client and contact@nexgenspec.com.
//

import SwiftUI
import MessageUI

struct InvoiceAndSendView: View {
    let version: InspectionVersion
    @StateObject private var exportService = ReportExportService()
    @EnvironmentObject private var subscriptions: SubscriptionManager

    @State private var invoicePrice = ""
    @State private var additionalServices = ""
    @State private var invoiceTotal = ""
    @State private var showMailCompose = false
    @State private var exportedPDFURL: URL?
    @State private var mailUnavailableAlert = false
    @State private var showExportError = false
    @State private var showPaywall = false
    @State private var showLargePDFWarning = false

    private let nexGenSpecEmail = "contact@nexgenspec.com"

    var body: some View {
        Form {
            Section(header: Text("Customer Contact")) {
                LabeledContent("Name", value: version.inspection.clientName)
                LabeledContent("Email", value: version.inspection.clientEmail.isEmpty ? "—" : version.inspection.clientEmail)
                LabeledContent("Phone", value: version.inspection.clientPhone.isEmpty ? "—" : version.inspection.clientPhone)
            }
            Section(header: Text("Report")) {
                if exportedPDFURL != nil {
                    LabeledContent("PDF", value: "Exported")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        runExport()
                    } label: {
                        Label(exportService.isExporting ? "Exporting…" : "Export PDF", systemImage: "doc.richtext")
                    }
                    .disabled(exportService.isExporting)
                    if exportService.isExporting {
                        Button("Cancel", role: .cancel) {
                            exportService.cancelExport()
                        }
                    }
                }
            }
            Section(header: Text("Invoice")) {
                HStack(spacing: 2) {
                    Text("$")
                    TextField("Price", text: $invoicePrice)
                        .keyboardType(.decimalPad)
                }
                TextField("Additional services", text: $additionalServices, axis: .vertical)
                    .lineLimit(3...6)
                HStack(spacing: 2) {
                    Text("$")
                    TextField("Total", text: $invoiceTotal)
                        .keyboardType(.decimalPad)
                }
            }
            Section {
                Button {
                    sendInvoiceTapped()
                } label: {
                    Label("Send Invoice to Client & NexGenSpec", systemImage: "envelope.badge")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Invoice & Send")
        .onChange(of: exportService.isExporting) { _, isExporting in
            if !isExporting {
                if case .success(_, let pdf?) = exportService.result {
                    exportedPDFURL = pdf
                    // Warn if PDF exceeds 20 MB — email providers may reject large attachments
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: pdf.path),
                       let fileSize = attrs[.size] as? UInt64,
                       fileSize > 20 * 1024 * 1024 {
                        showLargePDFWarning = true
                    }
                }
                if exportService.errorMessage != nil { showExportError = true }
            }
        }
        .sheet(isPresented: $showMailCompose) {
            mailComposeSheet
        }
        .alert("Mail Unavailable", isPresented: $mailUnavailableAlert) {
            Button("OK") {}
        } message: {
            Text("This device is not set up to send email. Add a mail account in Settings.")
        }
        .overlay {
            if exportService.isExporting {
                ProgressView(value: exportService.progress)
                    .padding()
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(subscriptions)
        }
        .alert("Large PDF", isPresented: $showLargePDFWarning) {
            Button("Send Anyway") { }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The exported PDF exceeds 20 MB. Some email providers may reject attachments this large. Consider reducing the number of photos or using a file-sharing link instead.")
        }
        .alert("Export failed", isPresented: $showExportError) {
            Button("OK") { showExportError = false; exportService.reset() }
        } message: {
            if let msg = exportService.errorMessage {
                Text(msg)
            }
        }
        .accessibilityLabel("Invoice and send to client")
        .accessibilityHint("Customer contact, invoice form, and send email with optional PDF")
    }

    @ViewBuilder
    private var mailComposeSheet: some View {
        let recipients = [version.inspection.clientEmail, nexGenSpecEmail].filter { !$0.isEmpty }
        if !recipients.isEmpty {
            MailComposeView(
                toRecipients: recipients,
                subject: "Inspection Report & Invoice – \(version.inspection.clientName)",
                body: invoiceEmailHTML,
                isHTML: true,
                attachmentURL: exportedPDFURL,
                extraAttachmentURLs: lidarUSDZAttachmentURLs(),
                onDismiss: { showMailCompose = false }
            )
        }
    }

    /// Collect USDZ files from any LiDAR scans saved for this inspection so
    /// they ride along with the emailed PDF.
    private func lidarUSDZAttachmentURLs() -> [URL] {
        let jobId = UUID(uuidString: version.inspection.inspectionId) ?? version.id
        let lidarDir = FilePaths.lidarFolder(jobId: jobId)
        return LiDARScanStore.loadScans(jobId: jobId)
            .map { lidarDir.appendingPathComponent($0.usdzFileName) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var invoiceEmailHTML: String {
        let inspection = version.inspection
        let dateStr = inspection.inspectionDate.formatted(date: .abbreviated, time: .omitted)
        let priceDisplay = invoicePrice.isEmpty ? "—" : "$\(invoicePrice)"
        let totalDisplay = invoiceTotal.isEmpty ? "—" : "$\(invoiceTotal)"
        let additionalRow = additionalServices.isEmpty ? "" : """
            <tr><td style="padding:8px 12px;color:#666;">Additional Services</td><td style="padding:8px 12px;text-align:right;">\(additionalServices)</td></tr>
            """
        let companyName = InspectorProfile.shared.companyName
        let inspectorLine = companyName.isEmpty ? inspection.inspectorName : "\(inspection.inspectorName) — \(companyName)"

        return """
        <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:600px;margin:0 auto;color:#1a1a1a;">
          <div style="background:linear-gradient(135deg,#0066cc,#00aaff);padding:24px;border-radius:12px 12px 0 0;text-align:center;">
            <h1 style="color:#fff;margin:0;font-size:22px;">Inspection Report &amp; Invoice</h1>
            <p style="color:rgba(255,255,255,0.85);margin:6px 0 0;font-size:14px;">NexGenSpec</p>
          </div>
          <div style="background:#fff;padding:24px;border:1px solid #e5e7eb;border-top:none;">
            <h2 style="font-size:16px;color:#333;margin:0 0 12px;">Client Details</h2>
            <table style="width:100%;border-collapse:collapse;font-size:14px;">
              <tr><td style="padding:6px 0;color:#666;width:140px;">Name</td><td>\(inspection.clientName)</td></tr>
              <tr><td style="padding:6px 0;color:#666;">Email</td><td>\(inspection.clientEmail)</td></tr>
              <tr><td style="padding:6px 0;color:#666;">Phone</td><td>\(inspection.clientPhone)</td></tr>
              <tr><td style="padding:6px 0;color:#666;">Property</td><td>\(inspection.propertyAddress)</td></tr>
              <tr><td style="padding:6px 0;color:#666;">Date</td><td>\(dateStr)</td></tr>
              <tr><td style="padding:6px 0;color:#666;">Inspector</td><td>\(inspectorLine)</td></tr>
            </table>
            <hr style="border:none;border-top:1px solid #e5e7eb;margin:20px 0;">
            <h2 style="font-size:16px;color:#333;margin:0 0 12px;">Invoice</h2>
            <table style="width:100%;border-collapse:collapse;font-size:14px;background:#f8f9fa;border-radius:8px;">
              <tr><td style="padding:8px 12px;color:#666;">Inspection Fee</td><td style="padding:8px 12px;text-align:right;font-weight:600;">\(priceDisplay)</td></tr>
              \(additionalRow)
              <tr style="border-top:2px solid #0066cc;"><td style="padding:10px 12px;font-weight:700;">Total</td><td style="padding:10px 12px;text-align:right;font-weight:700;color:#0066cc;font-size:16px;">\(totalDisplay)</td></tr>
            </table>
            <p style="margin:20px 0 0;font-size:13px;color:#666;">The full inspection report is attached as a PDF. If no attachment is present, please request it from your inspector.</p>
          </div>
          <div style="background:#f8f9fa;padding:16px;border-radius:0 0 12px 12px;border:1px solid #e5e7eb;border-top:none;text-align:center;">
            <p style="margin:0;font-size:12px;color:#999;">Generated by NexGenSpec · contact@nexgenspec.com</p>
          </div>
        </div>
        """
    }

    private func runExport() {
        exportedPDFURL = nil
        exportService.reset()
        Task {
            await exportService.export(version: version, watermark: !subscriptions.isPro)
        }
    }

    private func sendInvoiceTapped() {
        guard MFMailComposeViewController.canSendMail() else {
            mailUnavailableAlert = true
            return
        }
        if exportedPDFURL != nil {
            showMailCompose = true
            return
        }
        Task { @MainActor in
            await exportService.export(version: version, watermark: !subscriptions.isPro)
            if case .success(_, let pdf?) = exportService.result {
                exportedPDFURL = pdf
                showMailCompose = true
            }
        }
    }
}
