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
    @State private var termsAccepted = false
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
            } else if !termsAccepted {
                TermsAndConditionsView(onAcknowledge: .constant(acknowledgeCallback))
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
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
        .animation(.easeInOut(duration: 0.35), value: termsAccepted)
        .onAppear(perform: refreshTermsAcceptance)
        .onChange(of: authManager.isAuthenticated) { _, _ in
            refreshTermsAcceptance()
        }
        .onChange(of: authManager.currentUsername) { _, _ in
            refreshTermsAcceptance()
        }
    }

    private var acknowledgeCallback: (() -> Void)? {
        guard authManager.isAuthenticated,
              let username = authManager.currentUsername,
              !username.isEmpty else {
            return nil
        }

        return {
            TermsAcceptanceStore.markAccepted(username: username)
            termsAccepted = true
        }
    }

    private func refreshTermsAcceptance() {
        guard authManager.isAuthenticated,
              let username = authManager.currentUsername,
              !username.isEmpty else {
            termsAccepted = false
            return
        }

        termsAccepted = TermsAcceptanceStore.hasAcceptedTerms(username: username)
    }
}

#if DEBUG
#Preview {
    RootView()
        .environmentObject(InspectionStore())
        .environmentObject(AuthManager())
}
#endif
