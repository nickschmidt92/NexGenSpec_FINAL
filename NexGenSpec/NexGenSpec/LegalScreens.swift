import SwiftUI

// MARK: - AuditLog Helper
struct AuditLog {
    static func logAcceptance(of screen: String) {
        // Implement actual logging here, e.g., send to server or save locally
        print("User accepted \(screen) at \(Date())")
    }
}

// MARK: - Branding Constants
struct Branding {
    static let accentColor = Color.blue
    static let logoName = "AppLogo" // Ensure an image named "AppLogo" exists in assets
}

// MARK: - URLs and Effective Dates (Replace with your actual URLs and dates)
struct LegalConstants {
    static let privacyPolicyURL = URL(string: Bundle.main.object(forInfoDictionaryKey: "PrivacyPolicyURL") as? String ?? "")!
    static let termsOfServiceURL = URL(string: Bundle.main.object(forInfoDictionaryKey: "TermsOfServiceURL") as? String ?? "")!
    static let dataSafetyPDFName = "DataSafetySummary" // PDF in bundle

    static let privacyPolicyEffectiveDate = "Effective Date: January 1, 2026"
    static let termsOfServiceEffectiveDate = "Effective Date: January 1, 2026"
}

// MARK: - PrivacyPolicyView (Full Text + External Link)
struct PrivacyPolicyView: View {
    @State private var showExternalLinkAlert = false
    @State private var externalLink: URL? = nil

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    Text(LegalConstants.privacyPolicyEffectiveDate)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .padding(.top)

                    // Logo
                    Image(Branding.logoName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
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

                    // External link tappable text at bottom
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
        .accentColor(Branding.accentColor)
    }
}

// MARK: - TermsOfServiceView (Full Text + External Link)
struct TermsOfServiceView: View {
    @State private var showExternalLinkAlert = false
    @State private var externalLink: URL? = nil

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    Text(LegalConstants.termsOfServiceEffectiveDate)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .padding(.top)

                    Image(Branding.logoName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
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
        .accentColor(Branding.accentColor)
    }
}

// MARK: - DataSafetySummaryView (PDF Viewer)
struct DataSafetySummaryView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var showPDFNotFoundAlert = false

    var body: some View {
        NavigationView {
            Group {
                if let pdfURL = Bundle.main.url(forResource: LegalConstants.dataSafetyPDFName, withExtension: "pdf") {
                    PDFKitView(url: pdfURL)
                } else {
                    Text("Data Safety Summary PDF not found.")
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                        .onAppear {
                            showPDFNotFoundAlert = true
                        }
                }
            }
            .navigationTitle("Data Safety Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .alert(isPresented: $showPDFNotFoundAlert) {
                Alert(title: Text("Error"),
                      message: Text("DataSafetySummary.pdf is missing from the app bundle."),
                      dismissButton: .default(Text("OK")) {
                          presentationMode.wrappedValue.dismiss()
                      })
            }
        }
        .accentColor(Branding.accentColor)
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
            Text("By creating an account, you agree to our ")
                + Text("Terms of Service")
                    .underline()
                    .foregroundColor(Branding.accentColor)
                    .onTapGesture {
                        showTerms = true
                    }
                + Text(" and acknowledge the ")
                + Text("Privacy Policy")
                    .underline()
                    .foregroundColor(Branding.accentColor)
                    .onTapGesture {
                        showPrivacy = true
                    }
                + Text(".")

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
        NavigationView {
            VStack {
                // Assuming TermsAndConditionsView is implemented elsewhere and shows T&C text
                TermsAndConditionsView()

                Button(action: {
                    accepted = true
                    AuditLog.logAcceptance(of: "Terms and Conditions")
                }) {
                    Text(accepted ? "Accepted ✅" : "Accept Terms and Conditions")
                        .bold()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(accepted ? Color.green : Branding.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .padding()
                }
                .disabled(accepted)
            }
            .navigationTitle("Terms & Conditions")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accentColor(Branding.accentColor)
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
                AuditLog.logAcceptance(of: "Onboarding Terms and Conditions")
            }) {
                Text(acceptedTerms ? "Accepted ✅" : "Accept and Continue")
                    .bold()
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(acceptedTerms ? Color.green : Branding.accentColor)
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
