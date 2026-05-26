//
//  AppCapabilities.swift
//  NexGenSpec
//
//  Extension points for cloud sync, multi-user, AI, subscriptions. No implementation; allows future wiring without refactor.
//

import Foundation

/// Placeholder for future subscription/tier checks. Replace with real entitlement logic when adding paywall.
enum SubscriptionTier {
    case free
    case professional
    case team
}

/// Future: cloud sync context (user id, last sync, conflict resolution). Keep inspection IDs stable for sync.
struct SyncContext {
    var userId: String?
    var lastSyncedAt: Date?
}

/// Future: feature flags or tier-based capability. Use to gate LiDAR, AI summary, team features.
enum AppCapabilities {
    static var currentTier: SubscriptionTier { .professional }
    static var syncContext: SyncContext { SyncContext() }
    static var canUseLiDAR: Bool { true }
    static var canUseAISummary: Bool { false }

    /// Weather auto-logging via WeatherKit. Enabled: the App ID is registered
    /// for the WeatherKit service on the Apple Developer portal and it returns
    /// live data in the simulator. On-device fetches are still under
    /// investigation (data does not populate on a real device despite the
    /// entitlement + manual profiles) — the full fetch path is now
    /// instrumented (os_log category "WeatherKit" + Diagnostics log) so the
    /// exact failure is visible from a device. The weather UI appears in the
    /// inspection menu/overview and the report, and a fetch is attempted when
    /// an inspection is created without weather data. See WeatherService.swift.
    static var weatherLoggingEnabled: Bool { true }
}
