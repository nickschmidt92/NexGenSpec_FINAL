//
//  SyncScaffoldTests.swift
//  NexGenSpecTests
//
//  Slice 1 (build 22 CloudKit sync) regression tests. Proves the sync scaffold is
//  inert: the feature flag is OFF by default, the NoopSyncPort does nothing, and
//  the Keychain binding table round-trips with per-UID isolation. The flag-OFF
//  guarantee is the load-bearing "behaviorally identical to build 21" invariant.
//  See docs/design/build-22-cloudkit-sync.md §5, §6, §18.
//

import XCTest
@testable import NexGenSpec

final class SyncScaffoldTests: XCTestCase {

    // MARK: - Feature flag

    func testSyncFeatureFlagIsOffByDefault() {
        // The single guarantee that makes build 22 safe to ship dark: with the
        // flag off, no sync may run.
        XCTAssertFalse(SyncFeature.isEnabled, "Sync must ship OFF by default.")
        XCTAssertFalse(SyncFeature.effectiveSyncAllowed, "Flag off ⇒ no sync allowed.")
    }

    func testLocalOnlyModeForcesNoSyncAndDefaultsFalse() {
        let key = SyncFeature.localOnlyModeKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(SyncFeature.isLocalOnlyMode, "Local-only mode defaults to false.")

        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(SyncFeature.isLocalOnlyMode)
        // Fail-closed: local-only wins regardless of the master switch.
        XCTAssertFalse(SyncFeature.effectiveSyncAllowed, "Local-only mode must force no sync.")
    }

    // MARK: - NoopSyncPort is inert

    func testNoopSyncPortIsInert() async {
        let port: SyncPort = NoopSyncPort()
        XCTAssertEqual(port.status, .off)

        // None of these may crash, throw, or change status.
        let meta = VersionMetadata(
            id: UUID(), inspectionId: UUID(), versionNumber: 1, status: .draft,
            finalizedAt: nil, locked: false, clientName: "", propertyAddress: "", inspectionDate: Date()
        )
        await port.bind(firebaseUID: "uid-123")
        port.recordLocalChange(.versionUpserted(meta))
        port.recordLocalChange(.versionDeleted(versionId: UUID()))
        await port.seedIfNeeded(firebaseUID: "uid-123")
        port.unbind()

        XCTAssertEqual(port.status, .off, "NoopSyncPort status never changes.")
    }

    // MARK: - SyncBinding Codable

    func testSyncBindingCodableRoundTrip() throws {
        let binding = SyncBinding(
            firebaseUID: "uid-abc",
            cloudUserToken: "tok-xyz",
            zoneName: "ngs-hashed",
            boundAt: Date(timeIntervalSince1970: 1_700_000_000),
            seededAt: Date(timeIntervalSince1970: 1_700_000_100),
            schemaVersion: 1
        )
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(SyncBinding.self, from: data)
        XCTAssertEqual(binding, decoded)
    }

    // MARK: - SyncBindingStore (Keychain) round-trip + isolation

    /// Unique per-test service so we never touch the real binding store.
    private func makeTestService() -> String { "com.nexgenspec.test.syncBinding.\(UUID().uuidString)" }

    func testBindingStoreRoundTripAndPerUIDIsolation() throws {
        let service = makeTestService()
        let uidA = "uidA-\(UUID().uuidString)"
        let uidB = "uidB-\(UUID().uuidString)"
        defer {
            SyncBindingStore.delete(forUID: uidA, service: service)
            SyncBindingStore.delete(forUID: uidB, service: service)
        }

        let bindingA = SyncBinding(
            firebaseUID: uidA,
            cloudUserToken: "tokA",
            zoneName: "zoneA",
            boundAt: Date()
        )
        let saved = SyncBindingStore.save(bindingA, service: service)
        try XCTSkipUnless(saved, "Keychain unavailable in this test host; skipping storage round-trip.")

        // uidA round-trips.
        let loadedA = SyncBindingStore.load(forUID: uidA, service: service)
        XCTAssertEqual(loadedA, bindingA)

        // uidB has no binding — isolation.
        XCTAssertNil(SyncBindingStore.load(forUID: uidB, service: service))

        // Delete removes it.
        XCTAssertTrue(SyncBindingStore.delete(forUID: uidA, service: service))
        XCTAssertNil(SyncBindingStore.load(forUID: uidA, service: service))
    }

    func testBindingStoreSaveReplacesExisting() throws {
        let service = makeTestService()
        let uid = "uid-\(UUID().uuidString)"
        defer { SyncBindingStore.delete(forUID: uid, service: service) }

        let first = SyncBinding(firebaseUID: uid, cloudUserToken: "t1", zoneName: "z1", boundAt: Date())
        try XCTSkipUnless(SyncBindingStore.save(first, service: service),
                          "Keychain unavailable in this test host; skipping replace test.")

        var second = first
        second.cloudUserToken = "t2"
        second.seededAt = Date()
        XCTAssertTrue(SyncBindingStore.save(second, service: service))

        let loaded = SyncBindingStore.load(forUID: uid, service: service)
        XCTAssertEqual(loaded?.cloudUserToken, "t2")
        XCTAssertNotNil(loaded?.seededAt)
    }
}
