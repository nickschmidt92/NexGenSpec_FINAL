//
//  SyncPort.swift
//  NexGenSpec
//
//  The seam contract between the local-first store and CloudKit sync (build 22).
//
//  Sync is injected behind this protocol so that (a) with the feature flag OFF a
//  `NoopSyncPort` compiles sync out of the hot path, (b) the port is unit-testable
//  with an in-memory fake, and (c) the local store has ZERO compile-time
//  dependency on CloudKit. The local-first per-UID store remains the source of
//  truth; a `SyncPort` is an OBSERVER/mirror — it never owns or resolves
//  `appRoot`, and it never wipes local data.
//  See docs/design/build-22-cloudkit-sync.md §5.
//

import Foundation

/// Coarse sync state for UI + observability. No PII.
public enum SyncStatus: Equatable {
    /// Feature flag off — sync code is inert.
    case off
    /// User chose local-only mode, or no iCloud account — running 100% locally.
    case localOnly
    /// Bound and caught up; nothing in flight.
    case idle
    /// Actively pushing/pulling.
    case syncing
    /// Temporarily detached for a known, non-error reason (e.g. iCloud account
    /// changed under the signed-in Firebase UID — refuse-and-isolate).
    case paused(reason: String)
    /// A surfaced failure (also logged to Diagnostics/Crashlytics).
    case error(String)
}

/// A local mutation the mirror should reflect to CloudKit. Carries identifiers
/// only — the port loads payloads from the local store on demand, so a change is
/// cheap to record on the existing write paths. Forward-looking; later slices add
/// cases as media/seeding land.
public enum SyncChange: Equatable {
    /// A version's `current.json` was written (draft edit or finalize). Carries
    /// the lightweight metadata so the mirror builds the record's queryable
    /// fields without re-decoding the payload; `meta.locked` distinguishes an
    /// immutable finalized record (never overwritten) from a draft (LWW).
    case versionUpserted(VersionMetadata)
    /// A version (and its inspection folder) was deleted locally.
    case versionDeleted(versionId: UUID)
    /// A media file under an inspection folder was written.
    case mediaUpserted(jobId: UUID, relativePath: String)
    /// A media file was removed.
    case mediaDeleted(jobId: UUID, relativePath: String)
}

/// The injected sync seam. All methods are no-ops in `NoopSyncPort`. Sendable so
/// it can be handed to the mirror's background flush and captured by the
/// coordinator's bind task; conformers are thread-safe (NoopSyncPort is stateless,
/// CloudKitSyncPort is lock-guarded).
public protocol SyncPort: AnyObject, Sendable {

    /// Current coarse status (drives the status UI + diagnostics). A later slice
    /// may add a Combine publisher; a plain property keeps slice 1 dependency-free.
    var status: SyncStatus { get }

    /// Start/resume the mirror for the given Firebase UID. No-op when the flag is
    /// off, local-only is set, or no iCloud account is available. Called from the
    /// identity seam (NexGenSpecApp `onChange(of: currentUID)`) and on
    /// CKAccountStatus changes. Reactive — never assumes Firebase-vs-iCloud
    /// readiness order.
    func bind(firebaseUID: String) async

    /// Stop the mirror. PURE DETACH — must never touch local data (landmine 2).
    func unbind()

    /// Record a local mutation to be mirrored. Called additively on the existing
    /// local write paths. Cheap; the port batches/coalesces.
    func recordLocalChange(_ change: SyncChange)

    /// One-time, idempotent, guarded local→cloud seeding for an existing
    /// (build-21) user. No-op once `SyncBinding.seededAt` is set.
    func seedIfNeeded(firebaseUID: String) async

    /// Pull remote changes and apply them locally (two-way sync). No-op when not
    /// bound. (slice 4)
    func pull() async

    /// Push any queued-but-unsent local changes now. Idempotent and a no-op when
    /// not bound or nothing is queued. Re-driven on bind and on app foreground so an
    /// edit made during a transient unbind window (paused / bind-in-flight) is not
    /// stranded in the queue (build 22 fix F).
    func flushPending() async
}
