//
//  SyncCoordinatorTests.swift
//  NexGenSpecTests
//
//  Slice 2c (build 22) — the SyncCoordinator's port selection. Proves the gate
//  that makes 2c safe to ship: with sync disabled the coordinator stays inert
//  (no cloud port is ever constructed, nothing is forwarded), and only when
//  enabled does it route changes to the cloud port. Uses a fake port (no
//  CloudKit). The live behavior is device-verified.
//

import XCTest
@testable import NexGenSpec

private final class FakePort: SyncPort, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var boundUIDs: [String] = []
    private(set) var changes: [SyncChange] = []
    private(set) var pullCount = 0
    var status: SyncStatus = .idle

    private(set) var flushCount = 0
    func bind(firebaseUID: String) async { lock.withLock { boundUIDs.append(firebaseUID) } }
    func unbind() {}
    func recordLocalChange(_ change: SyncChange) { lock.withLock { changes.append(change) } }
    func seedIfNeeded(firebaseUID: String) async {}
    func pull() async { lock.withLock { pullCount += 1 } }
    func flushPending() async { lock.withLock { flushCount += 1 } }

    var changeCount: Int { lock.withLock { changes.count } }
    var bindCount: Int { lock.withLock { boundUIDs.count } }
    var pulls: Int { lock.withLock { pullCount } }
}

@MainActor
final class SyncCoordinatorTests: XCTestCase {

    private func meta() -> VersionMetadata {
        VersionMetadata(
            id: UUID(), inspectionId: UUID(), versionNumber: 1, status: .draft,
            finalizedAt: nil, locked: false, clientName: "", propertyAddress: "", inspectionDate: Date()
        )
    }

    func testDisabledStaysInertAndForwardsNothing() {
        let fake = FakePort()
        let coord = SyncCoordinator(isEnabled: { false }, makeCloudPort: { fake })

        coord.userDidChange(uid: "u")
        coord.recordLocalChange(.versionUpserted(meta()))

        XCTAssertEqual(fake.changeCount, 0, "Flag OFF ⇒ nothing forwarded to a cloud port.")
        XCTAssertEqual(fake.bindCount, 0, "Flag OFF ⇒ the cloud port is never even constructed/bound.")
        XCTAssertEqual(coord.status, .off)
    }

    func testEnabledRoutesChangesToCloudPort() {
        let fake = FakePort()
        let coord = SyncCoordinator(isEnabled: { true }, makeCloudPort: { fake })

        coord.userDidChange(uid: "u")   // selects the cloud port synchronously
        coord.recordLocalChange(.versionDeleted(versionId: UUID()))

        XCTAssertEqual(fake.changeCount, 1, "Enabled ⇒ changes forwarded to the cloud port.")
    }

    func testLogoutDetachesBackToNoop() {
        let fake = FakePort()
        let coord = SyncCoordinator(isEnabled: { true }, makeCloudPort: { fake })

        coord.userDidChange(uid: "u")
        coord.userDidChange(uid: nil)   // logout → detach to Noop
        coord.recordLocalChange(.versionUpserted(meta()))

        XCTAssertEqual(fake.changeCount, 0, "After logout, changes are not forwarded to the cloud port.")
        XCTAssertEqual(coord.status, .off)
    }

    // MARK: - Foreground pull (slice 4c)

    func testPullNowRoutesToActiveCloudPort() async {
        let fake = FakePort()
        let coord = SyncCoordinator(isEnabled: { true }, makeCloudPort: { fake })

        coord.userDidChange(uid: "u")   // selects the cloud port synchronously
        coord.pullNow()                 // e.g. app returned to foreground

        // pullNow dispatches into a Task; let it run.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThanOrEqual(fake.pulls, 1, "pullNow forwards a pull to the active cloud port.")
    }

    func testPullNowIsInertWhenDisabled() async {
        let fake = FakePort()
        let coord = SyncCoordinator(isEnabled: { false }, makeCloudPort: { fake })

        coord.userDidChange(uid: "u")   // stays Noop (flag off)
        coord.pullNow()

        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fake.pulls, 0, "Flag OFF ⇒ pullNow never reaches a cloud port (Noop no-op).")
    }
}
