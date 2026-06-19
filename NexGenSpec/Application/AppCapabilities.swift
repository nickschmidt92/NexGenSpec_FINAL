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
    /// Placeholder only — real entitlement lives in `SubscriptionManager`
    /// (`isPro` / `hasFeatureAccess`). Defaults to `.free` so that if anything
    /// ever reads this by mistake it fails CLOSED (treats the user as free)
    /// instead of silently granting Pro to everyone. Nothing reads it today.
    static var currentTier: SubscriptionTier { .free }
    static var syncContext: SyncContext { SyncContext() }
    static var canUseLiDAR: Bool { true }
    static var canUseAISummary: Bool { false }

    /// Weather auto-logging via the Open-Meteo API (replaced WeatherKit, whose
    /// JWT auth has been failing server-side on Apple's end). Enabled: a
    /// key-less URLSession request returns live data on device. The full fetch
    /// path is instrumented (os_log category "Weather" + Diagnostics log) so
    /// any failure is visible from a device. The weather UI appears in the
    /// inspection menu/overview and the report, and a fetch is attempted when
    /// an inspection is created without weather data. See WeatherService.swift.
    static var weatherLoggingEnabled: Bool { true }
}
