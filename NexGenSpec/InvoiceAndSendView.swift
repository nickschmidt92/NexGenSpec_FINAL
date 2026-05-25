//
//  InvoiceAndSendView.swift
//  NexGenSpec
//
//  Post-finalize: customer contact, report link/PDF, invoice form, send to the
//  client (CC the inspector's own profile email and any selected agents).
//

import SwiftUI
import MessageUI

struct InvoiceAndSendView: View {
    let version: InspectionVersion
    @StateObject private var exportService = ReportExportService()
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @ObservedObject private var profile = InspectorProfile.shared

    @State private var invoicePrice = ""
    @State private var additionalServices = ""
    @State private var invoiceTotal = ""
    @State private var showMailCompose = false
    @State private var exportedPDFURL: URL?
    @State private var mailUnavailableAlert = false
    @State private var showExportError = false
    @State private var showPaywall = false
    @State private var showLargePDFWarning = false
    @State private var ccBuyersAgent: Bool = false
    @State private var ccListingAgent: Bool = false
    // Persisted per-inspection via UserDefaults (keyed by inspectionId).
    // Avoids touching the Inspection model mid-TestFlight, which would
    // force a JSON migration for every existing draft on disk. These
    // are soft metadata — safe to lose if reinstalled.
    @State private var invoiceSentAt: Date?
    @State private var invoicePaidAt: Date?

    private var sentAtKey: String { "invoice.sentAt.\(version.inspection.inspectionId)" }
    private var paidAtKey: String { "invoice.paidAt.\(version.inspection.inspectionId)" }

    /// Once the invoice has been emailed to the client, the dollar amounts and
    /// services description are locked. Editing them after send would let the
    /// inspector show a different invoice in-app than the one the client
    /// received — i.e. an audit-trail break (T-01384).
    private var isInvoiceLocked: Bool { invoiceSentAt != nil }

    var body: some View {
        Form {
            Section(header: Text("Customer Contact")) {
                LabeledContent("Name", value: version.inspection.clientName)
                LabeledContent("Email", value: version.inspection.clientEmail.isEmpty ? "—" : version.inspection.clientEmail)
                LabeledContent("Phone", value: version.inspection.clientPhone.isEmpty ? "—" : version.inspection.clientPhone)
                if !profile.companyName.isEmpty {
                    LabeledContent("Company", value: profile.companyName)
                }
            }
            // Optional CC recipients — if the inspection has buyer's /
            // listing agent emails saved, surface toggles so the inspector
            // can loop them in without having to type the address again.
            if !buyersAgentEmail.isEmpty || !listingAgentEmail.isEmpty {
                Section(
                    header: Text("CC on Invoice (optional)"),
                    footer: Text("Adds the selected agent(s) as CC on the invoice email.")
                ) {
                    if !buyersAgentEmail.isEmpty {
                        Toggle(isOn: $ccBuyersAgent) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Buyer's Agent")
                                Text(buyersAgentEmail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !listingAgentEmail.isEmpty {
                        Toggle(isOn: $ccListingAgent) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Listing Agent")
                                Text(listingAgentEmail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
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
            Section {
                HStack(spacing: 2) {
                    Text("$")
                    TextField("Price", text: $invoicePrice)
                        .keyboardType(.decimalPad)
                        .decimalFiltered($invoicePrice)
                }
                TextField("Additional services", text: $additionalServices, axis: .vertical)
                    .lineLimit(3...6)
                HStack(spacing: 2) {
                    Text("$")
                    TextField("Total", text: $invoiceTotal)
                        .keyboardType(.decimalPad)
                        .decimalFiltered($invoiceTotal)
                }
            } header: {
                Text("Invoice")
            } footer: {
                if isInvoiceLocked {
                    Text("Locked after the invoice was emailed to the client.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isInvoiceLocked)
            // Legal / liability disclaimer — NexGenSpec is a reporting
            // tool, not a payment processor. Client pays the inspector
            // directly via whatever method the two agree on outside
            // the app. Called out explicitly before the Send button so
            // the tester can't miss it. Matches the beta feedback
            // "I don't want to be liable for payments".
            Section(
                header: Text("Payment"),
                footer: Text("NexGenSpec does not process payments. Payment is collected directly by the inspector (check, card, Zelle, cash, etc.) outside the app. This invoice is for recordkeeping only.")
                    .font(.footnote)
            ) {
                if let sentAt = invoiceSentAt {
                    LabeledContent("Invoice Sent") {
                        Text(sentAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.green)
                    }
                }
                if let paidAt = invoicePaidAt {
                    LabeledContent("Marked Paid") {
                        Text(paidAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.green)
                    }
                }
            }
            Section {
                Button {
                    sendInvoiceTapped()
                } label: {
                    Label(
                        invoiceSentAt == nil
                            ? "Send Invoice to Client"
                            : "Resend Invoice",
                        systemImage: invoiceSentAt == nil ? "envelope.badge" : "arrow.triangle.2.circlepath"
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                if invoiceSentAt != nil {
                    Button {
                        togglePaid()
                    } label: {
                        Label(
                            invoicePaidAt == nil ? "Mark Invoice as Paid" : "Clear Paid Status",
                            systemImage: invoicePaidAt == nil ? "checkmark.seal" : "xmark.seal"
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .foregroundStyle(invoicePaidAt == nil ? Color.green : Color.orange)
                }
            }
        }
        .onAppear(perform: loadPersistedState)
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
        // To: the client only. NexGenSpec is the tool, not the inspector of
        // record — it must never be a recipient on a client-facing report.
        // The inspector keeps their own copy via the CC below (their profile
        // email) plus their mail account's Sent folder. If the client email
        // is blank the composer still opens so the inspector can type it.
        let recipients = [version.inspection.clientEmail].filter { !$0.isEmpty }
        MailComposeView(
            toRecipients: recipients,
            ccRecipients: ccEmails,
            subject: invoiceSubject,
            body: invoiceEmailHTML,
            isHTML: true,
            attachmentURL: exportedPDFURL,
            extraAttachmentURLs: lidarUSDZAttachmentURLs(),
            onDismiss: { showMailCompose = false },
            onResult: { result in
                if result == .sent {
                    let now = Date()
                    invoiceSentAt = now
                    UserDefaults.standard.set(now, forKey: sentAtKey)
                }
            }
        )
    }

    /// Auto-populated CC list: any selected agents, plus the inspector's own
    /// address from their profile so they retain a copy of exactly what the
    /// client received. This replaces the former hardcoded contact@nexgenspec.com
    /// CC — the inspector, not NexGenSpec, is liable for their reports.
    private var ccEmails: [String] {
        var list: [String] = []
        if ccBuyersAgent, !buyersAgentEmail.isEmpty { list.append(buyersAgentEmail) }
        if ccListingAgent, !listingAgentEmail.isEmpty { list.append(listingAgentEmail) }
        let inspectorEmail = profile.email.trimmingCharacters(in: .whitespaces)
        if !inspectorEmail.isEmpty, !list.contains(inspectorEmail) {
            list.append(inspectorEmail)
        }
        return list
    }

    private var buyersAgentEmail: String {
        version.inspection.buyersAgent?.email ?? ""
    }

    private var listingAgentEmail: String {
        version.inspection.listingAgent?.email ?? ""
    }

    /// Subject line prefers the company name over the bare NexGenSpec
    /// wording so clients see the inspector's brand, not ours.
    private var invoiceSubject: String {
        let company = profile.companyName.trimmingCharacters(in: .whitespaces)
        let prefix = company.isEmpty ? "Inspection Report & Invoice" : "\(company) — Inspection Report & Invoice"
        return "\(prefix) – \(version.inspection.clientName)"
    }

    private func togglePaid() {
        if invoicePaidAt == nil {
            let now = Date()
            invoicePaidAt = now
            UserDefaults.standard.set(now, forKey: paidAtKey)
        } else {
            invoicePaidAt = nil
            UserDefaults.standard.removeObject(forKey: paidAtKey)
        }
    }

    private func loadPersistedState() {
        invoiceSentAt = UserDefaults.standard.object(forKey: sentAtKey) as? Date
        invoicePaidAt = UserDefaults.standard.object(forKey: paidAtKey) as? Date
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

        // The client-facing email is the inspector's brand, not ours. Header
        // subtitle and footer use the company name (falling back to the
        // inspector's name) plus the inspector's own contact details — never
        // a NexGenSpec address.
        let brandName = companyName.trimmingCharacters(in: .whitespaces).isEmpty
            ? inspection.inspectorName
            : companyName
        let profileEmail = InspectorProfile.shared.email.trimmingCharacters(in: .whitespaces)
        let profilePhone = InspectorProfile.shared.phone.trimmingCharacters(in: .whitespaces)
        var footerBits: [String] = []
        if !brandName.trimmingCharacters(in: .whitespaces).isEmpty { footerBits.append(brandName) }
        if !profileEmail.isEmpty { footerBits.append(profileEmail) }
        if !profilePhone.isEmpty { footerBits.append(profilePhone) }
        let footerLine = footerBits.joined(separator: " · ")
        let headerSubtitle = brandName.trimmingCharacters(in: .whitespaces).isEmpty
            ? ""
            : "<p style=\"color:rgba(255,255,255,0.85);margin:6px 0 0;font-size:14px;\">\(brandName)</p>"
        let footerHTML = footerLine.isEmpty
            ? ""
            : "<p style=\"margin:0;font-size:12px;color:#999;\">\(footerLine)</p>"

        return """
        <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:600px;margin:0 auto;color:#1a1a1a;">
          <div style="background:linear-gradient(135deg,#0066cc,#00aaff);padding:24px;border-radius:12px 12px 0 0;text-align:center;">
            <h1 style="color:#fff;margin:0;font-size:22px;">Inspection Report &amp; Invoice</h1>
            \(headerSubtitle)
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
            \(footerHTML)
          </div>
        </div>
        """
    }

    private func runExport() {
        exportedPDFURL = nil
        exportService.reset()
        Task {
            await exportService.export(version: version, watermark: !subscriptions.hasFeatureAccess)
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
            await exportService.export(version: version, watermark: !subscriptions.hasFeatureAccess)
            if case .success(_, let pdf?) = exportService.result {
                exportedPDFURL = pdf
                showMailCompose = true
            }
        }
    }
}
