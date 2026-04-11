import SwiftUI

// MARK: - AuditLog Helper
struct LegacyAuditLogHelper {
    static func logAcceptance(of screen: String) {
        #if DEBUG
        print("User accepted \(screen) at \(Date())")
        #endif
        AuditLog.log(event: "Accepted \(screen)")
    }
}

// MARK: - Branding Constants
struct Branding {
    static let accentColor = AppColor.accent
}

// MARK: - URLs and Effective Dates
struct LegalConstants {
    // Safe URL resolution: try Info.plist first, fall back to canonical
    // nexgenspec.com endpoints. No force-unwraps — an empty/missing plist
    // key on older builds used to crash the app when tapping the link.
    private static let fallbackPrivacy = "https://www.nexgenspec.com/privacy"
    private static let fallbackTerms   = "https://www.nexgenspec.com/terms"

    static let privacyPolicyURL: URL = {
        let s = (Bundle.main.object(forInfoDictionaryKey: "PrivacyPolicyURL") as? String) ?? ""
        return URL(string: s) ?? URL(string: fallbackPrivacy)!
    }()
    static let termsOfServiceURL: URL = {
        let s = (Bundle.main.object(forInfoDictionaryKey: "TermsAndConditionsURL") as? String) ?? ""
        return URL(string: s) ?? URL(string: fallbackTerms)!
    }()
    static let dataSafetyPDFName = "DataSafetySummary" // PDF in bundle

    static let privacyPolicyEffectiveDate = "Effective Date: April 10, 2026"
    static let termsOfServiceEffectiveDate = "Effective Date: April 10, 2026"
}

// MARK: - PrivacyPolicyView (Full Text + External Link)
struct PrivacyPolicyView: View {
    @State private var showExternalLinkAlert = false
    @State private var externalLink: URL? = nil

    var body: some View {
        NavigationStack {
            AppScreenBackground {
                ScrollView {
                    VStack(spacing: 16) {
                        Text(LegalConstants.privacyPolicyEffectiveDate)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top)

                        BrandLockup(
                            subtitle: "Privacy expectations and data handling for NexGenSpec customers.",
                            markSize: 60
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 8)

                        Text("Privacy Policy")
                            .font(.largeTitle)
                            .bold()
                            .foregroundColor(Branding.accentColor)
                            .padding(.bottom, 10)

                        Group {
                            Text("""
                            Your privacy is important to us. This policy explains how we collect, use, and protect your information when you use our app.

                            We collect minimal personal information and never share it with third parties without your consent.

                            We collect device information, usage data, and analytics to improve your experience.

                            We implement reasonable security measures to safeguard your data.

                            You have rights to access, update, or delete your personal information.

                            For more details, please review the full Privacy Policy hosted on our website.
                            """)
                            .font(.body)
                            .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal)

                        Button(action: {
                            externalLink = LegalConstants.privacyPolicyURL
                            showExternalLinkAlert = true
                        }) {
                            Text("View Full Privacy Policy Online")
                                .foregroundColor(Branding.accentColor)
                                .font(.headline)
                                .underline()
                        }
                        .padding(.vertical)

                        Spacer(minLength: 30)
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Privacy Policy")
            .navigationBarTitleDisplayMode(.inline)
            .alert(isPresented: $showExternalLinkAlert) {
                Alert(
                    title: Text("Open External Link?"),
                    message: Text("You are about to open the full Privacy Policy in your browser."),
                    primaryButton: .default(Text("Open")) {
                        if let url = externalLink {
                            UIApplication.shared.open(url)
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .tint(Branding.accentColor)
    }
}

// MARK: - PrivacyPolicyContent (no NavigationStack — for embedding in existing navigation)
struct PrivacyPolicyContent: View {
    @State private var showExternalLinkAlert = false
    @State private var externalLink: URL? = nil

    var body: some View {
        AppScreenBackground {
            ScrollView {
                VStack(spacing: 16) {
                    Text(LegalConstants.privacyPolicyEffectiveDate)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top)

                    Text("Privacy Policy")
                        .font(.largeTitle)
                        .bold()
                        .foregroundColor(Branding.accentColor)
                        .padding(.bottom, 10)

                    Group {
                        Text("""
                        Your privacy is important to us. This policy explains how we collect, use, and protect your information when you use our app.

                        We collect minimal personal information and never share it with third parties without your consent.

                        We collect device information, usage data, and analytics to improve your experience.

                        We implement reasonable security measures to safeguard your data.

                        You have rights to access, update, or delete your personal information.

                        For more details, please review the full Privacy Policy hosted on our website.
                        """)
                        .font(.body)
                        .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal)

                    Button(action: {
                        externalLink = LegalConstants.privacyPolicyURL
                        showExternalLinkAlert = true
                    }) {
                        Text("View Full Privacy Policy Online")
                            .foregroundColor(Branding.accentColor)
                            .font(.headline)
                            .underline()
                    }
                    .padding(.vertical)

                    Spacer(minLength: 30)
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $showExternalLinkAlert) {
            Alert(
                title: Text("Open External Link?"),
                message: Text("You are about to open the full Privacy Policy in your browser."),
                primaryButton: .default(Text("Open")) {
                    if let url = externalLink {
                        UIApplication.shared.open(url)
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }
}

// MARK: - TermsOfServiceView (Full Text + External Link)
struct TermsOfServiceView: View {
    @State private var showExternalLinkAlert = false
    @State private var externalLink: URL? = nil

    var body: some View {
        NavigationStack {
            AppScreenBackground {
                ScrollView {
                    VStack(spacing: 16) {
                        Text(LegalConstants.termsOfServiceEffectiveDate)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top)

                        BrandLockup(
                            subtitle: "Service terms, responsibilities, and operating boundaries for the app.",
                            markSize: 60
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 8)

                        Text("Terms of Service")
                            .font(.largeTitle)
                            .bold()
                            .foregroundColor(Branding.accentColor)
                            .padding(.bottom, 10)

                        Group {
                            Text("""
                            Welcome to our app. By using our services, you agree to the following terms and conditions.

                            Use of the app is subject to compliance with all applicable laws and these terms.

                            We reserve the right to update these terms at any time; continued use signifies acceptance of changes.

                            You are responsible for maintaining the confidentiality of your account and password.

                            We provide the app 'as is' without warranties or guarantees.

                            For the full Terms of Service, please visit our website.
                            """)
                            .font(.body)
                            .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal)

                        Button(action: {
                            externalLink = LegalConstants.termsOfServiceURL
                            showExternalLinkAlert = true
                        }) {
                            Text("View Full Terms of Service Online")
                                .foregroundColor(Branding.accentColor)
                                .font(.headline)
                                .underline()
                        }
                        .padding(.vertical)

                        Spacer(minLength: 30)
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Terms of Service")
            .navigationBarTitleDisplayMode(.inline)
            .alert(isPresented: $showExternalLinkAlert) {
                Alert(
                    title: Text("Open External Link?"),
                    message: Text("You are about to open the full Terms of Service in your browser."),
                    primaryButton: .default(Text("Open")) {
                        if let url = externalLink {
                            UIApplication.shared.open(url)
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .tint(Branding.accentColor)
    }
}

// MARK: - TermsOfServiceContent (no NavigationStack — for embedding in existing navigation)
struct TermsOfServiceContent: View {
    @State private var showExternalLinkAlert = false
    @State private var externalLink: URL? = nil

    var body: some View {
        AppScreenBackground {
            ScrollView {
                VStack(spacing: 16) {
                    Text(LegalConstants.termsOfServiceEffectiveDate)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top)

                    Text("Terms of Service")
                        .font(.largeTitle)
                        .bold()
                        .foregroundColor(Branding.accentColor)
                        .padding(.bottom, 10)

                    Group {
                        Text("""
                        Welcome to our app. By using our services, you agree to the following terms and conditions.

                        Use of the app is subject to compliance with all applicable laws and these terms.

                        We reserve the right to update these terms at any time; continued use signifies acceptance of changes.

                        You are responsible for maintaining the confidentiality of your account and password.

                        We provide the app 'as is' without warranties or guarantees.

                        For the full Terms of Service, please visit our website.
                        """)
                        .font(.body)
                        .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal)

                    Button(action: {
                        externalLink = LegalConstants.termsOfServiceURL
                        showExternalLinkAlert = true
                    }) {
                        Text("View Full Terms of Service Online")
                            .foregroundColor(Branding.accentColor)
                            .font(.headline)
                            .underline()
                    }
                    .padding(.vertical)

                    Spacer(minLength: 30)
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle("Terms of Service")
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $showExternalLinkAlert) {
            Alert(
                title: Text("Open External Link?"),
                message: Text("You are about to open the full Terms of Service in your browser."),
                primaryButton: .default(Text("Open")) {
                    if let url = externalLink {
                        UIApplication.shared.open(url)
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }
}

// MARK: - DataSafetySummaryView (PDF Viewer)
struct DataSafetySummaryView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let pdfURL = Bundle.main.url(forResource: LegalConstants.dataSafetyPDFName, withExtension: "pdf") {
                    PDFKitView(url: pdfURL)
                } else {
                    DataSafetySummaryFallbackView()
                }
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
        .accentColor(Branding.accentColor)
    }
}

private struct DataSafetySummaryFallbackView: View {
    var body: some View {
        AppScreenBackground {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    BrandLockup(
                        subtitle: "A plain-language summary of what data is stored, protected, and shared.",
                        markSize: 56
                    )

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
                        Text("Inspection data is not shared publicly. Exports and disclosures are limited to the inspector’s reporting workflow, the client, or cases required by law or explicit consent.")
                    }
                    .font(.body)

                    Divider()

                    Link("View Full Privacy Policy", destination: LegalConstants.privacyPolicyURL)
                        .font(.headline)
                    Link("View Terms of Service", destination: LegalConstants.termsOfServiceURL)
                        .font(.headline)
                }
                .padding()
            }
        }
    }
}

// MARK: - PDFKitView Wrapper for PDF Display
import PDFKit
struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

// MARK: - LegalMicrocopyView for Onboarding & Settings
struct LegalMicrocopyView: View {
    @State private var showTerms = false
    @State private var showPrivacy = false
    @State private var showDataSafety = false

    var body: some View {
        VStack(spacing: 12) {
            Text("By creating an account, you agree to our terms and acknowledge the privacy policy.")

            HStack(spacing: 16) {
                Button("Terms of Service") {
                    showTerms = true
                }
                .foregroundColor(Branding.accentColor)
                .underline()

                Button("Privacy Policy") {
                    showPrivacy = true
                }
                .foregroundColor(Branding.accentColor)
                .underline()
            }

            Button(action: {
                showDataSafety = true
            }) {
                Text("View Data Safety Summary")
                    .font(.subheadline)
                    .foregroundColor(Branding.accentColor)
                    .underline()
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
        .sheet(isPresented: $showTerms) {
            TermsOfServiceView()
        }
        .sheet(isPresented: $showPrivacy) {
            PrivacyPolicyView()
        }
        .sheet(isPresented: $showDataSafety) {
            DataSafetySummaryView()
        }
    }
}

// MARK: - TermsAndConditionsView Extension for Acceptance Logging (Assuming defined elsewhere)
struct TermsAndConditionsViewWithAcceptance: View {
    @State private var accepted = false

    var body: some View {
        NavigationStack {
            VStack {
                // Assuming TermsAndConditionsView is implemented elsewhere and shows T&C text
                TermsAndConditionsView()

                Button(action: {
                    accepted = true
                    LegacyAuditLogHelper.logAcceptance(of: "Terms and Conditions")
                }) {
                    Text(accepted ? "Accepted ✅" : "Accept Terms and Conditions")
                        .bold()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(accepted ? AppColor.success : Branding.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .padding()
                }
                .disabled(accepted)
            }
            .navigationTitle("Terms & Conditions")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Branding.accentColor)
    }
}

// MARK: - Sample SettingsLegalSection (to embed in app Settings)
struct SettingsLegalSection: View {
    @State private var showPrivacyPolicy = false
    @State private var showTermsOfService = false
    @State private var showDataSafetySummary = false

    var body: some View {
        Section(header: Text("Legal & Data Safety")) {
            Button("Privacy Policy") {
                showPrivacyPolicy = true
            }
            .foregroundColor(Branding.accentColor)
            .sheet(isPresented: $showPrivacyPolicy) {
                PrivacyPolicyView()
            }

            Button("Terms of Service") {
                showTermsOfService = true
            }
            .foregroundColor(Branding.accentColor)
            .sheet(isPresented: $showTermsOfService) {
                TermsOfServiceView()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Data Safety Summary")
                    .font(.headline)
                Text("""
                We are committed to protecting your data by employing strong security measures and transparency in data collection and usage.
                """)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button("View Full Data Safety Summary") {
                    showDataSafetySummary = true
                }
                .font(.subheadline)
                .foregroundColor(Branding.accentColor)
            }
            .padding(.vertical, 8)
            .sheet(isPresented: $showDataSafetySummary) {
                DataSafetySummaryView()
            }
        }
    }
}

// MARK: - Sample OnboardingLegalView including microcopy
struct OnboardingLegalView: View {
    @State private var acceptedTerms = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            LegalMicrocopyView()

            Button(action: {
                acceptedTerms = true
                LegacyAuditLogHelper.logAcceptance(of: "Onboarding Terms and Conditions")
            }) {
                Text(acceptedTerms ? "Accepted ✅" : "Accept and Continue")
                    .bold()
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(acceptedTerms ? AppColor.success : Branding.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .padding(.horizontal)
            }
            .disabled(acceptedTerms)

            Spacer()
        }
    }
}

// MARK: - Preview Container for all new legal views
struct LegalScreens_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            PrivacyPolicyView()
            TermsOfServiceView()
            DataSafetySummaryView()
            LegalMicrocopyView()
            TermsAndConditionsViewWithAcceptance()
            SettingsLegalSection()
            OnboardingLegalView()
        }
    }
}
