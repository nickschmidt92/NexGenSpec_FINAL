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
        // B-0045: the working store now lives in private Application Support, not
        // the file-shared Documents directory. Delete the old exposed copy here —
        // BEFORE the @StateObject `store` loads (its autoclosure is evaluated
        // lazily on first body render, strictly after init() returns), so no
        // sensitive data lingers in a browsable location.
        FilePaths.cleanupLegacyExposedStore()
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
                    if UserDefaults.standard.bool(forKey: "deletion-pending-wipe"), !store.isWiping {
                        // Reset in-memory state + gate writes synchronously (before
                        // the view renders) so the Dashboard never shows rows for
                        // files we're about to delete. The !isWiping guard makes a
                        // re-entrant onAppear a no-op (no double-fire). The retry
                        // flag is cleared only AFTER the disk wipe completes, so an
                        // interrupted wipe still retries on the next launch (T-01412).
                        store.beginWipe()
                        // Mirror finishLocalWipeAndDismiss() (AppSettingsView): the
                        // normal delete path clears the inspector profile, but if the
                        // app was force-quit during the receipt share sheet, only this
                        // recovery branch runs and previously OMITTED the profile wipe.
                        // Without it, the deleted user's name/license/email/phone
                        // survive in UserDefaults (nexgenspec.profile.*) and the live
                        // singleton — auto-filled on inspections, CC'd on invoices, and
                        // printed on client reports for the NEXT inspector. 5.1.1(v)
                        // residual-PII gap. clear() is @MainActor (we're in onAppear)
                        // and both wipes the in-memory singleton and persists empties.
                        InspectorProfile.shared.clear()
                        Task {
                            await store.performDiskWipe()
                            UserDefaults.standard.removeObject(forKey: "deletion-pending-wipe")
                        }
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
