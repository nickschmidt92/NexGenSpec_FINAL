//
//  SyncIdentityResolver.swift
//  NexGenSpec
//
//  THE identity contract core (landmine 1). Given the local Firebase UID, the
//  current iCloud user token, and any previously-persisted binding, decides
//  whether sync may bind, resume, or must REFUSE-AND-ISOLATE. Pure and total —
//  every edge has an explicit branch — so it is exhaustively unit-testable and is
//  the function P6 adversarially verifies. The local store path NEVER keys on the
//  Apple ID; this resolver only governs whether the CloudKit MIRROR attaches.
//  See docs/design/build-22-cloudkit-sync.md §2.3.
//

import Foundation

/// The outcome of resolving identity for a sign-in / account-status event.
public enum SyncIdentityDecision: Equatable {
    /// No iCloud account available → run 100% locally (graceful degradation).
    case noAccount
    /// No binding yet for this UID → create the binding + this UID's zone.
    case bindNew(zoneName: String)
    /// Existing binding matches the current iCloud user → resume the mirror.
    case resume(SyncBinding)
    /// The iCloud user changed under this Firebase UID → STOP. Never push this
    /// UID's data to the new iCloud, never pull the new iCloud's data in. The
    /// local store is untouched. Fail-closed.
    case refuseAndIsolate(reason: String)
}

public enum SyncIdentityResolver {

    /// - Parameters:
    ///   - firebaseUID: the local store key (never the Apple ID).
    ///   - cloudToken: opaque token for the current iCloud user, or nil if no
    ///     iCloud account is available.
    ///   - existing: the persisted binding for this UID, if any.
    public static func resolve(
        firebaseUID: String,
        cloudToken: String?,
        existing: SyncBinding?
    ) -> SyncIdentityDecision {
        // No iCloud → local-only. (Edge D.)
        guard let cloudToken else { return .noAccount }

        guard let existing else {
            // First bind for this UID — its own zone. (Edges A first-run, C: a
            // second app account on the same iCloud gets a DISTINCT zone because
            // zoneName is derived from the UID, not the iCloud user.)
            return .bindNew(zoneName: CloudKitSchema.zoneName(forFirebaseUID: firebaseUID))
        }

        // A binding is keyed by UID; if somehow it belongs to another UID, treat
        // as no binding and create this UID's own. (Defensive; should not happen.)
        guard existing.firebaseUID == firebaseUID else {
            return .bindNew(zoneName: CloudKitSchema.zoneName(forFirebaseUID: firebaseUID))
        }

        // Same iCloud user as when we bound → resume. (Edges A steady, E re-login.)
        if existing.cloudUserToken == cloudToken {
            return .resume(existing)
        }

        // The iCloud user changed under this Firebase UID. (Edges B, F.)
        // Refuse and isolate — never cross data between two iClouds.
        return .refuseAndIsolate(
            reason: "The iCloud account on this device changed. Sync is paused to keep your inspections from mixing between accounts. Your local data is safe."
        )
    }
}
