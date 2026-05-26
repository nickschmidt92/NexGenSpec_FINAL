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

    /// Weather auto-logging via WeatherKit. The App ID is now registered for
    /// the WeatherKit service on the Apple Developer portal and the JWT issue
    /// is resolved — WeatherKit returns live data on device, so the feature is
    /// enabled. The weather UI appears in the inspection menu/overview and the
    /// report, and a WeatherKit fetch is attempted when an inspection is created
    /// without weather data.
    static var weatherLoggingEnabled: Bool { true }
}
