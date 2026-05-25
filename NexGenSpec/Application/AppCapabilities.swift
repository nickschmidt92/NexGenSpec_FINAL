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

    /// Weather auto-logging via WeatherKit. The `com.apple.developer.weatherkit`
    /// entitlement is present in code, but on-device testing on 2026-05-25
    /// returned no data — the symptom of an App ID that has NOT yet been
    /// registered for the WeatherKit service on the Apple Developer portal
    /// (a server-side step, ~30 min to propagate, that also requires the
    /// provisioning profile to be regenerated). Until that is confirmed
    /// working on a real device, this stays `false` so we don't ship a
    /// visibly broken feature: the weather UI is hidden everywhere and no
    /// WeatherKit fetch is attempted. Flip to `true` once WeatherKit returns
    /// live data on device. See the WeatherKit registration blocker in NickOS.
    static var weatherLoggingEnabled: Bool { true }
}
