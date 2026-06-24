//
//  SyncConflictResolver.swift
//  NexGenSpec
//
//  The two-way conflict contract (build 22, slice 4). Pure and total — every
//  case has an explicit branch — so it is exhaustively unit-testable and is what
//  P6 re-verifies. Finalized/locked versions are IMMUTABLE (never overwritten,
//  never deleted via sync); drafts use last-writer-wins by update time; a remote
//  finalization supersedes a local draft of the same version.
//  See docs/design/build-22-cloudkit-sync.md §8.
//

import Foundation

/// What to do with a local version given a remote change.
public enum SyncApplyDecision: Equatable {
    /// Write the remote payload to the local store.
    case applyRemote
    /// Ignore the remote change; the local copy wins.
    case keepLocal
    /// Remove the local version (remote tombstone).
    case deleteLocal
}

/// The local store's view of one version, for conflict resolution. `updatedAt` is
/// the local last-edit clock used for draft last-writer-wins.
public struct LocalVersionState: Equatable {
    public let exists: Bool
    public let isFinalized: Bool
    public let updatedAt: Date?
    /// True when the local `current.json` EXISTS but was TRANSIENTLY unreadable
    /// (data-protection while the device is locked / I/O) — distinct from a genuine
    /// decode failure. The pull HOLDS the change token instead of settling this
    /// record, so the next pull retries rather than permanently skipping a legitimate
    /// remote update (build 22 fix D). Defaults false; never set for a clean read.
    public let readFailed: Bool

    public init(exists: Bool, isFinalized: Bool, updatedAt: Date?, readFailed: Bool = false) {
        self.exists = exists
        self.isFinalized = isFinalized
        self.updatedAt = updatedAt
        self.readFailed = readFailed
    }

    public static let absent = LocalVersionState(exists: false, isFinalized: false, updatedAt: nil)
}

public enum SyncConflictResolver {

    /// Resolve a remote UPSERT against local state.
    public static func resolveUpsert(
        local: LocalVersionState,
        remoteLocked: Bool,
        remoteUpdatedAt: Date
    ) -> SyncApplyDecision {
        // New on this device → take it.
        guard local.exists else { return .applyRemote }
        // Local is finalized → immutable; never overwrite a locked report.
        if local.isFinalized { return .keepLocal }
        // Remote is finalized but local is still a draft → finalization is
        // authoritative and supersedes the local draft of the same version.
        if remoteLocked { return .applyRemote }
        // Both drafts → last-writer-wins by update time. Unknown local time ⇒
        // prefer the remote (it carries a definite server timestamp).
        guard let localUpdatedAt = local.updatedAt else { return .applyRemote }
        return remoteUpdatedAt > localUpdatedAt ? .applyRemote : .keepLocal
    }

    /// Resolve a remote DELETE (tombstone) against local state.
    public static func resolveDelete(local: LocalVersionState) -> SyncApplyDecision {
        // Already gone → nothing to do.
        guard local.exists else { return .keepLocal }
        // Never delete a finalized report via sync — it is the immutable legal
        // record; a stray remote tombstone must not erase it.
        if local.isFinalized { return .keepLocal }
        return .deleteLocal
    }
}
