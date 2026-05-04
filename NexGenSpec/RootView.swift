//
//  RootView.swift
//  NexGenSpec
//
//  Entry: Login → T&C (if needed) → Dashboard. Store and AuthManager from environment.
//

import SwiftUI

enum TermsAcceptanceStore {
    static let currentVersion = "2026-02-07"

    static func hasAcceptedTerms(
        username: String,
        version: String = currentVersion,
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: key(for: username, version: version))
    }

    static func markAccepted(
        username: String,
        version: String = currentVersion,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(true, forKey: key(for: username, version: version))
    }

    static func key(for username: String, version: String = currentVersion) -> String {
        "NexGenSpec.termsAccepted.\(version).\(normalizedUsername(username))"
    }

    private static func normalizedUsername(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Entry point: Onboarding (first launch) → Login → Terms (if not yet accepted) → Dashboard.
struct RootView: View {
    @EnvironmentObject private var store: InspectionStore
    @EnvironmentObject private var authManager: AuthManager
    @AppStorage("nexgenspec.onboarding.completed") private var onboardingCompleted = false

    var body: some View {
        Group {
            if !onboardingCompleted {
                OnboardingView {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        onboardingCompleted = true
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .opacity.combined(with: .move(edge: .leading))
                ))
            } else if !authManager.isAuthenticated {
                LoginView(authManager: authManager)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .leading)),
                        removal: .opacity.combined(with: .move(edge: .leading))
                    ))
            } else {
                MainTabView()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96)),
                        removal: .opacity
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: onboardingCompleted)
        .animation(.easeInOut(duration: 0.35), value: authManager.isAuthenticated)
        .sheet(isPresented: $authManager.pendingFallbackEmailPrompt) {
            FallbackEmailPromptSheet(authManager: authManager)
                .interactiveDismissDisabled()
        }
    }
}

/// Captured at signup (both Sign in with Apple and email/password flows). The
/// fallback gives us an out-of-band way to deliver receipts and account-recovery
/// messages if the inspector loses access to their primary email — Apple's
/// private-relay revocation, provider lockout, account hijack, or simple
/// abandonment of the original address.
private struct FallbackEmailPromptSheet: View {
    @ObservedObject var authManager: AuthManager
    @State private var email = ""
    @State private var inlineError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Add a fallback email so we can reach you for receipts, account recovery, or important service notices if you ever lose access to your primary email.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField("you@example.com", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textContentType(.emailAddress)
                } header: {
                    Text("Fallback email")
                } footer: {
                    if let inlineError {
                        Text(inlineError).foregroundStyle(.red).font(.caption)
                    } else {
                        Text("We never send marketing email here without your opt-in. Skipping is allowed but not recommended.")
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Account Recovery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        authManager.skipFallbackEmailPrompt()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        inlineError = nil
        let ok = authManager.setFallbackEmail(email)
        if ok {
            dismiss()
        } else {
            inlineError = "Please enter a valid email address."
        }
    }
}

#if DEBUG
#Preview {
    RootView()
        .environmentObject(InspectionStore())
        .environmentObject(AuthManager())
}
#endif
