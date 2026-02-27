import SwiftUI

// MARK: - Models

struct Feature: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let systemImageName: String
}

// MARK: - Views

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()
    @State private var acceptedTerms = false
    
    private let brandingColor = Color("BrandingAccent") // Placeholder for branding color from logo
    
    private let features: [Feature] = [
        Feature(title: "Inspections",
                description: "Perform detailed inspections with ease.",
                systemImageName: "checkmark.seal"),
        Feature(title: "Photos",
                description: "Capture and organize photos seamlessly.",
                systemImageName: "camera"),
        Feature(title: "LiDAR",
                description: "Utilize LiDAR for precise measurements.",
                systemImageName: "wave.3.left"),
        Feature(title: "Apple Pencil",
                description: "Annotate and draw with Apple Pencil support.",
                systemImageName: "pencil.tip"),
        Feature(title: "Voice Commands",
                description: "Control the app using voice commands.",
                systemImageName: "mic.fill")
    ]
    
    var body: some View {
        NavigationStack(path: $path) {
            WelcomeScreen(brandingColor: brandingColor) {
                path.append(OnboardingStep.features)
            }
            .navigationDestination(for: OnboardingStep.self) { step in
                switch step {
                case .features:
                    FeaturesScreen(features: features, brandingColor: brandingColor) {
                        path.append(OnboardingStep.legal)
                    }
                case .legal:
                    LegalScreen(brandingColor: brandingColor) {
                        acceptedTerms = true
                        AuditLog.log(event: "User accepted Terms and Privacy Policy")
                        dismiss()
                    }
                }
            }
        }
        .accentColor(brandingColor)
    }
}

enum OnboardingStep: Hashable {
    case features, legal
}

// MARK: - Individual Onboarding Screens

struct WelcomeScreen: View {
    let brandingColor: Color
    let onStart: () -> Void
    
    var body: some View {
        VStack(spacing: 40) {
            Spacer()
            
            if let uiImage = UIImage(named: "LogoLockup") {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 250)
                    .accessibilityLabel("NexGenSpec Logo")
            } else {
                Text("NexGenSpec")
                    .font(.largeTitle)
                    .bold()
                    .foregroundColor(brandingColor)
            }
            
            Text("Welcome to NexGenSpec! The future of inspections is here. Let's get started.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Spacer()
            
            Button("Start") {
                onStart()
            }
            .font(.title2.bold())
            .frame(maxWidth: .infinity)
            .padding()
            .background(brandingColor)
            .foregroundColor(.white)
            .cornerRadius(12)
            .padding(.horizontal)
            
            Spacer()
        }
        .padding()
        .navigationBarBackButtonHidden(true)
    }
}

struct FeaturesScreen: View {
    let features: [Feature]
    let brandingColor: Color
    let onNext: () -> Void
    
    var body: some View {
        VStack(spacing: 30) {
            Text("Core Features")
                .font(.largeTitle.bold())
                .padding(.top)
            
            List(features) { feature in
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: feature.systemImageName)
                        .foregroundColor(brandingColor)
                        .font(.title2)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(feature.title)
                            .font(.headline)
                        Text(feature.description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
            .listStyle(.plain)
            
            // Footnote about LiDAR device support - update this message if device support changes
            Text("Note: LiDAR-based room capture is only available on iPad Pro and select iPhone Pro models. On other devices, you can add measurements and photos manually.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            Spacer()
            
            Button("Next") {
                onNext()
            }
            .font(.title2.bold())
            .frame(maxWidth: .infinity)
            .padding()
            .background(brandingColor)
            .foregroundColor(.white)
            .cornerRadius(12)
            .padding(.horizontal)
            .padding(.bottom)
        }
    }
}

// MARK: - Legal Detail Views

struct TermsAndConditionsView: View {
    enum SectionType {
        case privacyPolicy, termsOfService
    }
    
    let section: SectionType
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if section == .privacyPolicy {
                    Text("Privacy Policy")
                        .font(.largeTitle.bold())
                        .padding(.bottom)
                    Text("""
                    This is the Privacy Policy content...
                    (Insert full privacy policy text here.)
                    """)
                } else {
                    Text("Terms of Service")
                        .font(.largeTitle.bold())
                        .padding(.bottom)
                    Text("""
                    This is the Terms of Service content...
                    (Insert full terms of service text here.)
                    """)
                }
            }
            .padding()
        }
        .navigationTitle(section == .privacyPolicy ? "Privacy Policy" : "Terms of Service")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DataSafetyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Data Safety Summary")
                    .font(.largeTitle.bold())
                    .padding(.bottom)
                Text("""
                This is the Data Safety Summary content...
                (Insert full data safety summary or embed PDF content here.)
                """)
            }
            .padding()
        }
        .navigationTitle("Data Safety Summary")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LegalScreen: View {
    let brandingColor: Color
    let onAccept: () -> Void
    
    @State private var accepted = false
    
    // Track if legal views have been visited
    @State private var viewedPrivacyPolicy = false
    @State private var viewedTermsOfService = false
    @State private var viewedDataSafetySummary = false
    
    // Determine if accept button should be enabled
    private var canAccept: Bool {
        accepted && viewedPrivacyPolicy && viewedTermsOfService && viewedDataSafetySummary
    }
    
    var body: some View {
        VStack(spacing: 24) {
            Text("Terms & Privacy")
                .font(.largeTitle.bold())
                .padding(.top)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Please review and accept our Terms of Service and Privacy Policy to continue using NexGenSpec.")
                        .font(.body)
                    
                    NavigationLink("Read Privacy Policy") {
                        TermsAndConditionsView(section: .privacyPolicy)
                            .onDisappear {
                                viewedPrivacyPolicy = true
                            }
                    }
                    .foregroundColor(brandingColor)
                    
                    NavigationLink("Read Terms of Service") {
                        TermsAndConditionsView(section: .termsOfService)
                            .onDisappear {
                                viewedTermsOfService = true
                            }
                    }
                    .foregroundColor(brandingColor)
                    
                    NavigationLink("Data Safety Summary") {
                        DataSafetyView()
                            .onDisappear {
                                viewedDataSafetySummary = true
                            }
                    }
                    .foregroundColor(brandingColor)
                }
                .padding(.horizontal)
            }
            
            // Footnote about LiDAR device support - update this message if device support changes
            Text("Note: LiDAR-based room capture is only available on iPad Pro and select iPhone Pro models. On other devices, you can add measurements and photos manually.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            Toggle(isOn: $accepted) {
                Text("I accept the Terms of Service and Privacy Policy")
                    .font(.headline)
            }
            // Disable toggle until all three legal views have been visited
            .disabled(!(viewedPrivacyPolicy && viewedTermsOfService && viewedDataSafetySummary))
            .padding(.horizontal)
            
            Button("Accept") {
                onAccept()
            }
            .disabled(!canAccept)
            .font(.title2.bold())
            .frame(maxWidth: .infinity)
            .padding()
            .background(canAccept ? brandingColor : Color.gray.opacity(0.5))
            .foregroundColor(.white)
            .cornerRadius(12)
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationBarBackButtonHidden(false)
        .navigationTitle("Terms & Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - AuditLog Placeholder

struct AuditLog {
    static func log(event: String) {
        // Actual logging to audit system would happen here.
        print("AuditLog: \(event)")
    }
}

// MARK: - Preview and Entry Point

struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView()
            .environment(\.colorScheme, .light)
        OnboardingView()
            .environment(\.colorScheme, .dark)
    }
}

