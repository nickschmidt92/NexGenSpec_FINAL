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
    @State private var path = NavigationPath()
    var onComplete: () -> Void

    private let features: [Feature] = [
        Feature(title: "Structured Inspections",
                description: "Customizable templates for Roof, Electrical, Plumbing, HVAC, and more.",
                systemImageName: "checkmark.seal"),
        Feature(title: "Photo Capture & Annotation",
                description: "Take photos, mark them up with arrows, circles, and PencilKit drawings.",
                systemImageName: "camera"),
        Feature(title: "LiDAR Room Scanning",
                description: "Capture 3D room scans on supported devices for dimensional reference.",
                systemImageName: "wave.3.left"),
        Feature(title: "Apple Pencil Support",
                description: "Draw annotations directly on inspection photos with precision.",
                systemImageName: "pencil.tip"),
        Feature(title: "Voice Commands (Pro)",
                description: "Hands-free commands: \"Next room\", \"Add note\", \"Defect: broken window\".",
                systemImageName: "mic.fill"),
        Feature(title: "PDF Reports & Invoicing",
                description: "Generate branded reports, attach to invoices, and email to clients.",
                systemImageName: "doc.richtext")
    ]

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeScreen {
                path.append(OnboardingStep.features)
            }
            .navigationDestination(for: OnboardingStep.self) { step in
                switch step {
                case .features:
                    FeaturesScreen(features: features) {
                        path.append(OnboardingStep.legal)
                    }
                case .legal:
                    OnboardingLegalScreen(onAccept: onComplete)
                }
            }
        }
        .accentColor(AppColor.accent)
    }
}

enum OnboardingStep: Hashable {
    case features, legal
}

// MARK: - Welcome Screen

private struct WelcomeScreen: View {
    let onStart: () -> Void

    var body: some View {
        AppScreenBackground {
            VStack(spacing: 40) {
                Spacer()

                BrandLockup(
                    subtitle: "Field-ready inspection workflows with cleaner reports and secure records.",
                    markSize: 88,
                    alignment: .center
                )
                .frame(maxWidth: 420)
                .accessibilityLabel("NexGenSpec Logo")

                Text("The future of inspections is here.\nLet's get you set up.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Spacer()

                Button("Get Started") {
                    onStart()
                }
                .buttonStyle(AppPrimaryButtonStyle())
                .padding(.horizontal, 32)
                .accessibilityLabel("Get started with NexGenSpec")

                Spacer()
            }
            .padding()
        }
        .navigationBarBackButtonHidden(true)
    }
}

// MARK: - Features Screen

private struct FeaturesScreen: View {
    let features: [Feature]
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("What You Can Do")
                .font(.largeTitle.bold())
                .padding(.top, 24)
                .padding(.bottom, 8)

            List(features) { feature in
                HStack(alignment: .top, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppColor.accent.opacity(0.12))
                            .frame(width: 42, height: 42)
                        Image(systemName: feature.systemImageName)
                            .foregroundColor(AppColor.accent)
                            .font(.system(size: 18, weight: .semibold))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(feature.title)
                            .font(.headline)
                        Text(feature.description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)

            Text("LiDAR scanning requires iPad Pro or iPhone Pro. Voice commands require a Pro subscription.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            Button("Next") {
                onNext()
            }
            .buttonStyle(AppPrimaryButtonStyle())
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            .accessibilityLabel("Continue to terms and privacy")
        }
        .navigationTitle("Features")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Legal Acceptance Screen

private struct OnboardingLegalScreen: View {
    let onAccept: () -> Void

    @State private var viewedPrivacy = false
    @State private var viewedTerms = false
    @State private var accepted = false

    private var canAccept: Bool {
        accepted && viewedPrivacy && viewedTerms
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Terms & Privacy")
                .font(.largeTitle.bold())
                .padding(.top, 24)

            Text("Please review our Privacy Policy and Terms of Service before continuing.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(spacing: 12) {
                NavigationLink {
                    PrivacyPolicyContent()
                        .onDisappear { viewedPrivacy = true }
                } label: {
                    OnboardingLegalRow(
                        title: "Privacy Policy",
                        subtitle: "How your data is collected, stored, and protected.",
                        systemImage: "hand.raised.fill",
                        visited: viewedPrivacy
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    TermsOfServiceContent()
                        .onDisappear { viewedTerms = true }
                } label: {
                    OnboardingLegalRow(
                        title: "Terms of Service",
                        subtitle: "Rules governing your use of NexGenSpec.",
                        systemImage: "doc.text.fill",
                        visited: viewedTerms
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)

            if !viewedPrivacy || !viewedTerms {
                Text("Please read both documents to continue.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            Toggle(isOn: $accepted) {
                Text("I accept the Terms of Service and Privacy Policy")
                    .font(.subheadline.weight(.medium))
            }
            .disabled(!viewedPrivacy || !viewedTerms)
            .padding(.horizontal, 24)

            Button("Accept & Continue") {
                Diagnostics.logInfo("User accepted Terms and Privacy Policy via onboarding")
                onAccept()
            }
            .buttonStyle(AppPrimaryButtonStyle())
            .disabled(!canAccept)
            .opacity(canAccept ? 1 : 0.5)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            .accessibilityLabel("Accept terms and continue")
        }
        .navigationTitle("Terms & Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OnboardingLegalRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let visited: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppColor.accent.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColor.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if visited {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Preview

#if DEBUG
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(onComplete: {})
            .environment(\.colorScheme, .light)
        OnboardingView(onComplete: {})
            .environment(\.colorScheme, .dark)
    }
}
#endif
