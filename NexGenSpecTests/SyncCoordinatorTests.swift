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

/// A CloudAccountProviding stub with a mutable token, so tests can simulate a benign
/// same-account `.CKAccountChanged` (token unchanged) vs a real iCloud switch (token
/// changes) WITHOUT touching CloudKit.
private final class StubAccount: CloudAccountProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _token: String?
    init(token: String?) { _token = token }
    var token: String? {
        get { lock.withLock { _token } }
        set { lock.withLock { _token = newValue } }
    }
    func currentUserToken() async -> String? { lock.withLock { _token } }
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
        let coord = SyncCoordinator(isEnabled: { false }, account: StubAccount(token: "tok"), makeCloudPort: { fake })

        coord.userDidChange(uid: "u")
        coord.recordLocalChange(.versionUpserted(meta()))

        XCTAssertEqual(fake.changeCount, 0, "Flag OFF ⇒ nothing forwarded to a cloud port.")
        XCTAssertEqual(fake.bindCount, 0, "Flag OFF ⇒ the cloud port is never even constructed/bound.")
        XCTAssertEqual(coord.status, .off)
    }

    func testEnabledRoutesChangesToCloudPort() {
        let fake = FakePort()
        let coord = SyncCoordinator(isEnabled: { true }, account: StubAccount(token: "tok"), makeCloudPort: { fake })

        coord.userDidChange(uid: "u")   // selects the cloud port synchronously
        coord.recordLocalChange(.versionDeleted(versionId: UUID()))

        XCTAssertEqual(fake.changeCount, 1, "Enabled ⇒ changes forwarded to the cloud port.")
    }

    func testLogoutDetachesBackToNoop() {
        let fake = FakePort()
        let coord = SyncCoordinator(isEnabled: { true }, account: StubAccount(token: "tok"), makeCloudPort: { fake })

        coord.userDidChange(uid: "u")
        coord.userDidChange(uid: nil)   // logout → detach to Noop
        coord.recordLocalChange(.versionUpserted(meta()))

        XCTAssertEqual(fake.changeCount, 0, "After logout, changes are not forwarded to the cloud port.")
        XCTAssertEqual(coord.status, .off)
    }

    // MARK: - Foreground pull (slice 4c)

    func testPullNowRoutesToActiveCloudPort() async {
        let fake = FakePort()
        let coord = SyncCoordinator(isEnabled: { true }, account: StubAccount(token: "tok"), makeCloudPort: { fake })

        coord.userDidChange(uid: "u")   // selects the cloud port synchronously
        coord.pullNow()                 // e.g. app returned to foreground

        // pullNow dispatches into a Task; let it run.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThanOrEqual(fake.pulls, 1, "pullNow forwards a pull to the active cloud port.")
    }

    func testPullNowIsInertWhenDisabled() async {
        let fake = FakePort()
        let coord = SyncCoordinator(isEnabled: { false }, account: StubAccount(token: "tok"), makeCloudPort: { fake })

        coord.userDidChange(uid: "u")   // stays Noop (flag off)
        coord.pullNow()

        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fake.pulls, 0, "Flag OFF ⇒ pullNow never reaches a cloud port (Noop no-op).")
    }

    // MARK: - Foreground live-pull poll (build 32)

    func testForegroundPollingPullsWhileActiveThenStops() async {
        let fake = FakePort()
        let coord = SyncCoordinator(
            isEnabled: { true }, account: StubAccount(token: "tok"),
            makeCloudPort: { fake }, foregroundPollInterval: .milliseconds(20)
        )
        coord.userDidChange(uid: "u")   // bind cloud port synchronously

        coord.startForegroundPolling()
        try? await Task.sleep(nanoseconds: 150_000_000)   // ~7 intervals
        coord.stopForegroundPolling()
        // stop() cancels the poll loop, but a pullNow() the loop already
        // dispatched into its own Task can still land after cancellation —
        // let any in-flight pull settle BEFORE snapshotting, or the final
        // equality assert flakes on scheduler timing (seen as 7 != 6).
        try? await Task.sleep(nanoseconds: 40_000_000)
        let afterStop = fake.pulls
        XCTAssertGreaterThan(afterStop, 1, "Polling repeatedly pulls while active.")

        // No further pulls after stop (5 would-be intervals of silence).
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fake.pulls, afterStop, "stop() halts the poll — no pulls after stop.")
    }

    func testStartForegroundPollingIsIdempotent() async {
        let fake = FakePort()
        let coord = SyncCoordinator(
            isEnabled: { true }, account: StubAccount(token: "tok"),
            makeCloudPort: { fake }, foregroundPollInterval: .milliseconds(20)
        )
        coord.userDidChange(uid: "u")

        coord.startForegroundPolling()
        coord.startForegroundPolling()   // must NOT spawn a second poll task
        try? await Task.sleep(nanoseconds: 100_000_000)
        coord.stopForegroundPolling()
        let afterStop = fake.pulls

        // A single stop() must fully halt polling; if a second task had leaked,
        // pulls would keep climbing here.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fake.pulls, afterStop, "A second start must not leak a task — stop fully halts.")
    }

    func testPullAndRefreshForwardsToActivePort() async {
        let fake = FakePort()
        let coord = SyncCoordinator(isEnabled: { true }, account: StubAccount(token: "tok"), makeCloudPort: { fake })
        coord.userDidChange(uid: "u")

        await coord.pullAndRefresh()   // pull-to-refresh path
        XCTAssertGreaterThanOrEqual(fake.pulls, 1, "pull-to-refresh forwards a real pull to the active port.")
        XCTAssertGreaterThanOrEqual(fake.flushCount, 1, "pull-to-refresh also flushes pending outbound changes.")
    }

    func testPullAndRefreshIsInertWhenDisabled() async {
        let fake = FakePort()
        let coord = SyncCoordinator(isEnabled: { false }, account: StubAccount(token: "tok"), makeCloudPort: { fake })
        coord.userDidChange(uid: "u")   // stays Noop

        await coord.pullAndRefresh()
        XCTAssertEqual(fake.pulls, 0, "Flag OFF ⇒ pull-to-refresh is a Noop pull.")
    }

    // MARK: - .CKAccountChanged identity gate (NEW-1)

    func testSameAccountChangeKeepsPortButSwitchRebuilds() async {
        // A benign same-account .CKAccountChanged (iCloud token unchanged) must NOT
        // tear down + rebuild the port — that would clear the un-pushed outbound queue
        // (NEW-1). A real switch (token changes) MUST rebuild (cross-account isolation).
        var buildCount = 0
        let account = StubAccount(token: "tokA")
        let coord = SyncCoordinator(
            isEnabled: { true },
            account: account,
            makeCloudPort: { buildCount += 1; return FakePort() }
        )

        coord.userDidChange(uid: "u")   // rebind() builds port #1 synchronously
        XCTAssertEqual(buildCount, 1, "Initial bind builds the cloud port once.")

        // Same iCloud account → no rebuild. handleAccountChange() awaits the in-flight
        // bind so boundCloudToken is settled before the comparison — deterministic, no
        // sleep (this await is also the NEW-1 race fix).
        await coord.handleAccountChange()
        XCTAssertEqual(buildCount, 1, "A same-account CKAccountChange must NOT rebuild the port (NEW-1).")

        // Genuine iCloud account switch → rebuild.
        account.token = "tokB"
        await coord.handleAccountChange()
        XCTAssertEqual(buildCount, 2, "A real iCloud account switch rebuilds the port (cross-account isolation).")
    }
}
