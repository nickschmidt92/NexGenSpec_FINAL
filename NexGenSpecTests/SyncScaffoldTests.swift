//
//  SyncScaffoldTests.swift
//  NexGenSpecTests
//
//  CloudKit sync scaffold regression tests. Sync now ships LIVE (default-ON in
//  Release). These pin the flag semantics — DEBUG is dev-toggle-gated, the Release
//  default is ON, and Local-Only mode force-disables it regardless — plus the
//  NoopSyncPort inertness and the Keychain binding round-trip with per-UID isolation.
//  See docs/design/build-22-cloudkit-sync.md §5, §6, §18.
//

import XCTest
@testable import NexGenSpec

final class SyncScaffoldTests: XCTestCase {

    // MARK: - Feature flag

    func testSyncFeatureFlagSemantics() {
        // Sync ships LIVE: DEFAULT-ON in Release. In DEBUG it is gated by the dev toggle
        // (default off) so developers opt in deliberately against the Development CloudKit
        // environment; the Release default is compiled (`#else return true`) and can't be
        // exercised from a DEBUG test host. Save/restore so a developer's live toggle
        // isn't clobbered by the test.
        let key = SyncFeature.devEnabledKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        #if DEBUG
        XCTAssertFalse(SyncFeature.isEnabled, "DEBUG: sync is off until the dev toggle is set.")
        XCTAssertFalse(SyncFeature.effectiveSyncAllowed, "DEBUG dev toggle off ⇒ no sync.")
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(SyncFeature.isEnabled, "DEBUG: the dev toggle enables sync.")
        XCTAssertTrue(SyncFeature.effectiveSyncAllowed, "DEBUG dev toggle on ⇒ sync allowed.")
        #else
        XCTAssertTrue(SyncFeature.isEnabled, "Release: sync is ON by default (cross-device iCloud ships live).")
        #endif
    }

    func testLocalOnlyModeForcesNoSyncAndDefaultsFalse() {
        let localKey = SyncFeature.localOnlyModeKey
        let devKey = SyncFeature.devEnabledKey
        let originalLocal = UserDefaults.standard.object(forKey: localKey)
        let originalDev = UserDefaults.standard.object(forKey: devKey)
        defer {
            if let originalLocal { UserDefaults.standard.set(originalLocal, forKey: localKey) }
            else { UserDefaults.standard.removeObject(forKey: localKey) }
            if let originalDev { UserDefaults.standard.set(originalDev, forKey: devKey) }
            else { UserDefaults.standard.removeObject(forKey: devKey) }
        }

        UserDefaults.standard.removeObject(forKey: localKey)
        XCTAssertFalse(SyncFeature.isLocalOnlyMode, "Local-only mode defaults to false.")

        // Turn the master switch ON (in DEBUG via the dev toggle) so this genuinely
        // tests that Local-Only WINS over an ENABLED master, not just over default-off.
        #if DEBUG
        UserDefaults.standard.set(true, forKey: devKey)
        #endif
        XCTAssertTrue(SyncFeature.isEnabled, "precondition: the master switch is on")

        UserDefaults.standard.set(true, forKey: localKey)
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

    /// The real store's service must be environment-scoped (T-01618): Debug (Dev
    /// CloudKit env) and TestFlight/Release (Prod env) on one machine must not
    /// share a binding row, or the alternating changeToken forces a full resync on
    /// every swap. Tests compile under DEBUG, so pin the `.dev` name — and that the
    /// pre-scoping shared name is no longer the live default.
    func testDefaultBindingServiceIsEnvironmentScoped() {
        XCTAssertEqual(SyncBindingStore.defaultService, "com.nexgenspec.syncBinding.dev")
        XCTAssertNotEqual(SyncBindingStore.defaultService, "com.nexgenspec.syncBinding")
    }

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
