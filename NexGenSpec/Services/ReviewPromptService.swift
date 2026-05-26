//
//  ReviewPromptService.swift
//  NexGenSpec
//
//  Requests an App Store review at a positive milestone — when the inspector
//  finalizes their 2nd inspection — following Apple's HIG guidance to ask only
//  after the user has gotten real value from the app.
//

import Foundation
import StoreKit
import UIKit

@MainActor
enum ReviewPromptService {

    private enum Key {
        /// Count of *successfully finalized* inspections (not merely created).
        static let finalizedCount = "nexgenspec.review.finalizedInspectionCount"
        /// One-shot guard: set once the system review prompt has been requested.
        static let didRequest = "nexgenspec.review.didRequestReview"
    }

    /// Finalized-inspection milestone at which we surface the review prompt.
    private static let promptThreshold = 2

    /// Call exactly once per **successful** inspection finalization. Increments
    /// the completed-inspection counter and, the first time it reaches the
    /// milestone, asks StoreKit to surface the review prompt — at most once for
    /// the lifetime of the install.
    ///
    /// `SKStoreReviewController` independently throttles how often the dialog
    /// can appear, so a request is best-effort; we never re-ask regardless.
    static func recordFinalizationAndMaybeRequestReview() {
        let defaults = UserDefaults.standard

        // One-shot: never prompt twice.
        guard !defaults.bool(forKey: Key.didRequest) else { return }

        let newCount = defaults.integer(forKey: Key.finalizedCount) + 1
        defaults.set(newCount, forKey: Key.finalizedCount)

        guard newCount >= promptThreshold else { return }

        // Milestone reached. Surface the prompt and record the one-shot only if
        // it actually fired, so a build that can't present it (DEBUG) doesn't
        // silently burn the single lifetime opportunity.
        if requestReview() {
            defaults.set(true, forKey: Key.didRequest)
        }
    }

    /// Surfaces the system review prompt in the active window scene. Returns
    /// `true` when the request was issued. No-op in DEBUG builds so the dialog
    /// only fires in shipping (App Store / TestFlight) builds.
    @discardableResult
    private static func requestReview() -> Bool {
        #if DEBUG
        return false
        #else
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return false }
        SKStoreReviewController.requestReview(in: scene)
        return true
        #endif
    }
}
