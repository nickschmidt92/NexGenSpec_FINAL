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
        ZStack {
            AppColor.brandPanelGradient
                .ignoresSafeArea()

            HexWatermark()
                .frame(width: 460, height: 520)
                .offset(x: 150, y: -210)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                BrandMark(size: 180)

                Text("NexGenSpec")
                    // Plain system .largeTitle to match the nav-bar titles and
                    // the other onboarding screens ("What You Can Do", "Terms &
                    // Privacy"), rather than the rounded AppFont.hero wordmark.
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                Text("The future of inspections is here.\nLet's get you set up.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .padding(.horizontal, 32)

                Spacer()

                Button("Get Started") {
                    onStart()
                }
                .buttonStyle(AppPrimaryButtonStyle())
                .padding(.horizontal, 32)
                .accessibilityLabel("Get started with NexGenSpec")

                Spacer()
                    .frame(height: 40)
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

            BrandMark(size: 96)
                .padding(.bottom, 8)

            List(features) { feature in
                HStack(alignment: .top, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppColor.accent.opacity(0.12))
                            .frame(width: 42, height: 42)
                        Image(systemName: feature.systemImageName)
                            .foregroundStyle(AppColor.accent)
                            .font(.system(size: 18, weight: .semibold))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(feature.title)
                            .font(.headline)
                        Text(feature.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)

            Text("LiDAR scanning requires iPad Pro or iPhone Pro.")
                .font(.footnote)
                .foregroundStyle(.secondary)
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

    @State private var accepted = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Terms & Privacy")
                .font(.largeTitle.bold())
                .padding(.top, 24)

            BrandMark(size: 96)
                .padding(.bottom, 4)

            Text("Tap a document below to read the full text. Toggle the switch to accept and continue.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(spacing: 12) {
                NavigationLink {
                    PrivacyPolicyContent()
                } label: {
                    OnboardingLegalRow(
                        title: "Privacy Policy",
                        subtitle: "How your data is collected, stored, and protected.",
                        systemImage: "hand.raised.fill"
                    )
                }
                .buttonStyle(.plain)
                .hoverEffect(.lift)

                NavigationLink {
                    TermsOfServiceContent()
                } label: {
                    OnboardingLegalRow(
                        title: "Terms of Service",
                        subtitle: "Rules governing your use of NexGenSpec.",
                        systemImage: "doc.text.fill"
                    )
                }
                .buttonStyle(.plain)
                .hoverEffect(.lift)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 12)

            Toggle(isOn: $accepted) {
                Text("I accept the Terms of Service and Privacy Policy")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 24)

            Button("Accept & Continue") {
                Diagnostics.logInfo("User accepted Terms and Privacy Policy via onboarding")
                AuditLog.log(event: "Terms and Privacy Policy accepted via onboarding")
                onAccept()
            }
            .buttonStyle(AppPrimaryButtonStyle())
            .disabled(!accepted)
            .opacity(accepted ? 1 : 0.5)
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

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
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
