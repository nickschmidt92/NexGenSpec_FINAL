//
//  SyncConflictResolverTests.swift
//  NexGenSpecTests
//
//  Slice 4 (build 22) — the two-way conflict contract. Exhaustive cases for
//  finalized-immutability and draft last-writer-wins (docs §8). These are what
//  the P6 finalized-immutable-under-conflict gate re-verifies.
//

import XCTest
@testable import NexGenSpec

final class SyncConflictResolverTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_700_000_100) // later

    // MARK: - Upsert

    func testNewRemoteVersionIsApplied() {
        XCTAssertEqual(SyncConflictResolver.resolveUpsert(local: .absent, remoteLocked: false, remoteUpdatedAt: t0), .applyRemote)
    }

    func testLocalFinalizedIsNeverOverwritten() {
        let local = LocalVersionState(exists: true, isFinalized: true, updatedAt: t0)
        // Even a newer remote draft must not overwrite a finalized local report.
        XCTAssertEqual(SyncConflictResolver.resolveUpsert(local: local, remoteLocked: false, remoteUpdatedAt: t1), .keepLocal)
    }

    func testRemoteFinalizationSupersedesLocalDraft() {
        let local = LocalVersionState(exists: true, isFinalized: false, updatedAt: t1)
        // Remote is finalized (locked) → authoritative even if the local draft is newer.
        XCTAssertEqual(SyncConflictResolver.resolveUpsert(local: local, remoteLocked: true, remoteUpdatedAt: t0), .applyRemote)
    }

    func testDraftLastWriterWins() {
        let local = LocalVersionState(exists: true, isFinalized: false, updatedAt: t0)
        // Newer remote wins.
        XCTAssertEqual(SyncConflictResolver.resolveUpsert(local: local, remoteLocked: false, remoteUpdatedAt: t1), .applyRemote)
        // Older remote loses.
        let localNewer = LocalVersionState(exists: true, isFinalized: false, updatedAt: t1)
        XCTAssertEqual(SyncConflictResolver.resolveUpsert(local: localNewer, remoteLocked: false, remoteUpdatedAt: t0), .keepLocal)
    }

    func testUnknownLocalTimePrefersRemote() {
        let local = LocalVersionState(exists: true, isFinalized: false, updatedAt: nil)
        XCTAssertEqual(SyncConflictResolver.resolveUpsert(local: local, remoteLocked: false, remoteUpdatedAt: t0), .applyRemote)
    }

    // MARK: - Delete

    func testDeleteRemovesLocalDraft() {
        let local = LocalVersionState(exists: true, isFinalized: false, updatedAt: t0)
        XCTAssertEqual(SyncConflictResolver.resolveDelete(local: local), .deleteLocal)
    }

    func testDeleteNeverRemovesFinalized() {
        let local = LocalVersionState(exists: true, isFinalized: true, updatedAt: t0)
        XCTAssertEqual(SyncConflictResolver.resolveDelete(local: local), .keepLocal)
    }

    func testDeleteOfAbsentIsNoop() {
        XCTAssertEqual(SyncConflictResolver.resolveDelete(local: .absent), .keepLocal)
    }
}
