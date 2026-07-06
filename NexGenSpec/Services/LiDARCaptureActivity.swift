//
//  LiDARCaptureActivity.swift
//  NexGenSpec
//
//  Tracks whether a RoomPlan capture session is live so heavy background
//  work (CloudKit foreground pull) can defer instead of contending with
//  ARKit for the main thread mid-scan. No RoomPlan import on purpose —
//  SyncCoordinator must see this type on every platform.
//

import Foundation

@MainActor
final class LiDARCaptureActivity {
    static let shared = LiDARCaptureActivity()
    private init() {}

    private(set) var isActive = false
    private var pendingPull: (() -> Void)?

    func captureDidStart() { isActive = true }

    func captureDidEnd() {
        isActive = false
        let deferred = pendingPull
        pendingPull = nil
        deferred?()
    }

    /// One-shot deferred pull; last writer wins (a single catch-up pull
    /// covers any number of skipped triggers).
    func setPendingPull(_ block: @escaping () -> Void) { pendingPull = block }
}
