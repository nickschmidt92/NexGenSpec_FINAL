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
            RootView()
                .environmentObject(store)
                .environmentObject(authManager)
                .environmentObject(subscriptions)
                .tint(AppColor.accent)
        }
    }
}
