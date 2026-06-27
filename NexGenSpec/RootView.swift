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
        .sheet(isPresented: Binding(
            // Sequence the two REQUIRED prompts so they never contend for the same
            // presentation slot: the inspector-name sheet has priority, and the
            // fallback-email sheet presents only once the name prompt is resolved.
            // Two simultaneous `.sheet(isPresented:)` on one view race (SwiftUI
            // presents one and drops the other) — this hit a brand-new Apple user
            // who hid BOTH their name and email. The setter still writes the
            // underlying flag, so Skip/Save dismiss correctly.
            get: { authManager.pendingFallbackEmailPrompt && !authManager.pendingInspectorNamePrompt },
            set: { authManager.pendingFallbackEmailPrompt = $0 }
        )) {
            FallbackEmailPromptSheet(authManager: authManager)
                .interactiveDismissDisabled()
                .onAppear {
                    AuditLog.log(event: "FallbackEmailPromptSheet onAppear")
                }
        }
        .sheet(isPresented: $authManager.pendingInspectorNamePrompt) {
            InspectorNamePromptSheet(authManager: authManager)
                .interactiveDismissDisabled()
        }
        .onChange(of: authManager.pendingFallbackEmailPrompt) { _, newValue in
            AuditLog.log(event: "RootView observed pendingFallbackEmailPrompt → \(newValue)")
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

/// One-time, REQUIRED capture of the inspector's human name. Presented when the
/// signed-in account has no name (existing users created before name capture,
/// Apple sign-ins where the name was hidden, or Apple re-logins where Apple no
/// longer returns the name). The name is printed on the client report; without
/// it the report would fall back to the login email. There is intentionally no
/// Skip button and the sheet is non-dismissible — a name is mandatory.
private struct InspectorNamePromptSheet: View {
    @ObservedObject var authManager: AuthManager
    @State private var name = ""
    @State private var inlineError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Enter your full name as it should appear on inspection reports. This is required.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField("Full name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.name)
                        .autocorrectionDisabled()
                } header: {
                    Text("Inspector name")
                } footer: {
                    if let inlineError {
                        Text(inlineError).foregroundStyle(.red).font(.caption)
                    } else {
                        Text("You can change this later in your inspector profile.")
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Your Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        inlineError = nil
        Task { @MainActor in
            let ok = await authManager.setInspectorName(name)
            if ok {
                dismiss()
            } else {
                inlineError = "Please enter your full name."
            }
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
