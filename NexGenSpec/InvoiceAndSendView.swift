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
                        .foregroundColor(.secondary)
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
                TextField("Price", text: $invoicePrice)
                    .keyboardType(.decimalPad)
                TextField("Additional services", text: $additionalServices, axis: .vertical)
                    .lineLimit(3...6)
                TextField("Total", text: $invoiceTotal)
                    .keyboardType(.decimalPad)
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
                body: invoiceEmailBody,
                attachmentURL: exportedPDFURL,
                onDismiss: { showMailCompose = false }
            )
        }
    }

    private var invoiceEmailBody: String {
        var lines: [String] = []
        lines.append("Customer contact (from original form)")
        lines.append("Name: \(version.inspection.clientName)")
        lines.append("Email: \(version.inspection.clientEmail)")
        lines.append("Phone: \(version.inspection.clientPhone)")
        lines.append("")
        lines.append("Property: \(version.inspection.propertyAddress)")
        lines.append("Inspection date: \(version.inspection.inspectionDate.formatted(date: .abbreviated, time: .omitted))")
        lines.append("")
        lines.append("Invoice")
        lines.append("Price: \(invoicePrice.isEmpty ? "—" : invoicePrice)")
        if !additionalServices.isEmpty {
            lines.append("Additional services: \(additionalServices)")
        }
        lines.append("Total: \(invoiceTotal.isEmpty ? "—" : invoiceTotal)")
        lines.append("")
        lines.append("Report: See attached PDF (or export from app if not attached).")
        return lines.joined(separator: "\n")
    }

    private func runExport() {
        guard subscriptions.isPro else {
            showPaywall = true
            return
        }
        exportedPDFURL = nil
        exportService.reset()
        Task {
            await exportService.export(version: version)
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
        guard subscriptions.isPro else {
            showPaywall = true
            return
        }
        Task { @MainActor in
            await exportService.export(version: version)
            if case .success(_, let pdf?) = exportService.result {
                exportedPDFURL = pdf
                showMailCompose = true
            }
        }
    }
}
