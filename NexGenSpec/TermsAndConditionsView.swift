import SwiftUI
import UIKit
import PDFKit

/// Displays the Terms and Conditions / Inspection Agreement in a readable format.
///
/// This view supports both modal usage with an acknowledgment callback (e.g. "Accept Terms & Continue")
/// and readonly usage where no acknowledgment is needed (e.g. sidebar or reference panel).
public struct TermsAndConditionsView: View {
    @State private var showShareSheet = false
    @State private var showAuditLogSheet = false
    @State private var searchText: String = ""
    
    /// Optional callback invoked when user acknowledges terms.
    /// If `nil`, no accept button is shown and view is readonly.
    @Binding public var onAcknowledge: (() -> Void)?
    
    /// Initializes the view.
    /// - Parameter onAcknowledge: Binding to optional callback to invoke on acknowledge. Defaults to `.constant(nil)`.
    public init(onAcknowledge: Binding<(() -> Void)?> = .constant(nil)) {
        self._onAcknowledge = onAcknowledge
    }
    
    public var body: some View {
        AppScreenBackground {
            VStack(spacing: 0) {
                VStack(spacing: Spacing.sm) {
                    VStack(spacing: Spacing.sm) {
                        BrandLockup(
                            subtitle: "Terms and privacy commitments for NexGenSpec users.",
                            markSize: 60
                        )

                        Text("NexGenSpec is inspection reporting software only. You are responsible for licensing, insurance, and report content. This app is not a marketplace.")
                            .font(AppFont.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(AppColor.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        VStack(spacing: 2) {
                            Text("Effective Date: May 30, 2026 (Terms of Service)")
                            Text("Effective Date: May 30, 2026 (Privacy Policy)")
                        }
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .accessibilityElement(children: .combine)
                        .padding(.top, 4)

                        HStack(spacing: Spacing.sm) {
                            Link(destination: URL(string: "https://nexgenspec.com/privacy.html")!) {
                                TermsQuickLink(title: "Privacy Policy", systemImage: "hand.raised.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("View Privacy Policy")

                            Link(destination: URL(string: "https://nexgenspec.com/terms.html")!) {
                                TermsQuickLink(title: "Terms of Service", systemImage: "doc.text.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("View Terms of Service")
                        }

                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)

                            TextField("Search Terms", text: $searchText)
                                .textFieldStyle(.plain)
                                .accessibilityLabel("Search Terms")

                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 48)
                        .background(AppColor.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(AppColor.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .frame(maxWidth: 920)
                    .padding(.top, Spacing.md)
                    .padding(.horizontal)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                        // PART A — NexGenSpec Terms of Service
                        Group {
                            highlightedText("Terms of Service", id: "title", font: .title.bold(), isHeader: true)
                            highlightedText("These terms govern your use of NexGenSpec, a professional home inspection app for licensed property inspectors, available on the Apple App Store for iPhone and iPad. The app is provided by NexGenSpec LLC (\"we\", \"us\", \"the developer\") to inspectors (\"you\", \"the user\") who have downloaded the app and accepted these Terms.\n", font: .body)

                            highlightedText("1. Account & Subscription", font: .headline, isHeader: true)
                            highlightedText("• An account is required to protect inspection data (client personal information, property photos, defect findings).\n• The app is free to download. Free users may create up to 3 complete inspections with full PDF export. After 3 inspections, a Pro subscription is required to create additional inspections.\n• Pro subscription: $49/month or $449/year. Subscriptions auto-renew unless cancelled at least 24 hours before the end of the current period. Manage subscriptions in iOS Settings → Apple ID → Subscriptions.\n• Payment is processed by Apple. NexGenSpec does not collect payment information directly.\n• Communications. NexGenSpec may email you in connection with your account (e.g. authentication, password resets, subscription receipts, important service or security notices) and, from time to time, regarding new features, updates, deals, or upgrade offers. You may opt out of marketing emails at any time by emailing contact@nexgenspec.com with the word \"unsubscribe\" in the subject line. Transactional and account-related emails will continue regardless of marketing preferences.\n", font: .body)

                            highlightedText("2. Inspector Responsibility", font: .headline, isHeader: true)
                            highlightedText("NexGenSpec is a tool for documenting inspections. The accuracy and completeness of every inspection report is the responsibility of the licensed inspector who creates it. The developer is not responsible for inspection findings, omissions, or any decisions made by the inspector or their clients based on app-generated reports.\n", font: .body)

                            highlightedText("3. Invoice & Payment Collection", font: .headline, isHeader: true)
                            highlightedText("NexGenSpec includes invoice formatting and email-delivery features as a convenience. NexGenSpec does not process payments. Any payment between the inspector and their client is collected directly by the inspector outside the app. The \"Mark Invoice as Paid\" toggle inside the app is a record-keeping aid only.\n", font: .body)

                            highlightedText("4. Data & Privacy", font: .headline, isHeader: true)
                            highlightedText("Inspection data, including photos, defect findings, client information, and signatures, is stored on your device using iOS Data Protection. The only data sent off-device is (a) authentication tokens for sign-in, (b) anonymized crash reports, and (c) when an inspection captures weather, the approximate coordinates of your location, sent to Open-Meteo (open-meteo.com) to fetch current conditions. Inspection content never leaves the device unless you choose to email a PDF report. See our Privacy Policy for full details.\n", font: .body)

                            highlightedText("5. Acceptable Use", font: .headline, isHeader: true)
                            highlightedText("• You agree to use the app for lawful, professional inspection purposes only.\n• You will not attempt to reverse-engineer, decompile, or extract source code from the app.\n• You will not use the app to harass, defame, or harm any third party.\n• You are responsible for maintaining the confidentiality of your account credentials.\n", font: .body)

                            highlightedText("6. Termination", font: .headline, isHeader: true)
                            highlightedText("You may delete your account at any time from inside the app (Settings → Delete Account), which permanently removes your authentication record and all locally stored inspections. We may suspend or terminate accounts that violate these Terms.\n", font: .body)

                            highlightedText("7. Disclaimer of Warranties", font: .headline, isHeader: true)
                            highlightedText("The app is provided \"as is\" without warranties of any kind. We don't guarantee NexGenSpec will be uninterrupted, error-free, or compatible with every iOS version or device. Inspection content is stored on your device, not on a NexGenSpec server. Inspectors are responsible for maintaining their own backups.\n", font: .body)

                            highlightedText("8. Limitation of Liability", font: .headline, isHeader: true)
                            highlightedText("NexGenSpec is software. Our liability is limited to the operation of that software — specifically: app availability, app bugs that cause data loss inside the app, and similar app-level issues.\n\nMaximum remedy. To the maximum extent permitted by law, our total liability to you for any claim arising out of or relating to your use of NexGenSpec is limited to a refund of the subscription fee you paid for the calendar month in which the issue occurred, contingent on (a) you reporting the issue to NexGenSpec LLC in writing within that same calendar month, and (b) you providing reasonable supporting documentation evidencing the issue. No other remedy is available.\n\nWhat NexGenSpec does not cover:\n• The accuracy, completeness, or quality of any inspection report you create. Those are the licensed inspector's professional work product and professional liability.\n• Defects, damages, or losses at a property — whether identified, missed, or misclassified during an inspection.\n• Decisions made by buyers, sellers, agents, lenders, or any other party based on a NexGenSpec-generated report.\n• Third-party services the app integrates with (Apple's iOS, Open-Meteo, StoreKit, Firebase, your email provider, Apple Pay, etc.). Each is governed by its own terms. Weather data provided by Open-Meteo.com (https://open-meteo.com/).\n• Any payment dispute between an inspector and a client. NexGenSpec does not process payments.\n• Loss of inspection data caused by device failure, accidental deletion, OS upgrades, lost or stolen devices, or anything outside our direct control. NexGenSpec does not maintain server-side copies of inspection content and cannot recover it.\n• Indirect, consequential, incidental, special, or punitive damages, including lost revenue, lost profits, lost business opportunities, or loss of goodwill.\n\nOutage refund. If NexGenSpec experiences an extended outage caused by NexGenSpec LLC (and not by Apple, Firebase, your network, your device, or other services outside our control), our maximum responsibility is a pro-rated refund of subscription fees for the duration of the outage. Outages must be reported in writing within the calendar month they occur to qualify.\n", font: .body)

                            highlightedText("9. Governing Law & Venue", font: .headline, isHeader: true)
                            highlightedText("These Terms are governed by the laws of the State of Colorado, USA, without regard to its conflict-of-laws principles. You and NexGenSpec LLC agree that any dispute arising out of or relating to these Terms or the app shall be brought exclusively in the state or federal courts located in Denver, Colorado, and you consent to personal jurisdiction in those courts.\n\nCanadian users: If you are a resident of Canada, the foregoing does not deprive you of any non-waivable consumer-protection rights granted by your province or territory of residence. Where such rights apply, they remain in effect notwithstanding the choice of Colorado law.\n\nYou and NexGenSpec LLC agree that any dispute will be resolved on an individual basis only. Class actions, class arbitrations, and consolidated proceedings are not permitted.\n", font: .body)

                            highlightedText("10. Changes to These Terms", font: .headline, isHeader: true)
                            highlightedText("We may update these Terms from time to time. Material changes will be communicated through the app and require fresh acceptance before continued use.\n", font: .body)

                            highlightedText("11. Contact", font: .headline, isHeader: true)
                            HStack(spacing: 0) {
                                Text("NexGenSpec LLC — ")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Link("contact@nexgenspec.com",
                                     destination: URL(string: "mailto:contact@nexgenspec.com")!)
                                .font(.body)
                                .foregroundColor(.accentColor)
                                .accessibilityLabel("Contact Support Email")
                            }
                            Divider().padding(.top, 12)
                        }
                        .id("title")

                        // PART B — Sample Inspector–Client Agreement (Template)
                        Group {
                            highlightedText("Sample Inspector–Client Agreement (Template)", id: "section1", font: .title2.bold(), isHeader: true)

                            highlightedText("Important Notice", font: .headline, isHeader: true)
                            highlightedText("The sections below are a TEMPLATE you (the inspector) may adapt for use between yourself and your client. NexGenSpec LLC is NOT a party to any inspector-client agreement, has no role in negotiating or enforcing it, and does not retain or guarantee any inspection records on your behalf. By using this template, you agree NexGenSpec LLC is not responsible for its content, suitability, or legal effect. Have your own attorney review before relying on it.\n\nIf the client is not present at the inspection, standard practice is to have the client review and sign this agreement digitally before the inspection (email a copy, use DocuSign, etc.) or include it in your booking confirmation. If the agreement remains unsigned at the time of inspection, document the situation in your notes.\n", font: .body)

                            highlightedText("Section 1 — Inspection Documentation & Digital Media", font: .headline, isHeader: true)
                            highlightedText("By scheduling and permitting this inspection, the client authorizes the Inspector to capture, create, and retain photos, videos, thermal imagery, drone imagery, and 3D/LiDAR scans of the property, where applicable to the scope of this inspection. These records are collected for inspection reporting, internal quality assurance, and to provide a clear, detailed summary of the property's condition.\n\nThe Inspector retains full ownership and custody of all original inspection records. The client receives a copy of the inspection report, which may include selected photos and media as needed for context.\n\nThe Inspector keeps documentation private and uses it only for: this inspection, reporting, dispute resolution, insurance/legal compliance, or other obligations related to this engagement. It will not be shared publicly or with third parties except as required by law or with the client's consent.\n", font: .body)

                            highlightedText("Plain-English Client Summary:", font: .headline, isHeader: true)
                            highlightedText("\"Your inspector takes detailed photos, videos, and (where equipped) 3D, thermal, or drone media to make your inspection report accurate and to protect both parties. The inspector keeps the originals; you get a copy in your report. Your images are private and used only for your inspection, not for marketing or social media.\"\n", font: .body)
                            Divider()
                        }
                        .id("section1")

                        Group {
                            highlightedText("Section 2 — Inspector's Photo & Record Retention Practice", id: "section2", font: .headline, isHeader: true)
                            highlightedText("The Inspector's stated retention practice is:", font: .body)
                            Group {
                                highlightedText("• Retention Period: Original inspection photos, videos, and digital records are retained for at least 5 years — the industry-standard window for claims, complaints, or insurance reviews. Consult your professional liability carrier and licensing board for jurisdiction-specific obligations.", font: .body)
                                highlightedText("• Storage: The Inspector is solely responsible for the security, backup, and retention of these records, using systems of the inspector's choosing.", font: .body)
                                highlightedText("• Backup obligation: The Inspector should regularly export finalized inspections to a long-term backup location (iCloud Drive, an encrypted external drive, a NAS, or another system) immediately after finalization to satisfy this retention practice.", font: .body)
                                highlightedText("• Deletion & Archival: Records may be archived or deleted after the retention period ends, unless a dispute or claim is pending.", font: .body)
                                highlightedText("• No Premature Deletion: The Inspector will not delete originals before the retention period ends except in documented exceptions.", font: .body)
                            }
                            .padding(.leading)
                            highlightedText("\nImportant: NexGenSpec software stores inspection records on the Inspector's device only. NexGenSpec LLC does not host, backup, audit, or guarantee retention of these records, and cannot recover them if the device is lost, factory-reset, has a hardware failure, or has the app uninstalled without an iCloud Backup. The Inspector is fully responsible for backing up records to meet this retention practice (e.g. iCloud Backup + per-inspection export to Files app / iCloud Drive).\n\nEmail delivery and retention. Once a PDF report has been delivered to the client by email, retention of the client's copy is governed entirely by the client's chosen email/storage provider — not by the Inspector and not by NexGenSpec. The Inspector should not rely on a sent email as a long-term archive.\n", font: .body)
                            Divider()
                        }
                        .id("section2")
                    }
                        .padding()
                        .onChange(of: searchText) { _, _ in
                            scrollToFirstMatch(proxy: proxy)
                        }
                        .onAppear {
                            scrollToFirstMatch(proxy: proxy)
                        }
                    }
                    .frame(maxWidth: 920)
                    .padding(.horizontal)
                }
                
                Text("By using NexGenSpec, you agree to the Terms of Service and acknowledge the Privacy Policy.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 8)
                
                if onAcknowledge != nil {
                    Text("You must accept these terms to continue.")
                        .font(.headline)
                        .foregroundColor(AppColor.critical)
                        .padding(.horizontal)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel("You must accept these terms to continue")
                    
                    Button {
                        AuditLog.log(event: "Terms and Conditions accepted")
                        onAcknowledge?()
                    } label: {
                        Text("Accept Terms & Continue")
                    }
                    .buttonStyle(AppPrimaryButtonStyle())
                    .padding([.horizontal, .bottom])
                    .accessibilityLabel("Accept Terms and Continue")
                }
            }
        }
        .navigationTitle("Terms & Conditions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: {
                    // Ensure only one sheet is shown at a time
                    showAuditLogSheet = false
                    showShareSheet = true
                }) {
                    Image(systemName: "square.and.arrow.up")
                        .accessibilityLabel("Share Terms and Conditions")
                }
                Button(action: {
                    // Ensure only one sheet is shown at a time
                    showShareSheet = false
                    showAuditLogSheet = true
                }) {
                    Image(systemName: "doc.plaintext")
                        .accessibilityLabel("Export Audit Log")
                }
            }
        }
        // Prevent simultaneous sheet triggers by explicit logic above
        .sheet(isPresented: $showShareSheet) {
            ActivityView(activityItems: [fullTermsText])
        }
        // Prevent simultaneous sheet triggers by explicit logic above
        .sheet(isPresented: $showAuditLogSheet) {
            ActivityView(activityItems: [AuditLog.read()])
        }
    }

    /// Aggregates all terms text into a single plain text string for sharing.
    public var fullTermsText: String {
        """
        NexGenSpec — Terms of Service & Sample Inspector–Client Agreement
        Effective Date: May 30, 2026

        ============================================================
        PART A — NEXGENSPEC TERMS OF SERVICE
        ============================================================

        These terms govern your use of NexGenSpec, a professional home inspection app for licensed property inspectors, available on the Apple App Store for iPhone and iPad. The app is provided by NexGenSpec LLC ("we", "us", "the developer") to inspectors ("you", "the user") who have downloaded the app and accepted these Terms.

        1. Account & Subscription
        • An account is required to protect inspection data (client personal information, property photos, defect findings).
        • The app is free to download. Free users may create up to 3 complete inspections with full PDF export. After 3 inspections, a Pro subscription is required to create additional inspections.
        • Pro subscription: $49/month or $449/year. Subscriptions auto-renew unless cancelled at least 24 hours before the end of the current period. Manage subscriptions in iOS Settings → Apple ID → Subscriptions.
        • Payment is processed by Apple. NexGenSpec does not collect payment information directly.
        • Communications. NexGenSpec may email you in connection with your account (e.g. authentication, password resets, subscription receipts, important service or security notices) and, from time to time, regarding new features, updates, deals, or upgrade offers. You may opt out of marketing emails at any time by emailing contact@nexgenspec.com with the word "unsubscribe" in the subject line. Transactional and account-related emails will continue regardless of marketing preferences.

        2. Inspector Responsibility
        NexGenSpec is a tool for documenting inspections. The accuracy and completeness of every inspection report is the responsibility of the licensed inspector who creates it. The developer is not responsible for inspection findings, omissions, or any decisions made by the inspector or their clients based on app-generated reports.

        3. Invoice & Payment Collection
        NexGenSpec includes invoice formatting and email-delivery features as a convenience. NexGenSpec does not process payments. Any payment between the inspector and their client is collected directly by the inspector outside the app. The "Mark Invoice as Paid" toggle inside the app is a record-keeping aid only.

        4. Data & Privacy
        Inspection data, including photos, defect findings, client information, and signatures, is stored on your device using iOS Data Protection. The only data sent off-device is (a) authentication tokens for sign-in, (b) anonymized crash reports, and (c) when an inspection captures weather, the approximate coordinates of your location, sent to Open-Meteo (open-meteo.com) to fetch current conditions. Inspection content never leaves the device unless you choose to email a PDF report. See our Privacy Policy for full details.

        5. Acceptable Use
        • You agree to use the app for lawful, professional inspection purposes only.
        • You will not attempt to reverse-engineer, decompile, or extract source code from the app.
        • You will not use the app to harass, defame, or harm any third party.
        • You are responsible for maintaining the confidentiality of your account credentials.

        6. Termination
        You may delete your account at any time from inside the app (Settings → Delete Account), which permanently removes your authentication record and all locally stored inspections. We may suspend or terminate accounts that violate these Terms.

        7. Disclaimer of Warranties
        The app is provided "as is" without warranties of any kind. We don't guarantee NexGenSpec will be uninterrupted, error-free, or compatible with every iOS version or device. Inspection content is stored on your device, not on a NexGenSpec server. Inspectors are responsible for maintaining their own backups.

        8. Limitation of Liability
        NexGenSpec is software. Our liability is limited to the operation of that software — specifically: app availability, app bugs that cause data loss inside the app, and similar app-level issues.

        Maximum remedy. To the maximum extent permitted by law, our total liability to you for any claim arising out of or relating to your use of NexGenSpec is limited to a refund of the subscription fee you paid for the calendar month in which the issue occurred, contingent on (a) you reporting the issue to NexGenSpec LLC in writing within that same calendar month, and (b) you providing reasonable supporting documentation evidencing the issue. No other remedy is available.

        What NexGenSpec does not cover:
        • The accuracy, completeness, or quality of any inspection report you create. Those are the licensed inspector's professional work product and professional liability.
        • Defects, damages, or losses at a property — whether identified, missed, or misclassified during an inspection.
        • Decisions made by buyers, sellers, agents, lenders, or any other party based on a NexGenSpec-generated report.
        • Third-party services the app integrates with (Apple's iOS, Open-Meteo, StoreKit, Firebase, your email provider, Apple Pay, etc.). Each is governed by its own terms. Weather data provided by Open-Meteo.com (https://open-meteo.com/).
        • Any payment dispute between an inspector and a client. NexGenSpec does not process payments.
        • Loss of inspection data caused by device failure, accidental deletion, OS upgrades, lost or stolen devices, or anything outside our direct control. NexGenSpec does not maintain server-side copies of inspection content and cannot recover it.
        • Indirect, consequential, incidental, special, or punitive damages, including lost revenue, lost profits, lost business opportunities, or loss of goodwill.

        Outage refund. If NexGenSpec experiences an extended outage caused by NexGenSpec LLC (and not by Apple, Firebase, your network, your device, or other services outside our control), our maximum responsibility is a pro-rated refund of subscription fees for the duration of the outage. Outages must be reported in writing within the calendar month they occur to qualify.

        9. Governing Law & Venue
        These Terms are governed by the laws of the State of Colorado, USA, without regard to its conflict-of-laws principles. You and NexGenSpec LLC agree that any dispute arising out of or relating to these Terms or the app shall be brought exclusively in the state or federal courts located in Denver, Colorado, and you consent to personal jurisdiction in those courts.

        Canadian users: If you are a resident of Canada, the foregoing does not deprive you of any non-waivable consumer-protection rights granted by your province or territory of residence. Where such rights apply, they remain in effect notwithstanding the choice of Colorado law.

        You and NexGenSpec LLC agree that any dispute will be resolved on an individual basis only. Class actions, class arbitrations, and consolidated proceedings are not permitted.

        10. Changes to These Terms
        We may update these Terms from time to time. Material changes will be communicated through the app and require fresh acceptance before continued use.

        11. Contact
        NexGenSpec LLC — contact@nexgenspec.com

        ============================================================
        PART B — SAMPLE INSPECTOR–CLIENT AGREEMENT (TEMPLATE)
        ============================================================

        Important Notice
        The sections below are a TEMPLATE you (the inspector) may adapt for use between yourself and your client. NexGenSpec LLC is NOT a party to any inspector-client agreement, has no role in negotiating or enforcing it, and does not retain or guarantee any inspection records on your behalf. By using this template, you agree NexGenSpec LLC is not responsible for its content, suitability, or legal effect. Have your own attorney review before relying on it.

        If the client is not present at the inspection, standard practice is to have the client review and sign this agreement digitally before the inspection (email a copy, use DocuSign, etc.) or include it in your booking confirmation. If the agreement remains unsigned at the time of inspection, document the situation in your notes.

        Section 1 — Inspection Documentation & Digital Media
        By scheduling and permitting this inspection, the client authorizes the Inspector to capture, create, and retain photos, videos, thermal imagery, drone imagery, and 3D/LiDAR scans of the property, where applicable to the scope of this inspection. These records are collected for inspection reporting, internal quality assurance, and to provide a clear, detailed summary of the property's condition.

        The Inspector retains full ownership and custody of all original inspection records. The client receives a copy of the inspection report, which may include selected photos and media as needed for context.

        The Inspector keeps documentation private and uses it only for: this inspection, reporting, dispute resolution, insurance/legal compliance, or other obligations related to this engagement. It will not be shared publicly or with third parties except as required by law or with the client's consent.

        Plain-English Client Summary:
        "Your inspector takes detailed photos, videos, and (where equipped) 3D, thermal, or drone media to make your inspection report accurate and to protect both parties. The inspector keeps the originals; you get a copy in your report. Your images are private and used only for your inspection, not for marketing or social media."

        Section 2 — Inspector's Photo Retention Practice
        The Inspector's stated retention practice is:
        • Retention Period: Original inspection photos, videos, and digital records are retained for at least 5 years — the industry-standard window for claims, complaints, or insurance reviews.
        • Storage: The Inspector is solely responsible for the security, backup, and retention of these records, using systems of the inspector's choosing.
        • Deletion & Archival: Records may be archived or deleted after the retention period ends, unless a dispute or claim is pending.
        • No Premature Deletion: The Inspector will not delete originals before the retention period ends except in documented exceptions.

        Important: NexGenSpec software stores inspection records on the Inspector's device. NexGenSpec LLC does not host, backup, audit, or guarantee retention of these records. The Inspector is fully responsible for backing up records to meet this retention practice (e.g. via iCloud Backup, an external drive, or another system).

        ============================================================
        DATA SAFETY SUMMARY
        ============================================================

        NexGenSpec is local-first. Inspection content — defects, photos, signatures, LiDAR scans, notes, client info, agent info, calendar events, invoices, and PDFs — is stored privately on your iPhone or iPad in the app's sandboxed storage. Other apps cannot read it. NexGenSpec LLC does not receive copies and has no server-side database of inspection data.

        The only data sent off-device is: (a) your account login (email and an encrypted password, or your Apple ID identifier if using Sign in with Apple) stored in Firebase Authentication, (b) anonymized crash reports sent to Firebase Crashlytics if the app crashes, and (c) when an inspection captures weather, the approximate coordinates (~1 km) of your current location, sent to Open-Meteo (open-meteo.com) to fetch current conditions (no account, not linked to your identity, no copy retained by us). No personal data, no inspection content, no background tracking.

        NexGenSpec LLC does not sell, rent, or share your data. No third-party advertising. No marketing trackers.

        Location (Optional)
        If you grant Location access, NexGenSpec uses a one-time fix two ways: automatically when you create or open an inspection, to attach current weather (approximate coordinates ~1 km sent to Open-Meteo); and only when you tap "Use Current Location," to auto-fill a property address (resolved using Apple's location services — those coordinates go to Apple, not NexGenSpec or Open-Meteo). Location is never tracked in the background or stored on our servers, and never linked to your identity. All other features work without it.

        iCloud (Optional)
        If you enable iCloud Backup in iOS Settings, your device — including NexGenSpec's app data — is backed up to your personal iCloud account. Apple encrypts and manages that backup. NexGenSpec has no access.

        Calendar (Optional)
        If you grant Calendar access, NexGenSpec writes events to a calendar you choose, including the property address, client contact details, agent contact details (if provided), and the NexGenSpec job ID. This information is written only to your local calendar and to any calendar accounts (iCloud, Google) you have enabled on your device. NexGenSpec does not receive this data. Deleting an inspection in NexGenSpec also deletes its calendar event. Calendar access is entirely optional — all other app features work without it.

        Your Control
        • Delete the app to remove inspection data from your device.
        • Email contact@nexgenspec.com to delete your login account.
        • Manage your subscription in iOS Settings → Apple ID → Subscriptions.
        """
    }
    
    /// Highlights occurrences of the search text within the given text.
    /// - Parameters:
    ///   - content: The full text content to display.
    ///   - id: Optional id for ScrollViewReader.
    ///   - font: Font to apply to the Text.
    ///   - isHeader: Whether this text is a header (for accessibility).
    /// - Returns: A Text view with highlighted matches.
    @ViewBuilder
    private func highlightedText(_ content: String, id: String? = nil, font: Font = .body, isHeader: Bool = false) -> some View {
        if searchText.isEmpty {
            Text(content)
                .font(font)
                .foregroundColor(.primary)
                .accessibilityAddTraits(isHeader ? .isHeader : [])
                .lineSpacing(4)
                .id(id)
        } else {
            // Note: This implementation scrolls to the first matching section.
            // For finer-grained scrolling to exact matches within sections,
            // additional logic would be needed.
            makeHighlightedText(content: content, searchText: searchText, font: font)
                .accessibilityAddTraits(isHeader ? .isHeader : [])
                .lineSpacing(4)
                .id(id)
        }
    }
    
    private func makeHighlightedText(content: String, searchText: String, font: Font) -> Text {
        let parts = content.lowercased().components(separatedBy: searchText.lowercased())
        if parts.count <= 1 {
            return Text(content).font(font).foregroundColor(.primary)
        }
        var finalText = Text("")
        var currentIndex = content.startIndex
        for (i, part) in parts.enumerated() {
            let partCount = part.count
            if partCount > 0 {
                let partStart = currentIndex
                let partEnd = content.index(partStart, offsetBy: partCount)
                let originalPart = String(content[partStart..<partEnd])
                finalText = Text("\(finalText)\(Text(originalPart).font(font).foregroundColor(.primary))")
                currentIndex = partEnd
            }
            if i < parts.count - 1 {
                let matchStart = currentIndex
                let matchEnd = content.index(matchStart, offsetBy: searchText.count)
                let match = String(content[matchStart..<matchEnd])
                finalText = Text("\(finalText)\(Text(match).font(font).foregroundColor(.accentColor).bold())")
                currentIndex = matchEnd
            }
        }
        return finalText
    }
    
    /// Scrolls to the first match found in the document if any.
    /// - Parameter proxy: ScrollViewProxy for scrolling.
    private func scrollToFirstMatch(proxy: ScrollViewProxy) {
        guard !searchText.isEmpty else {
            return
        }
        // Search in order of sections and title.
        let searchOrder = ["title", "section1", "section2", "datasafety"]
        
        for id in searchOrder {
            if containsSearchMatch(in: id) == true {
                withAnimation {
                    proxy.scrollTo(id, anchor: .top)
                }
                break
            }
        }
    }
    
    /// Checks if the given section id contains the search text.
    /// - Parameter id: The id string of the section.
    /// - Returns: true if match found, false otherwise.
    public func containsSearchMatch(in id: String) -> Bool? {
        let contentForId: String
        switch id {
        case "title":
            contentForId = fullTermsText
        case "section1":
            contentForId =
            """
            Sample Inspector–Client Agreement (Template)
            Important Notice
            The sections below are a TEMPLATE you (the inspector) may adapt for use between yourself and your client. NexGenSpec LLC is NOT a party to any inspector-client agreement, has no role in negotiating or enforcing it, and does not retain or guarantee any inspection records on your behalf.

            Section 1 — Inspection Documentation & Digital Media
            By scheduling and permitting this inspection, the client authorizes the Inspector to capture, create, and retain photos, videos, thermal imagery, drone imagery, and 3D/LiDAR scans of the property, where applicable to the scope of this inspection.

            The Inspector retains full ownership and custody of all original inspection records. The client receives a copy of the inspection report.

            Plain-English Client Summary:
            "Your inspector takes detailed photos, videos, and (where equipped) 3D, thermal, or drone media to make your inspection report accurate and to protect both parties."
            """
        case "section2":
            contentForId =
            """
            Section 2 — Inspector's Photo Retention Practice
            • Retention Period: Original inspection photos, videos, and digital records are retained for at least 5 years.
            • Storage: The Inspector is solely responsible for the security, backup, and retention of these records.
            • Deletion & Archival: Records may be archived or deleted after the retention period ends, unless a dispute or claim is pending.
            • No Premature Deletion: The Inspector will not delete originals before the retention period ends except in documented exceptions.

            Important: NexGenSpec software stores inspection records on the Inspector's device. NexGenSpec LLC does not host, backup, audit, or guarantee retention of these records.
            """
        default:
            contentForId = ""
        }
        return contentForId.lowercased().contains(searchText.lowercased())
    }
}

private struct TermsQuickLink: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))

            Text(title)
                .font(AppFont.subheadline.weight(.semibold))
        }
        .foregroundStyle(AppColor.accent)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(AppColor.accent.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// UIKit wrapper for iOS share sheet (UIActivityViewController)
struct ActivityView: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems,
                                                  applicationActivities: applicationActivities)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct TermsAndConditionsView_Previews: PreviewProvider {
    @State static var acknowledgeCallback: (() -> Void)? = nil
    
    static var previews: some View {
        NavigationStack {
            TermsAndConditionsView(onAcknowledge: $acknowledgeCallback)
        }
    }
}
