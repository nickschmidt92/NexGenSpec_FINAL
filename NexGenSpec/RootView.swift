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

/// Entry point: Login, then Terms (if not yet accepted), then Dashboard with inspection list.
struct RootView: View {
    @EnvironmentObject private var store: InspectionStore
    @EnvironmentObject private var authManager: AuthManager
    @State private var termsAccepted = false

    var body: some View {
        Group {
            if !authManager.isAuthenticated {
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
                DashboardView()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96)),
                        removal: .opacity
                    ))
            }
        }
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
