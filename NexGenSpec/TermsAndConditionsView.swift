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
    @State private var showDataSafetyPDF = false
    
    /// Optional callback invoked when user acknowledges terms.
    /// If `nil`, no accept button is shown and view is readonly.
    @Binding public var onAcknowledge: (() -> Void)?
    
    /// Initializes the view.
    /// - Parameter onAcknowledge: Binding to optional callback to invoke on acknowledge. Defaults to `.constant(nil)`.
    public init(onAcknowledge: Binding<(() -> Void)?> = .constant(nil)) {
        self._onAcknowledge = onAcknowledge
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // App disclaimer: NexGenSpec is reporting software only; legally separate from any inspection company.
            Text("NexGenSpec is inspection reporting software only. You are responsible for licensing, insurance, and report content. This app is not a marketplace and is legally separate from D.I.A. Inspections.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            
            // Logo (optional; use NexGenSpec or company branding)
            if UIImage(named: "LogoLockup") != nil {
                Image("LogoLockup")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 48)
                    .accessibilityLabel("App Logo")
                    .padding(.top, 8)
                    .padding(.horizontal)
            }
            
            // Effective Dates for Policies
            VStack(spacing: 2) {
                Text("Effective Date: February 7, 2026 (Terms of Service)")
                Text("Effective Date: February 7, 2026 (Privacy Policy)")
            }
            .font(.footnote)
            .foregroundColor(.secondary)
            .accessibilityElement(children: .combine)
            .padding(.top, 8)
            .padding(.bottom, 4)
            
            // Links to hosted Privacy and Terms URLs
            HStack(spacing: 8) {
                Link("View Privacy Policy", destination: URL(string: "https://www.dia-inspections.com/privacy")!)
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
                    .accessibilityLabel("View Privacy Policy")
                Spacer()
                Link("View Terms of Service", destination: URL(string: "https://www.dia-inspections.com/terms")!)
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
                    .accessibilityLabel("View Terms of Service")
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            
            // Search Field
            TextField("Search Terms", text: $searchText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.horizontal)
                .padding(.bottom, 4)
                .accessibilityLabel("Search Terms")
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Group {
                            highlightedText("Terms & Conditions", id: "title", font: .title.bold(), isHeader: true)
                            
                            Group {
                                highlightedText("These terms and conditions outline the rules and regulations for the use of D.I.A. Inspections' website, located at https://www.dia-inspections.com.\n\n", font: .body)
                                highlightedText("Cookies:", font: .headline, isHeader: true)
                                highlightedText("We employ the use of cookies. By accessing the website, you agree to use cookies in agreement with D.I.A. Inspections’ Privacy Policy.\n\n", font: .body)
                                highlightedText("License:", font: .headline, isHeader: true)
                                highlightedText("Unless otherwise stated, D.I.A. Inspections and/or its licensors own the intellectual property rights for all material on the website. All intellectual property rights are reserved. You may access this from the website for your own personal use subjected to restrictions set in these terms and conditions.\n\n", font: .body)
                                highlightedText("You must not:", font: .body)
                                highlightedText("• Republish material\n• Sell, rent or sub-license material\n• Reproduce, duplicate or copy material\n• Redistribute content without prior written consent\n\n", font: .body)
                                highlightedText("User Comments:", font: .headline, isHeader: true)
                                highlightedText("Certain parts of this website allow users to post comments. D.I.A. Inspections does not filter, edit, publish or review Comments prior to their presence on the website. Comments reflect the views of the author only and do not represent the views of D.I.A. Inspections.\n\n", font: .body)
                                highlightedText("Hyperlinking to our Content:", font: .headline, isHeader: true)
                                highlightedText("The following organizations may link to our Website without prior written approval:\n- Government agencies\n- Search engines\n- News organizations\n- Online directory distributors\n- System wide Accredited Businesses\n\n", font: .body)
                                highlightedText("Modification of Terms:", font: .headline, isHeader: true)
                                highlightedText("D.I.A. Inspections may revise these terms and conditions at any time. By using the website you are expected to review these terms on a regular basis to ensure you understand all terms and conditions governing use.\n\n", font: .body)
                                highlightedText("Your Privacy:", font: .headline, isHeader: true)
                                highlightedText("Please read our Privacy Policy to understand how we handle your personal data.\n\n", font: .body)
                                highlightedText("Contact Us:", font: .headline, isHeader: true)
                                
                                // Contact email tappable link
                                HStack(spacing: 0) {
                                    Text("If you have any questions about these Terms, please contact us at ")
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Link("support@dia-inspections.com",
                                         destination: URL(string: "mailto:support@dia-inspections.com")!)
                                    .font(.body)
                                    .foregroundColor(.accentColor)
                                    .accessibilityLabel("Contact Support Email")
                                }
                            }
                            .padding(.bottom, 12)
                        }
                        .id("title")
                        
                        // Section 1
                        Group {
                            highlightedText("SECTION 1 — INSPECTION AGREEMENT LANGUAGE", id: "section1", font: .title3.bold(), isHeader: true)
                            highlightedText("INSPECTION DOCUMENTATION & DIGITAL MEDIA", font: .headline, isHeader: true)
                            highlightedText("By scheduling and permitting this inspection, you authorize D.I.A. Inspections (\"Inspector\") to capture, create, and retain photos, videos, thermal images, drone imagery, and 3D/LiDAR scans of the property. These records are collected for inspection reporting, internal quality assurance, and to provide you with a clear, detailed summary of the property’s condition.\n\nThe Inspector retains full ownership and custody of all original inspection records, including photos and digital files. You, as the client, receive a copy of the inspection report, which may include selected photos and media as needed for context. All media is securely stored and may be backed up to trusted cloud services for retention and disaster recovery.\n\nYour privacy is important: inspection documentation will not be shared publicly or with third parties except as required by law, with your consent, or as necessary for insurance, legal, or compliance purposes related to this inspection. Use of all documentation is strictly limited to inspection, reporting, dispute resolution, or as otherwise required to fulfill contractual or legal obligations. If there is any dispute, D.I.A. Inspections’ digital records may be relied upon as evidence.", font: .body)
                            highlightedText("Plain-English Client Summary:", font: .headline, isHeader: true)
                            highlightedText("\"We take detailed photos, videos, and 3D scans to make your inspection report accurate, protect both parties, and maintain quality. We keep the originals safe; you get a copy in your report. Your images are private and used only for your inspection, not for marketing or social media.\"", font: .body)
                            Divider()
                        }
                        .id("section1")
                        
                        // Section 2
                        Group {
                            highlightedText("SECTION 2 — PHOTO RETENTION POLICY", id: "section2", font: .title3.bold(), isHeader: true)
                            highlightedText("OFFICIAL POLICY", font: .headline, isHeader: true)
                            Group {
                                highlightedText("• Retention Period: All original inspection photos, videos, and digital records are retained for at least 5 years.", font: .body)
                                highlightedText("• Justification: 5 years is the industry standard window for claims, complaints, or insurance reviews.", font: .body)
                                highlightedText("• Applies To: All digital inspection media, including annotated/edited versions and exported report assets.", font: .body)
                                highlightedText("• Justification: Ensures any version used in a report or dispute is accessible.", font: .body)
                                highlightedText("• Deletion & Archival: Media may be securely archived or deleted after the retention period, unless a dispute or claim is pending.", font: .body)
                                highlightedText("• Justification: Limits storage costs while protecting against active risks.", font: .body)
                                highlightedText("• Secure Storage: All media is stored on secure, access-controlled systems, with cloud backup as needed.", font: .body)
                                highlightedText("• Justification: Reduces risk of loss, tampering, or unauthorized access.", font: .body)
                                highlightedText("• No Premature Deletion: Originals cannot be deleted or overwritten before the retention period ends, except with written admin approval in documented exceptions.", font: .body)
                                highlightedText("• Justification: Guarantees the integrity of records if you’re ever challenged.", font: .body)
                            }
                            .padding(.leading)
                            Divider()
                        }
                        .id("section2")
                        
                        // Section 3
                        Group {
                            highlightedText("SECTION 3 — INSPECTIQ PHOTO LEGAL MODEL (SYSTEM OF RECORD)", id: "section3", font: .title3.bold(), isHeader: true)
                            highlightedText("DESIGN & LIFECYCLE", font: .headline, isHeader: true)
                            Group {
                                highlightedText("• Capture: Photos and media are captured or imported directly into InspectIQ, never into the device’s personal gallery/camera roll. This immediately marks the image as official evidence.", font: .body)
                                highlightedText("• Storage: All originals are saved in a secure, immutable archive inside InspectIQ, with unique IDs, timestamps, inspection IDs, and context tags (system/area/category).", font: .body)
                                highlightedText("• Annotation: Markups or annotations create new, linked versions (never overwrite the original).", font: .body.italic())
                                highlightedText("    - Originals = Untouched evidence\n    - Annotated = Marked-up “copies” for reports", font: .body)
                                highlightedText("• Organization: Every photo is organized:\n    - By Inspection\n    - By Area/System\n    - By Type (original, annotated, exported)", font: .body)
                                highlightedText("• Report Use: Only approved/exported assets leave the system (for reports or client copies). Metadata and version histories are maintained for all exports.", font: .body)
                                highlightedText("• Archive: After report finalization, all media is locked. Originals cannot be altered. The full chain from capture to export is preserved for audits.", font: .body)
                            }
                            .padding(.leading)
                            highlightedText("How this protects legal integrity:", font: .headline, isHeader: true)
                            Group {
                                highlightedText("• Every image has a clear chain-of-custody and audit trail.", font: .body)
                                highlightedText("• No accidental loss or modification.", font: .body)
                                highlightedText("• In any dispute, you have bulletproof evidence and can demonstrate responsible, professional recordkeeping.", font: .body)
                            }
                            .padding(.leading)
                            highlightedText("How this reduces liability:", font: .headline, isHeader: true)
                            Group {
                                highlightedText("• You can prove exactly when/where/how each photo was taken, and show you never tampered with originals.", font: .body)
                                highlightedText("• If you’re challenged, insurance/legal reviewers see a transparent, professional process — not a digital ‘shoebox.’", font: .body)
                            }
                            .padding(.leading)
                            Divider()
                        }
                        .id("section3")
                        
                        // Section 4
                        Group {
                            highlightedText("SECTION 4 — APP ENFORCEMENT RULES", id: "section4", font: .title3.bold(), isHeader: true)
                            Group {
                                highlightedText("1. Originals are permanent: Once a photo is captured/imported, the original file cannot be deleted or modified after report finalization.", font: .body)
                                highlightedText("2. No overwriting originals: All edits, markups, or crops create new, linked versions. Originals always remain available.", font: .body)
                                highlightedText("3. Clear versioning: Every change is tracked:\n    • Original\n    • Annotated/edited\n    • Report-exported", font: .body)
                                highlightedText("4. Export rules: Only finalized, report-approved images/assets may be exported or shared outside the app.", font: .body)
                                highlightedText("5. Admin-only deletion/archive: Deletion of originals (after retention period) or in exceptional cases is admin-controlled, logged, and never silent.", font: .body)
                                highlightedText("6. Audit trail required: All access, edits, exports, or deletions must be logged (timestamp, user, action).", font: .body)
                            }
                            .padding(.leading)
                            Divider()
                        }
                        .id("section4")
                        
                        // Section 5
                        Group {
                            highlightedText("SECTION 5 — SUMMARY", id: "section5", font: .title3.bold(), isHeader: true)
                            highlightedText("Executive Summary", font: .headline, isHeader: true)
                            highlightedText("This system protects your business by ensuring all inspection photos are securely stored, never overwritten, and properly organized for at least 5 years. Originals and annotated copies are clearly separated, every action is logged, and only approved assets leave the app. If you ever face a dispute, claim, or insurance request, you have a complete, defensible evidence trail.", font: .body)
                            highlightedText("For Clients", font: .headline, isHeader: true)
                            highlightedText("We keep all original photos and inspection records locked and safe for 5 years. Your report only includes what’s needed, and nothing leaves our secure system unless it’s part of your inspection.", font: .body)
                            highlightedText("For Insurance or Legal Inquiries", font: .headline, isHeader: true)
                            highlightedText("All inspection photos and records are preserved in an immutable, access-controlled system with full audit trails for at least 5 years, per our written retention policy. Originals are never deleted or altered before that time, and all exports or edits are versioned and logged. This ensures we can demonstrate the authenticity and integrity of any documentation if required.", font: .body)
                        }
                        .id("section5")
                        
                        // Data Safety Summary Section
                        Group {
                            Divider()
                            highlightedText("DATA SAFETY SUMMARY", id: "datasafety", font: .title3.bold(), isHeader: true)
                            highlightedText("We take data safety seriously. All personal and inspection data is encrypted at rest and in transit. Access controls and audit logs protect against unauthorized access. Our app does not share your data with third parties except as required by law or with your explicit consent.", font: .body)
                            
                            Button(action: {
                                showDataSafetyPDF = true
                            }) {
                                Text("View Full Data Safety Summary (PDF)")
                                    .font(.body.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundColor(.accentColor)
                                    .cornerRadius(8)
                                    .padding(.vertical, 8)
                            }
                            .accessibilityLabel("View Full Data Safety Summary PDF")
                        }
                    }
                    .padding()
                    .onChange(of: searchText) { _, _ in
                        scrollToFirstMatch(proxy: proxy)
                    }
                    .onAppear {
                        scrollToFirstMatch(proxy: proxy)
                    }
                }
            }
            
            // Acceptance Microcopy
            Text("By using NexGenSpec, you agree to the Terms of Service and acknowledge the Privacy Policy.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)
            
            if onAcknowledge != nil {
                // Clear visible and accessible message above the button
                Text("You must accept these terms to continue.")
                    .font(.headline)
                    .foregroundColor(.red)
                    .padding(.horizontal)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel("You must accept these terms to continue")
                
                Button {
                    AuditLog.log(event: "Terms and Conditions accepted")
                    onAcknowledge?()
                } label: {
                    Text("Accept Terms & Continue")
                        .bold()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .padding([.horizontal, .bottom])
                }
                .accessibilityLabel("Accept Terms and Continue")
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
        // Present PDF viewer for Data Safety Summary
        .sheet(isPresented: $showDataSafetyPDF) {
            if let url = dataSafetySummaryPDFURL {
                PDFViewer(url: url)
            } else {
                TermsDataSafetySummaryFallbackView()
            }
        }
    }

    private var dataSafetySummaryPDFURL: URL? {
        Bundle.main.url(forResource: "DataSafetySummary", withExtension: "pdf")
    }
    
    /// Aggregates all terms text into a single plain text string for sharing.
    public var fullTermsText: String {
        """
        Terms & Conditions

        These terms and conditions outline the rules and regulations for the use of D.I.A. Inspections' website, located at https://www.dia-inspections.com.

        Cookies:
        We employ the use of cookies. By accessing the website, you agree to use cookies in agreement with D.I.A. Inspections’ Privacy Policy.

        License:
        Unless otherwise stated, D.I.A. Inspections and/or its licensors own the intellectual property rights for all material on the website. All intellectual property rights are reserved. You may access this from the website for your own personal use subjected to restrictions set in these terms and conditions.

        You must not:
        • Republish material
        • Sell, rent or sub-license material
        • Reproduce, duplicate or copy material
        • Redistribute content without prior written consent

        User Comments:
        Certain parts of this website allow users to post comments. D.I.A. Inspections does not filter, edit, publish or review Comments prior to their presence on the website. Comments reflect the views of the author only and do not represent the views of D.I.A. Inspections.

        Hyperlinking to our Content:
        The following organizations may link to our Website without prior written approval:
        - Government agencies
        - Search engines
        - News organizations
        - Online directory distributors
        - System wide Accredited Businesses

        Modification of Terms:
        D.I.A. Inspections may revise these terms and conditions at any time. By using the website you are expected to review these terms on a regular basis to ensure you understand all terms and conditions governing use.

        Your Privacy:
        Please read our Privacy Policy to understand how we handle your personal data.

        Contact Us:
        If you have any questions about these Terms, please contact us at support@dia-inspections.com.

        SECTION 1 — INSPECTION AGREEMENT LANGUAGE
        INSPECTION DOCUMENTATION & DIGITAL MEDIA
        By scheduling and permitting this inspection, you authorize D.I.A. Inspections ("Inspector") to capture, create, and retain photos, videos, thermal images, drone imagery, and 3D/LiDAR scans of the property. These records are collected for inspection reporting, internal quality assurance, and to provide you with a clear, detailed summary of the property’s condition.

        The Inspector retains full ownership and custody of all original inspection records, including photos and digital files. You, as the client, receive a copy of the inspection report, which may include selected photos and media as needed for context. All media is securely stored and may be backed up to trusted cloud services for retention and disaster recovery.

        Your privacy is important: inspection documentation will not be shared publicly or with third parties except as required by law, with your consent, or as necessary for insurance, legal, or compliance purposes related to this inspection. Use of all documentation is strictly limited to inspection, reporting, dispute resolution, or as otherwise required to fulfill contractual or legal obligations. If there is any dispute, D.I.A. Inspections’ digital records may be relied upon as evidence.

        Plain-English Client Summary:
        "We take detailed photos, videos, and 3D scans to make your inspection report accurate, protect both parties, and maintain quality. We keep the originals safe; you get a copy in your report. Your images are private and used only for your inspection, not for marketing or social media."

        SECTION 2 — PHOTO RETENTION POLICY
        OFFICIAL POLICY
        • Retention Period: All original inspection photos, videos, and digital records are retained for at least 5 years.
        • Justification: 5 years is the industry standard window for claims, complaints, or insurance reviews.
        • Applies To: All digital inspection media, including annotated/edited versions and exported report assets.
        • Justification: Ensures any version used in a report or dispute is accessible.
        • Deletion & Archival: Media may be securely archived or deleted after the retention period, unless a dispute or claim is pending.
        • Justification: Limits storage costs while protecting against active risks.
        • Secure Storage: All media is stored on secure, access-controlled systems, with cloud backup as needed.
        • Justification: Reduces risk of loss, tampering, or unauthorized access.
        • No Premature Deletion: Originals cannot be deleted or overwritten before the retention period ends, except with written admin approval in documented exceptions.
        • Justification: Guarantees the integrity of records if you’re ever challenged.

        SECTION 3 — INSPECTIQ PHOTO LEGAL MODEL (SYSTEM OF RECORD)
        DESIGN & LIFECYCLE
        • Capture: Photos and media are captured or imported directly into InspectIQ, never into the device’s personal gallery/camera roll. This immediately marks the image as official evidence.
        • Storage: All originals are saved in a secure, immutable archive inside InspectIQ, with unique IDs, timestamps, inspection IDs, and context tags (system/area/category).
        • Annotation: Markups or annotations create new, linked versions (never overwrite the original).
            - Originals = Untouched evidence
            - Annotated = Marked-up “copies” for reports
        • Organization: Every photo is organized:
            - By Inspection
            - By Area/System
            - By Type (original, annotated, exported)
        • Report Use: Only approved/exported assets leave the system (for reports or client copies). Metadata and version histories are maintained for all exports.
        • Archive: After report finalization, all media is locked. Originals cannot be altered. The full chain from capture to export is preserved for audits.

        How this protects legal integrity:
        • Every image has a clear chain-of-custody and audit trail.
        • No accidental loss or modification.
        • In any dispute, you have bulletproof evidence and can demonstrate responsible, professional recordkeeping.

        How this reduces liability:
        • You can prove exactly when/where/how each photo was taken, and show you never tampered with originals.
        • If you’re challenged, insurance/legal reviewers see a transparent, professional process — not a digital ‘shoebox.’

        SECTION 4 — APP ENFORCEMENT RULES
        1. Originals are permanent: Once a photo is captured/imported, the original file cannot be deleted or modified after report finalization.
        2. No overwriting originals: All edits, markups, or crops create new, linked versions. Originals always remain available.
        3. Clear versioning: Every change is tracked:
            • Original
            • Annotated/edited
            • Report-exported
        4. Export rules: Only finalized, report-approved images/assets may be exported or shared outside the app.
        5. Admin-only deletion/archive: Deletion of originals (after retention period) or in exceptional cases is admin-controlled, logged, and never silent.
        6. Audit trail required: All access, edits, exports, or deletions must be logged (timestamp, user, action).

        SECTION 5 — SUMMARY
        Executive Summary
        This system protects your business by ensuring all inspection photos are securely stored, never overwritten, and properly organized for at least 5 years. Originals and annotated copies are clearly separated, every action is logged, and only approved assets leave the app. If you ever face a dispute, claim, or insurance request, you have a complete, defensible evidence trail.

        For Clients
        We keep all original photos and inspection records locked and safe for 5 years. Your report only includes what’s needed, and nothing leaves our secure system unless it’s part of your inspection.

        For Insurance or Legal Inquiries
        All inspection photos and records are preserved in an immutable, access-controlled system with full audit trails for at least 5 years, per our written retention policy. Originals are never deleted or altered before that time, and all exports or edits are versioned and logged. This ensures we can demonstrate the authenticity and integrity of any documentation if required.

        DATA SAFETY SUMMARY
        We take data safety seriously. All personal and inspection data is encrypted at rest and in transit. Access controls and audit logs protect against unauthorized access. Our app does not share your data with third parties except as required by law or with your explicit consent.
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
        let searchOrder = ["title", "section1", "section2", "section3", "section4", "section5", "datasafety"]
        
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
            contentForId = "Terms & Conditions"
        case "section1":
            contentForId =
            """
            SECTION 1 — INSPECTION AGREEMENT LANGUAGE
            INSPECTION DOCUMENTATION & DIGITAL MEDIA
            By scheduling and permitting this inspection, you authorize D.I.A. Inspections (\"Inspector\") to capture, create, and retain photos, videos, thermal images, drone imagery, and 3D/LiDAR scans of the property. These records are collected for inspection reporting, internal quality assurance, and to provide you with a clear, detailed summary of the property’s condition.

            The Inspector retains full ownership and custody of all original inspection records, including photos and digital files. You, as the client, receive a copy of the inspection report, which may include selected photos and media as needed for context. All media is securely stored and may be backed up to trusted cloud services for retention and disaster recovery.

            Your privacy is important: inspection documentation will not be shared publicly or with third parties except as required by law, with your consent, or as necessary for insurance, legal, or compliance purposes related to this inspection. Use of all documentation is strictly limited to inspection, reporting, dispute resolution, or as otherwise required to fulfill contractual or legal obligations. If there is any dispute, D.I.A. Inspections’ digital records may be relied upon as evidence.

            Plain-English Client Summary:
            "We take detailed photos, videos, and 3D scans to make your inspection report accurate, protect both parties, and maintain quality. We keep the originals safe; you get a copy in your report. Your images are private and used only for your inspection, not for marketing or social media."
            """
        case "section2":
            contentForId =
            """
            SECTION 2 — PHOTO RETENTION POLICY
            OFFICIAL POLICY
            • Retention Period: All original inspection photos, videos, and digital records are retained for at least 5 years.
            • Justification: 5 years is the industry standard window for claims, complaints, or insurance reviews.
            • Applies To: All digital inspection media, including annotated/edited versions and exported report assets.
            • Justification: Ensures any version used in a report or dispute is accessible.
            • Deletion & Archival: Media may be securely archived or deleted after the retention period, unless a dispute or claim is pending.
            • Justification: Limits storage costs while protecting against active risks.
            • Secure Storage: All media is stored on secure, access-controlled systems, with cloud backup as needed.
            • Justification: Reduces risk of loss, tampering, or unauthorized access.
            • No Premature Deletion: Originals cannot be deleted or overwritten before the retention period ends, except with written admin approval in documented exceptions.
            • Justification: Guarantees the integrity of records if you’re ever challenged.
            """
        case "section3":
            contentForId =
            """
            SECTION 3 — INSPECTIQ PHOTO LEGAL MODEL (SYSTEM OF RECORD)
            DESIGN & LIFECYCLE
            • Capture: Photos and media are captured or imported directly into InspectIQ, never into the device’s personal gallery/camera roll. This immediately marks the image as official evidence.
            • Storage: All originals are saved in a secure, immutable archive inside InspectIQ, with unique IDs, timestamps, inspection IDs, and context tags (system/area/category).
            • Annotation: Markups or annotations create new, linked versions (never overwrite the original).
                - Originals = Untouched evidence
                - Annotated = Marked-up “copies” for reports
            • Organization: Every photo is organized:
                - By Inspection
                - By Area/System
                - By Type (original, annotated, exported)
            • Report Use: Only approved/exported assets leave the system (for reports or client copies). Metadata and version histories are maintained for all exports.
            • Archive: After report finalization, all media is locked. Originals cannot be altered. The full chain from capture to export is preserved for audits.

            How this protects legal integrity:
            • Every image has a clear chain-of-custody and audit trail.
            • No accidental loss or modification.
            • In any dispute, you have bulletproof evidence and can demonstrate responsible, professional recordkeeping.

            How this reduces liability:
            • You can prove exactly when/where/how each photo was taken, and show you never tampered with originals.
            • If you’re challenged, insurance/legal reviewers see a transparent, professional process — not a digital ‘shoebox.’
            """
        case "section4":
            contentForId =
            """
            SECTION 4 — APP ENFORCEMENT RULES
            1. Originals are permanent: Once a photo is captured/imported, the original file cannot be deleted or modified after report finalization.
            2. No overwriting originals: All edits, markups, or crops create new, linked versions. Originals always remain available.
            3. Clear versioning: Every change is tracked:
                • Original
                • Annotated/edited
                • Report-exported
            4. Export rules: Only finalized, report-approved images/assets may be exported or shared outside the app.
            5. Admin-only deletion/archive: Deletion of originals (after retention period) or in exceptional cases is admin-controlled, logged, and never silent.
            6. Audit trail required: All access, edits, exports, or deletions must be logged (timestamp, user, action).
            """
        case "section5":
            contentForId =
            """
            SECTION 5 — SUMMARY
            Executive Summary
            This system protects your business by ensuring all inspection photos are securely stored, never overwritten, and properly organized for at least 5 years. Originals and annotated copies are clearly separated, every action is logged, and only approved assets leave the app. If you ever face a dispute, claim, or insurance request, you have a complete, defensible evidence trail.

            For Clients
            We keep all original photos and inspection records locked and safe for 5 years. Your report only includes what’s needed, and nothing leaves our secure system unless it’s part of your inspection.

            For Insurance or Legal Inquiries
            All inspection photos and records are preserved in an immutable, access-controlled system with full audit trails for at least 5 years, per our written retention policy. Originals are never deleted or altered before that time, and all exports or edits are versioned and logged. This ensures we can demonstrate the authenticity and integrity of any documentation if required.
            """
        case "datasafety":
            contentForId =
            """
            DATA SAFETY SUMMARY
            We take data safety seriously. All personal and inspection data is encrypted at rest and in transit. Access controls and audit logs protect against unauthorized access. Our app does not share your data with third parties except as required by law or with your explicit consent.
            """
        default:
            contentForId = ""
        }
        return contentForId.lowercased().contains(searchText.lowercased())
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

/// PDF Viewer for displaying PDF documents from URL
struct PDFViewer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIViewController {
        let pdfView = PDFView()
        pdfView.document = PDFDocument(url: url)
        pdfView.autoScales = true

        let viewController = UIViewController()
        viewController.view = pdfView
        viewController.navigationItem.title = "Data Safety Summary"
        
        let nav = UINavigationController(rootViewController: viewController)
        return nav
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private struct TermsDataSafetySummaryFallbackView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Data Safety Summary")
                        .font(.title2.bold())

                    Text("This build does not include a bundled PDF copy of the data safety summary. The current summary is provided below.")
                        .font(.body)
                        .foregroundColor(.secondary)

                    Group {
                        Text("What We Collect")
                            .font(.headline)
                        Text("NexGenSpec stores inspection details, photos, signatures, LiDAR scans, videos, and audit events so reports can be created, finalized, and retained for business records.")

                        Text("How Data Is Protected")
                            .font(.headline)
                        Text("Inspection data written by the app is saved with file protection enabled. Backups can be encrypted, and finalized reports keep an audit trail and verification hash.")

                        Text("How Data Is Used")
                            .font(.headline)
                        Text("Inspection records are used to build reports, support customer communication, and preserve documentation for retention and dispute resolution workflows.")

                        Text("Sharing")
                            .font(.headline)
                        Text("Inspection data is not shared publicly. Exports and disclosures are limited to the inspector's reporting workflow, the client, or cases required by law or explicit consent.")
                    }
                    .font(.body)

                    Divider()

                    Link("View Full Privacy Policy", destination: URL(string: "https://www.dia-inspections.com/privacy")!)
                        .font(.headline)
                    Link("View Terms of Service", destination: URL(string: "https://www.dia-inspections.com/terms")!)
                        .font(.headline)
                }
                .padding()
            }
            .navigationTitle("Data Safety Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct TermsAndConditionsView_Previews: PreviewProvider {
    @State static var acknowledgeCallback: (() -> Void)? = nil
    
    static var previews: some View {
        NavigationStack {
            TermsAndConditionsView(onAcknowledge: $acknowledgeCallback)
        }
    }
}
