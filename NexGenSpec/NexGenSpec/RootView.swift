//
//  RootView.swift
//  NexGenSpec
//
//  Entry: Login → T&C (if needed) → Dashboard. Store and AuthManager from environment.
//

import SwiftUI

private let termsAcceptedKey = "NexGenSpec.termsAccepted"

/// Entry point: Login, then Terms (if not yet accepted), then Dashboard with inspection list.
struct RootView: View {
    @EnvironmentObject private var store: InspectionStore
    @EnvironmentObject private var authManager: AuthManager
    @State private var termsAccepted = UserDefaults.standard.bool(forKey: termsAcceptedKey)

    var body: some View {
        Group {
            if !authManager.isAuthenticated {
                LoginView(authManager: authManager)
            } else if !termsAccepted {
                TermsAndConditionsView(onAcknowledge: .constant({
                    UserDefaults.standard.set(true, forKey: termsAcceptedKey)
                    termsAccepted = true
                }))
            } else {
                DashboardView()
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
