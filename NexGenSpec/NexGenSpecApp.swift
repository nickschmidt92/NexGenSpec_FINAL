//
//  NexGenSpecApp.swift
//  NexGenSpec
//
//  On-the-go inspection reporting software. Denver, CO.
//

import SwiftUI

/// Run as early as possible to suppress _UIRemoteKeyboardPlaceholderView constraint log spam (iOS system bug).
private let _suppressKeyboardConstraintLog: Void = {
    UserDefaults.standard.set(false, forKey: "_UIConstraintBasedLayoutLogUnsatisfiable")
    UserDefaults.standard.set(false, forKey: "NSConstraintBasedLayoutLogUnsatisfiable")
}()

@main
struct NexGenSpecApp: App {
    @StateObject private var store = InspectionStore()
    @StateObject private var authManager = AuthManager()
    @StateObject private var subscriptions = SubscriptionManager()

    init() {
        _ = _suppressKeyboardConstraintLog
        FirebaseBootstrap.configureIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            rootContent
                .environmentObject(store)
                .environmentObject(authManager)
                .environmentObject(subscriptions)
                .tint(AppColor.accent)
                .preferredColorScheme(nil) // Respect system light/dark setting
                // Keep SubscriptionManager in sync with the signed-in Firebase user
                // so whitelisted admin emails get premium access automatically.
                .onAppear {
                    // T-01412: If a prior account deletion was interrupted before
                    // its local wipe finished (e.g. the user abandoned the receipt
                    // share sheet by killing the app), the Firebase account is gone
                    // but local data may remain. Complete the wipe now, then clear
                    // the retry flag. clearAllLocalData() also resets the store's
                    // in-memory metadata loaded during init().
                    if UserDefaults.standard.bool(forKey: "deletion-pending-wipe") {
                        store.clearAllLocalData()
                        UserDefaults.standard.removeObject(forKey: "deletion-pending-wipe")
                    }
                    subscriptions.applyCurrentUser(email: authManager.currentUsername)
                    // Re-confirm DeviceCheck trial bit on every cold launch so
                    // a Delete App + reinstall is detected immediately rather
                    // than after the abuser has already started a 4th inspection.
                    Task { await subscriptions.refreshDeviceCheckTrial() }
                }
                .onChange(of: authManager.currentUsername) { _, newEmail in
                    subscriptions.applyCurrentUser(email: newEmail)
                    // After sign-in (email/password or Sign in with Apple),
                    // re-check the device bit. The first call may have
                    // returned `.unknown(.notAuthenticated)` because no
                    // Firebase user existed yet — this catches that case.
                    if newEmail != nil {
                        Task { await subscriptions.refreshDeviceCheckTrial() }
                    }
                }
        }
    }

    /// Production launches always go through RootView. Only a `-screenshotMode`
    /// DEBUG launch is routed to the screenshot host (compiled out of Release).
    @ViewBuilder private var rootContent: some View {
        #if DEBUG
        if ScreenshotMode.isActive {
            ScreenshotHost()
        } else {
            RootView()
        }
        #else
        RootView()
        #endif
    }
}
