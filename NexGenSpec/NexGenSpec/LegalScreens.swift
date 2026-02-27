import SwiftUI

// Assuming TermsAndConditionsView is defined elsewhere and accessible here
// If not, you can import its module or file as needed.

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

// MARK: - PrivacyPolicyView
struct PrivacyPolicyView: View {
    @State private var policyURL: URL? = nil
    @State private var showExternalLinkAlert = false

    private let externalURLKey = "PrivacyPolicyURL"

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    Image(Branding.logoName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .padding(.top)

                    Text("Privacy Policy")
                        .font(.largeTitle)
                        .bold()
                        .foregroundColor(Branding.accentColor)
                        .padding(.bottom, 10)

                    // Example privacy policy text
                    Group {
                        Text("Your privacy is important to us. This policy explains how we collect, use, and protect your information when you use our app.")
                            .font(.body)
                            .multilineTextAlignment(.leading)
                        Text("We collect minimal personal information and never share it with third parties without your consent.")
                            .font(.body)
                            .multilineTextAlignment(.leading)
                        Text("You can view the full privacy policy on our website if you prefer.")
                            .font(.body)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal)

                    if let url = policyURL {
                        Link("View Full Privacy Policy", destination: url)
                            .font(.headline)
                            .foregroundColor(Branding.accentColor)
                            .padding(.top, 30)
                    } else {
                        Text("Privacy Policy URL not found.")
                            .foregroundColor(.red)
                            .padding(.top, 30)
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Privacy Policy")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let urlString = Bundle.main.object(forInfoDictionaryKey: externalURLKey) as? String,
                   let url = URL(string: urlString) {
                    policyURL = url
                }
            }
        }
        .accentColor(Branding.accentColor)
    }
}

// MARK: - DisclaimerView
struct DisclaimerView: View {
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    Image(Branding.logoName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .padding(.top)

                    Text("Disclaimer")
                        .font(.largeTitle)
                        .bold()
                        .foregroundColor(Branding.accentColor)
                        .padding(.bottom, 10)

                    Group {
                        Text("This app is provided for informational purposes only.")
                            .multilineTextAlignment(.leading)
                            .font(.body)
                        Text("It does not provide legal, engineering, medical, or any other professional certifications or advice.")
                            .multilineTextAlignment(.leading)
                            .font(.body)
                        Text("Use of this app and reliance on its content is at your own risk.")
                            .multilineTextAlignment(.leading)
                            .font(.body)
                    }
                    .padding(.horizontal)

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Disclaimer")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accentColor(Branding.accentColor)
    }
}

// MARK: - TermsAndConditionsView Extension for Acceptance Logging
struct TermsAndConditionsViewWithAcceptance: View {
    // Assuming original TermsAndConditionsView exists without acceptance logging
    @State private var accepted = false

    var body: some View {
        NavigationView {
            VStack {
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

// MARK: - Preview Container for LegalScreens.swift (Optional)
struct LegalScreens_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            TermsAndConditionsViewWithAcceptance()
            PrivacyPolicyView()
            DisclaimerView()
        }
    }
}
