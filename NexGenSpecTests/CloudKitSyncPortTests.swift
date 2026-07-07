//
//  CloudKitSyncPortTests.swift
//  NexGenSpecTests
//
//  Slice 2b (build 22) — the push-only mirror orchestration, exercised with fake
//  CloudKit/account/binding/reader backends. Verifies the bind decisions wire
//  through to the right CloudDatabase calls and, critically, that an iCloud
//  account change REFUSES-AND-ISOLATES: it pushes nothing and never overwrites
//  the existing binding (landmine 1). See docs/design/build-22-cloudkit-sync.md.
//

import XCTest
@testable import NexGenSpec

// MARK: - Fakes

private final class FakeDatabase: CloudDatabase, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var ensuredZones: [String] = []
    private(set) var saved: [(record: InspectionVersionRecord, zone: String)] = []
    private(set) var deleted: [(name: String, zone: String)] = []
    private(set) var deletedZones: [String] = []
    /// Models the live zone's record store, keyed by recordName, so a finalize that
    /// re-pushes the SAME versionId can be verified to OVERWRITE a draft (fix A) but
    /// NEVER overwrite an already-finalized record.
    private var stored: [String: InspectionVersionRecord] = [:]
    var failEnsureZone = false
    var failSave = false
    var failDeleteZone = false

    func ensureZone(_ zoneName: String) async throws {
        if failEnsureZone { throw NSError(domain: "test", code: 1) }
        lock.withLock { ensuredZones.append(zoneName) }
    }
    func save(_ record: InspectionVersionRecord, inZone zoneName: String) async throws {
        if failSave { throw NSError(domain: "test", code: 2) }
        lock.withLock {
            // Model CKCloudDatabase (fix A): the save fetches the server record and
            // NEVER overwrites one that is already finalized/locked (immutability at
            // the source of truth). Otherwise it creates/overwrites — promoting a
            // draft to finalized, the core fix-A case.
            if stored[record.recordName]?.locked == true { return }
            stored[record.recordName] = record
            saved.append((record, zoneName))
        }
    }
    func delete(recordName: String, inZone zoneName: String) async throws {
        lock.withLock { deleted.append((recordName, zoneName)); stored[recordName] = nil }
    }
    func deleteZone(_ zoneName: String) async throws {
        if failDeleteZone { throw NSError(domain: "test", code: 3) }
        lock.withLock { deletedZones.append(zoneName) }
    }
    /// The record currently stored under a name (nil if never saved / clobbered).
    func record(named recordName: String) -> InspectionVersionRecord? { lock.withLock { stored[recordName] } }

    // SyncMeta deletion log (§8).
    private var tombstones: Set<String> = []
    func recordTombstone(versionId: String, inZone zoneName: String) async throws {
        lock.withLock { _ = tombstones.insert(versionId) }
    }
    func tombstonedIds(inZone zoneName: String) async throws -> Set<String> {
        lock.withLock { tombstones }
    }
    /// Test helper: pre-seed tombstones as if another device deleted these ids.
    func seedTombstones(_ ids: [String]) { lock.withLock { tombstones.formUnion(ids) } }
    var tombstoneSnapshot: Set<String> { lock.withLock { tombstones } }

    // Asset sync (D-0203).
    private(set) var savedAssets: [(record: SyncAssetRecord, zone: String)] = []
    private(set) var deletedAssetKeys: [String] = []
    private(set) var clearedAssetKeys: [String] = []
    private var assetTombstones: Set<String> = []
    func saveAsset(_ record: SyncAssetRecord, inZone zoneName: String) async throws {
        if failSave { throw NSError(domain: "test", code: 4) }
        lock.withLock { savedAssets.append((record, zoneName)) }
    }
    func recordAssetTombstone(key: String, inZone zoneName: String) async throws {
        lock.withLock { assetTombstones.insert(key); deletedAssetKeys.append(key) }
    }
    func clearAssetTombstone(key: String, inZone zoneName: String) async throws {
        lock.withLock { assetTombstones.remove(key); clearedAssetKeys.append(key) }
    }
    func tombstonedAssetKeys(inZone zoneName: String) async throws -> Set<String> {
        lock.withLock { assetTombstones }
    }
    func seedAssetTombstones(_ keys: [String]) { lock.withLock { assetTombstones.formUnion(keys) } }
    var assetTombstoneSnapshot: Set<String> { lock.withLock { assetTombstones } }
}

private struct FakeAccount: CloudAccountProviding {
    let token: String?
    func currentUserToken() async -> String? { token }
}

private struct FakeReader: LocalVersionReader, @unchecked Sendable {
    var data: Data? = Data("payload".utf8)
    var snapshots: [LocalVersionSnapshot] = []
    var state: LocalVersionState = .absent
    func versionData(forVersionId id: UUID) -> Data? { data }
    func allLocalVersions() -> [LocalVersionSnapshot] { snapshots }
    func localState(forVersionId id: UUID) -> LocalVersionState { state }
}

private struct FakeFetcher: CloudZoneFetcher {
    var changes: ZoneChanges
    func fetchChanges(inZone zoneName: String, since token: Data?) async throws -> ZoneChanges { changes }
}

private final class FakeWriter: LocalVersionWriter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var applied: [Data] = []
    private(set) var deleted: [String] = []
    /// Simulate a transient apply/delete failure (e.g. disk write error) to prove
    /// the port does not advance the change token on failure (review F5).
    var applyResult = true
    var deleteResult = true
    func applyRemoteVersion(_ payload: Data) async -> Bool { lock.withLock { applied.append(payload) }; return applyResult }
    func deleteLocalVersion(recordName: String) async -> Bool { lock.withLock { deleted.append(recordName) }; return deleteResult }
    var appliedCount: Int { lock.withLock { applied.count } }
    var deletedCount: Int { lock.withLock { deleted.count } }

    // Asset sync (D-0203). Records the assets the pull applied/deleted, in order, so
    // tests can assert kind-ordering (scan record after its siblings) and tombstone
    // handling; the result flags simulate a transient write failure (token held).
    private(set) var appliedAssets: [SyncAssetRecord] = []
    private(set) var deletedAssets: [(jobId: UUID, relativePath: String)] = []
    var applyAssetResult = true
    var deleteAssetResult = true
    func applyRemoteAsset(_ record: SyncAssetRecord) async -> Bool { lock.withLock { appliedAssets.append(record) }; return applyAssetResult }
    func deleteLocalAsset(jobId: UUID, relativePath: String) async -> Bool { lock.withLock { deletedAssets.append((jobId, relativePath)) }; return deleteAssetResult }
    var appliedAssetKinds: [SyncAssetKind] { lock.withLock { appliedAssets.map { $0.kind } } }
    var deletedAssetCount: Int { lock.withLock { deletedAssets.count } }
}

private final class FakeBindings: BindingStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: SyncBinding]
    init(_ initial: [String: SyncBinding] = [:]) { store = initial }
    func load(forUID uid: String) -> SyncBinding? { lock.withLock { store[uid] } }
    @discardableResult func save(_ binding: SyncBinding) -> Bool {
        lock.withLock { store[binding.firebaseUID] = binding }; return true
    }
    @discardableResult func delete(forUID uid: String) -> Bool {
        lock.withLock { store[uid] = nil }; return true
    }
    func current(_ uid: String) -> SyncBinding? { load(forUID: uid) }
}

private final class FakeTeardownOwed: TeardownOwedStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: SyncTeardownOwed] = [:]
    func record(_ owed: SyncTeardownOwed) { lock.withLock { store[owed.firebaseUID] = owed } }
    func loadAll() -> [SyncTeardownOwed] { lock.withLock { Array(store.values) } }
    func remove(forUID uid: String) { lock.withLock { store[uid] = nil } }
    var all: [SyncTeardownOwed] { loadAll() }
    var count: Int { lock.withLock { store.count } }
}

// MARK: - Tests

final class CloudKitSyncPortTests: XCTestCase {

    private func meta(_ id: UUID = UUID()) -> VersionMetadata {
        VersionMetadata(
            id: id, inspectionId: UUID(), versionNumber: 1, status: .draft,
            finalizedAt: nil, locked: false, clientName: "Client",
            propertyAddress: "Addr", inspectionDate: Date()
        )
    }

    private func makePort(token: String?, bindings: FakeBindings, db: FakeDatabase, reader: FakeReader = FakeReader(), fetcher: CloudZoneFetcher = NoopZoneFetcher(), writer: LocalVersionWriter = NoopLocalVersionWriter()) -> CloudKitSyncPort {
        CloudKitSyncPort(account: FakeAccount(token: token), database: db, reader: reader, bindings: bindings, fetcher: fetcher, writer: writer)
    }

    private func remoteRecord(id: UUID, locked: Bool = false) -> InspectionVersionRecord {
        InspectionVersionRecord(
            recordName: id.uuidString, inspectionId: UUID().uuidString, versionNumber: 1,
            status: locked ? "Final" : "Draft", locked: locked, finalizedAt: nil,
            schemaVersion: 1, updatedAt: nil, payload: Data("remote".utf8)
        )
    }

    func testNoICloudStaysLocalOnlyAndPushesNothing() async {
        let db = FakeDatabase(); let binds = FakeBindings()
        let port = makePort(token: nil, bindings: binds, db: db)

        await port.bind(firebaseUID: "uidA")
        XCTAssertEqual(port.status, .localOnly)
        XCTAssertTrue(db.ensuredZones.isEmpty, "No iCloud ⇒ no zone created.")

        port.recordLocalChange(.versionUpserted(meta()))
        await port.flushPending()
        XCTAssertTrue(db.saved.isEmpty, "No iCloud ⇒ nothing pushed.")
    }

    func testBindNewCreatesZoneAndPersistsBinding() async {
        let db = FakeDatabase(); let binds = FakeBindings()
        let port = makePort(token: "tok1", bindings: binds, db: db)

        await port.bind(firebaseUID: "uidA")
        XCTAssertEqual(port.status, .idle)
        let expectedZone = CloudKitSchema.zoneName(forFirebaseUID: "uidA")
        XCTAssertEqual(db.ensuredZones, [expectedZone])
        let stored = binds.current("uidA")
        XCTAssertEqual(stored?.cloudUserToken, "tok1")
        XCTAssertEqual(stored?.zoneName, expectedZone)
    }

    func testResumeAndUpsertPushesRecordToBoundZone() async {
        let zone = CloudKitSchema.zoneName(forFirebaseUID: "uidA")
        let existing = SyncBinding(firebaseUID: "uidA", cloudUserToken: "tok1", zoneName: zone, boundAt: Date())
        let db = FakeDatabase(); let binds = FakeBindings(["uidA": existing])
        let payload = Data("the-json".utf8)
        let port = makePort(token: "tok1", bindings: binds, db: db, reader: FakeReader(data: payload))

        await port.bind(firebaseUID: "uidA")
        XCTAssertEqual(port.status, .idle)

        let m = meta()
        port.recordLocalChange(.versionUpserted(m))
        await port.flushPending()

        XCTAssertEqual(db.saved.count, 1)
        XCTAssertEqual(db.saved.first?.record.recordName, m.id.uuidString)
        XCTAssertEqual(db.saved.first?.record.payload, payload)
        XCTAssertEqual(db.saved.first?.zone, zone)
    }

    func testVersionDeletedPushesDelete() async {
        let zone = CloudKitSchema.zoneName(forFirebaseUID: "uidA")
        let existing = SyncBinding(firebaseUID: "uidA", cloudUserToken: "tok1", zoneName: zone, boundAt: Date())
        let db = FakeDatabase(); let binds = FakeBindings(["uidA": existing])
        let port = makePort(token: "tok1", bindings: binds, db: db)

        await port.bind(firebaseUID: "uidA")
        let victim = UUID()
        port.recordLocalChange(.versionDeleted(versionId: victim))
        await port.flushPending()

        XCTAssertEqual(db.deleted.count, 1)
        XCTAssertEqual(db.deleted.first?.name, victim.uuidString)
        XCTAssertEqual(db.deleted.first?.zone, zone)
    }

    func testAppleIDChangeRefusesIsolatesAndPushesNothing() async {
        // Bound to iCloud user tok1; device now reports tok2.
        let zone = CloudKitSchema.zoneName(forFirebaseUID: "uidA")
        let existing = SyncBinding(firebaseUID: "uidA", cloudUserToken: "tok1", zoneName: zone, boundAt: Date())
        let db = FakeDatabase(); let binds = FakeBindings(["uidA": existing])
        let port = makePort(token: "tok2", bindings: binds, db: db)

        await port.bind(firebaseUID: "uidA")

        // Paused, not idle.
        if case .paused = port.status {} else { XCTFail("Expected paused/refuse, got \(port.status)") }
        // Never created/touched a zone for the new account.
        XCTAssertTrue(db.ensuredZones.isEmpty, "Refuse-and-isolate must not touch CloudKit.")
        // The original binding is NOT overwritten with the new token.
        XCTAssertEqual(binds.current("uidA")?.cloudUserToken, "tok1", "Binding must not be rebound to the new iCloud user.")

        // And no local change is ever pushed while refused.
        port.recordLocalChange(.versionUpserted(meta()))
        await port.flushPending()
        XCTAssertTrue(db.saved.isEmpty, "Refused state must push nothing.")
    }

    func testUnbindStopsPushing() async {
        let db = FakeDatabase(); let binds = FakeBindings()
        let port = makePort(token: "tok1", bindings: binds, db: db)
        await port.bind(firebaseUID: "uidA")
        XCTAssertEqual(port.status, .idle)

        port.unbind()
        XCTAssertEqual(port.status, .off)
        port.recordLocalChange(.versionUpserted(meta()))
        await port.flushPending()
        XCTAssertTrue(db.saved.isEmpty, "After unbind, nothing is pushed.")
    }

    func testMissingPayloadSkipsSaveWithoutError() async {
        let db = FakeDatabase(); let binds = FakeBindings()
        // reader returns nil ⇒ the version file isn't on disk; skip, don't crash.
        let port = makePort(token: "tok1", bindings: binds, db: db, reader: FakeReader(data: nil))
        await port.bind(firebaseUID: "uidA")
        port.recordLocalChange(.versionUpserted(meta()))
        await port.flushPending()
        XCTAssertTrue(db.saved.isEmpty)
        XCTAssertEqual(port.status, .idle, "A missing payload is a skip, not an error.")
    }

    // MARK: - Seeding (slice 3)

    private func snapshot() -> LocalVersionSnapshot {
        LocalVersionSnapshot(meta: meta(), payload: Data("seed".utf8))
    }

    func testSeedingPushesAllLocalVersionsOnceAndMarksSeeded() async {
        let db = FakeDatabase()
        let binds = FakeBindings()
        let port = makePort(token: "tok1", bindings: binds, db: db, reader: FakeReader(snapshots: [snapshot(), snapshot(), snapshot()]))

        await port.bind(firebaseUID: "uidA")
        XCTAssertEqual(db.saved.count, 3, "Seeding pushes every local version once on first bind.")
        XCTAssertNotNil(binds.current("uidA")?.seededAt, "seededAt is set after a clean pass.")

        // Re-bind (now seeded) must NOT re-seed.
        await port.bind(firebaseUID: "uidA")
        XCTAssertEqual(db.saved.count, 3, "Already-seeded ⇒ no duplicate re-seed.")
    }

    func testInterruptedSeedDoesNotMarkSeededAndReseeds() async {
        let db = FakeDatabase()
        db.failSave = true
        let binds = FakeBindings()
        let port = makePort(token: "tok1", bindings: binds, db: db, reader: FakeReader(snapshots: [snapshot()]))

        await port.bind(firebaseUID: "uidA")
        XCTAssertNil(binds.current("uidA")?.seededAt, "A failed seed pass must not mark seeded.")

        db.failSave = false
        await port.bind(firebaseUID: "uidA")   // resume → re-seeds
        XCTAssertNotNil(binds.current("uidA")?.seededAt, "Re-bind after recovery completes seeding.")
    }

    func testSeedingNeverDeletes() async {
        let db = FakeDatabase()
        let port = makePort(token: "tok1", bindings: FakeBindings(), db: db, reader: FakeReader(snapshots: [snapshot(), snapshot()]))
        await port.bind(firebaseUID: "uidA")
        XCTAssertTrue(db.deleted.isEmpty, "Seeding is push-only; it never deletes local or cloud data.")
    }

    // MARK: - Finalize reaches CloudKit (fix A)

    /// Regression for fix A: finalizing a draft keeps the SAME versionId, so the
    /// draft record already exists in the zone. The old `ifAbsent: meta.locked`
    /// never-clobber push hit `serverRecordChanged` (swallowed as "left immutable"),
    /// so the finalized payload/status/locked NEVER uploaded and device B kept a
    /// stale draft forever. The push must now OVERWRITE the draft with the finalized
    /// record. (With the old code this fails: the stored record stays a draft.)
    func testFinalizePromotionOverwritesDraftRecordInCloud() async {
        let db = FakeDatabase()
        let vid = UUID()
        let port = makePort(token: "tok1", bindings: FakeBindings(), db: db, reader: FakeReader(data: Data("json".utf8)))
        await port.bind(firebaseUID: "uidA")

        // 1) Push the DRAFT for this versionId.
        let draft = VersionMetadata(
            id: vid, inspectionId: UUID(), versionNumber: 1, status: .draft,
            finalizedAt: nil, locked: false, clientName: "", propertyAddress: "", inspectionDate: Date()
        )
        port.recordLocalChange(.versionUpserted(draft))
        await port.flushPending()
        XCTAssertEqual(db.record(named: vid.uuidString)?.locked, false, "draft pushed first")

        // 2) Finalize the SAME versionId → push a locked/Final record.
        let finalized = VersionMetadata(
            id: vid, inspectionId: draft.inspectionId, versionNumber: 1, status: .final,
            finalizedAt: Date(), locked: true, clientName: "", propertyAddress: "", inspectionDate: Date()
        )
        port.recordLocalChange(.versionUpserted(finalized))
        // `await flushPending()` is not a strict barrier: a re-run spawned by the prior
        // flush's `_flushAgain` can hold the flush lock, so the explicit call may return
        // before the finalize push lands. Pump until it does — the re-run mechanism
        // guarantees the queue drains (eventual, not immediate, consistency).
        for _ in 0..<200 where db.record(named: vid.uuidString)?.locked != true {
            await port.flushPending()
            await Task.yield()
        }

        let cloud = db.record(named: vid.uuidString)
        XCTAssertEqual(cloud?.locked, true, "finalize must OVERWRITE the draft cloud record (locked=1) — fix A")
        XCTAssertEqual(cloud?.status, "Final", "finalize must promote the cloud record's status to Final")
        XCTAssertNotNil(cloud?.finalizedAt, "the finalized record must carry finalizedAt")
    }

    /// Immutability at the source of truth (fix A adversarial finding #1): once a
    /// versionId is finalized in the cloud, a SECOND, divergent finalization of the
    /// same id (e.g. another device that finalized the shared draft offline, with a
    /// different finalizedAt) must NOT clobber it. `database.save` refuses to
    /// overwrite an already-locked server record.
    func testFinalizedCloudRecordIsNeverClobberedByASecondFinalize() async {
        let db = FakeDatabase()
        let vid = UUID()
        let port = makePort(token: "tok1", bindings: FakeBindings(), db: db, reader: FakeReader(data: Data("json".utf8)))
        await port.bind(firebaseUID: "uidA")

        let finalA = VersionMetadata(
            id: vid, inspectionId: UUID(), versionNumber: 1, status: .final,
            finalizedAt: Date(timeIntervalSince1970: 1000), locked: true,
            clientName: "", propertyAddress: "", inspectionDate: Date()
        )
        port.recordLocalChange(.versionUpserted(finalA))
        await port.flushPending()
        XCTAssertEqual(db.record(named: vid.uuidString)?.finalizedAt, Date(timeIntervalSince1970: 1000))

        // A divergent second finalize of the SAME id must be refused at the cloud.
        let finalB = VersionMetadata(
            id: vid, inspectionId: finalA.inspectionId, versionNumber: 1, status: .final,
            finalizedAt: Date(timeIntervalSince1970: 2000), locked: true,
            clientName: "", propertyAddress: "", inspectionDate: Date()
        )
        port.recordLocalChange(.versionUpserted(finalB))
        await port.flushPending()
        XCTAssertEqual(db.record(named: vid.uuidString)?.finalizedAt, Date(timeIntervalSince1970: 1000),
                       "a finalized cloud record is immutable — the second finalize must not clobber the first")
    }

    // MARK: - Edit queued while unbound is not lost (fix F)

    /// Regression for fix F: `flushPending` used to drain `pending` BEFORE checking
    /// the binding, so an edit recorded during a transient unbind window was dropped
    /// (seeding runs once, so it never re-pushed). The queue must survive an unbound
    /// flush and push on the next bind.
    func testEditQueuedWhileUnboundIsNotLostAndPushesOnBind() async {
        let db = FakeDatabase()
        let binds = FakeBindings()
        let port = makePort(token: "tok1", bindings: binds, db: db)

        // Record a change BEFORE binding (activeBinding == nil). Flushing while
        // unbound must NOT drop it.
        let m = meta()
        port.recordLocalChange(.versionUpserted(m))
        await port.flushPending()
        XCTAssertTrue(db.saved.isEmpty, "nothing is pushed while unbound")

        // Bind: the bind tail re-drives flushPending and the queued edit uploads.
        await port.bind(firebaseUID: "uidA")
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(db.saved.count, 1, "the edit queued while unbound is pushed once bound (fix F)")
        XCTAssertEqual(db.saved.first?.record.recordName, m.id.uuidString)
    }

    // MARK: - Account-deletion teardown (fix C / edge G)

    func testAccountTeardownDeletesZoneAndBindingWhenBound() async {
        let zone = CloudKitSchema.zoneName(forFirebaseUID: "uidA")
        let binding = SyncBinding(firebaseUID: "uidA", cloudUserToken: "tok1", zoneName: zone, boundAt: Date())
        let db = FakeDatabase(); let binds = FakeBindings(["uidA": binding]); let owed = FakeTeardownOwed()

        // Current iCloud user still matches the bound account → safe to delete the zone.
        await SyncAccountTeardown.tearDown(uid: "uidA", database: db, account: FakeAccount(token: "tok1"), bindings: binds, owed: owed, isEnabled: true)

        XCTAssertEqual(db.deletedZones, [zone], "teardown deletes the deleted account's CloudKit zone")
        XCTAssertNil(binds.current("uidA"), "teardown removes the local binding")
        XCTAssertEqual(owed.count, 0, "a clean delete leaves nothing owed")
    }

    /// Finding #4: after an iCloud-account switch the bound zone lives in the OLD,
    /// inaccessible private DB. Teardown must NOT issue deleteZone against the new
    /// account (it would falsely "succeed" and leave the real zone behind) — but it
    /// must still drop the local binding.
    func testAccountTeardownSkipsZoneDeleteAfterICloudSwitchButDropsBinding() async {
        let zone = CloudKitSchema.zoneName(forFirebaseUID: "uidA")
        let binding = SyncBinding(firebaseUID: "uidA", cloudUserToken: "tok1", zoneName: zone, boundAt: Date())
        let db = FakeDatabase(); let binds = FakeBindings(["uidA": binding]); let owed = FakeTeardownOwed()

        // Current iCloud user is DIFFERENT from the bound account (tok2 != tok1).
        await SyncAccountTeardown.tearDown(uid: "uidA", database: db, account: FakeAccount(token: "tok2"), bindings: binds, owed: owed, isEnabled: true)

        XCTAssertTrue(db.deletedZones.isEmpty, "must not deleteZone against the wrong iCloud account")
        XCTAssertNil(binds.current("uidA"), "the local binding is still dropped")
        XCTAssertEqual(owed.all.first?.zoneName, zone, "an unreachable zone is recorded owed for the cold-launch sweep")
    }

    func testAccountTeardownIsNoopWhenFlagOff() async {
        let zone = CloudKitSchema.zoneName(forFirebaseUID: "uidA")
        let binding = SyncBinding(firebaseUID: "uidA", cloudUserToken: "tok1", zoneName: zone, boundAt: Date())
        let db = FakeDatabase(); let binds = FakeBindings(["uidA": binding]); let owed = FakeTeardownOwed()

        await SyncAccountTeardown.tearDown(uid: "uidA", database: db, account: FakeAccount(token: "tok1"), bindings: binds, owed: owed, isEnabled: false)

        XCTAssertTrue(db.deletedZones.isEmpty, "flag OFF ⇒ no CloudKit zone delete")
        XCTAssertNotNil(binds.current("uidA"), "flag OFF ⇒ binding left intact")
        XCTAssertEqual(owed.count, 0, "flag OFF ⇒ nothing recorded owed")
    }

    func testAccountTeardownIsNoopWhenNoBinding() async {
        let db = FakeDatabase(); let binds = FakeBindings(); let owed = FakeTeardownOwed()
        await SyncAccountTeardown.tearDown(uid: "uidA", database: db, account: FakeAccount(token: "tok1"), bindings: binds, owed: owed, isEnabled: true)
        XCTAssertTrue(db.deletedZones.isEmpty, "no binding ⇒ nothing to tear down")
        XCTAssertEqual(owed.count, 0, "no binding ⇒ nothing recorded owed")
    }

    /// iCloud unavailable at deletion time (token nil): we can't verify ownership, so
    /// no zone delete is attempted (it would hit the wrong/unknown DB). Teardown is
    /// one-shot best-effort, so the binding is still dropped; the zone residual + the
    /// known durable-retry limitation are documented (sync-GA item).
    func testAccountTeardownSkipsZoneButDropsBindingWhenICloudUnavailable() async {
        let zone = CloudKitSchema.zoneName(forFirebaseUID: "uidA")
        let binding = SyncBinding(firebaseUID: "uidA", cloudUserToken: "tok1", zoneName: zone, boundAt: Date())
        let db = FakeDatabase(); let binds = FakeBindings(["uidA": binding]); let owed = FakeTeardownOwed()

        await SyncAccountTeardown.tearDown(uid: "uidA", database: db, account: FakeAccount(token: nil), bindings: binds, owed: owed, isEnabled: true)

        XCTAssertTrue(db.deletedZones.isEmpty, "iCloud unavailable ⇒ no zone delete attempted (could hit wrong DB)")
        XCTAssertNil(binds.current("uidA"), "best-effort teardown is one-shot: the binding is dropped")
        XCTAssertEqual(owed.all.first?.zoneName, zone, "iCloud unavailable ⇒ zone recorded owed for the sweep")
    }

    /// A transient deleteZone failure does not block teardown: the attempt is made and
    /// the binding is still dropped (best-effort, never blocks the wipe). Durable retry
    /// of the residual zone is a documented sync-GA item.
    func testAccountTeardownDropsBindingEvenWhenZoneDeleteFails() async {
        let zone = CloudKitSchema.zoneName(forFirebaseUID: "uidA")
        let binding = SyncBinding(firebaseUID: "uidA", cloudUserToken: "tok1", zoneName: zone, boundAt: Date())
        let db = FakeDatabase(); db.failDeleteZone = true
        let binds = FakeBindings(["uidA": binding]); let owed = FakeTeardownOwed()

        await SyncAccountTeardown.tearDown(uid: "uidA", database: db, account: FakeAccount(token: "tok1"), bindings: binds, owed: owed, isEnabled: true)

        XCTAssertNil(binds.current("uidA"), "best-effort: binding dropped even when deleteZone fails")
        XCTAssertEqual(owed.all.first?.zoneName, zone, "a transient deleteZone failure records the zone owed for the sweep (fix C)")
    }

    // MARK: - Cold-launch teardown sweep (fix C)

    func testTeardownSweepRetriesOwedZoneWhenOwnerReturns() async {
        let zone = CloudKitSchema.zoneName(forFirebaseUID: "uidA")
        let db = FakeDatabase()
        let owed = FakeTeardownOwed()
        owed.record(SyncTeardownOwed(firebaseUID: "uidA", zoneName: zone, cloudUserToken: "tok1"))

        // The owning iCloud user is back (token matches) → the retry deletes the zone
        // and clears the owed marker.
        await SyncTeardownSweep.run(database: db, account: FakeAccount(token: "tok1"), owed: owed, isEnabled: true)

        XCTAssertEqual(db.deletedZones, [zone], "the sweep retries the owed zone delete under the owning account")
        XCTAssertEqual(owed.count, 0, "a successful retry clears the owed marker")
    }

    func testTeardownSweepKeepsOwedWhenTokenMismatches() async {
        let zone = CloudKitSchema.zoneName(forFirebaseUID: "uidA")
        let db = FakeDatabase()
        let owed = FakeTeardownOwed()
        owed.record(SyncTeardownOwed(firebaseUID: "uidA", zoneName: zone, cloudUserToken: "tok1"))

        // A DIFFERENT iCloud user is signed in (tok2 != tok1) → never deleteZone the
        // wrong DB; leave it owed for a later launch under the owner.
        await SyncTeardownSweep.run(database: db, account: FakeAccount(token: "tok2"), owed: owed, isEnabled: true)

        XCTAssertTrue(db.deletedZones.isEmpty, "the sweep must not deleteZone against the wrong iCloud account")
        XCTAssertEqual(owed.count, 1, "the owed marker is kept for a later launch under the owner")
    }

    func testTeardownSweepIsNoopWhenFlagOff() async {
        let zone = CloudKitSchema.zoneName(forFirebaseUID: "uidA")
        let db = FakeDatabase()
        let owed = FakeTeardownOwed()
        owed.record(SyncTeardownOwed(firebaseUID: "uidA", zoneName: zone, cloudUserToken: "tok1"))

        await SyncTeardownSweep.run(database: db, account: FakeAccount(token: "tok1"), owed: owed, isEnabled: false)

        XCTAssertTrue(db.deletedZones.isEmpty, "flag OFF ⇒ the sweep is a strict no-op")
        XCTAssertEqual(owed.count, 1, "flag OFF ⇒ owed markers are untouched")
    }

    // MARK: - Deletion tombstone / no-resurrection (§8)

    func testDeletePushRecordsTombstone() async {
        let db = FakeDatabase(); let binds = FakeBindings()
        let port = makePort(token: "t1", bindings: binds, db: db)
        await port.bind(firebaseUID: "uidA")

        let id = UUID()
        port.recordLocalChange(.versionDeleted(versionId: id))
        await port.flushPending()

        XCTAssertTrue(db.tombstoneSnapshot.contains(id.uuidString), "a delete records a tombstone in the SyncMeta deletion log")
        XCTAssertTrue(db.deleted.contains(where: { $0.name == id.uuidString }), "the record is also deleted from the zone")
    }

    func testPushSuppressesTombstonedUpsert() async {
        let db = FakeDatabase(); let binds = FakeBindings()
        let writer = FakeWriter()
        var reader = FakeReader(); reader.state = LocalVersionState(exists: true, isFinalized: false, updatedAt: Date())
        let port = makePort(token: "t1", bindings: binds, db: db, reader: reader, writer: writer)
        await port.bind(firebaseUID: "uidA")

        // Another device already deleted this id → it's tombstoned.
        let m = meta()
        db.seedTombstones([m.id.uuidString])

        port.recordLocalChange(.versionUpserted(m))
        await port.flushPending()

        XCTAssertTrue(db.saved.isEmpty, "a tombstoned id is never re-pushed (no resurrection, §8)")
        XCTAssertEqual(writer.deletedCount, 1, "the local copy of a remotely-deleted draft is dropped (delete-wins)")
    }

    func testPullSuppressesResurrectedTombstonedRecord() async {
        let id = UUID()
        let changes = ZoneChanges(
            changed: [RemoteVersion(record: remoteRecord(id: id), modifiedAt: Date())],
            deletedRecordNames: [], newToken: Data("tok".utf8)
        )
        let db = FakeDatabase(); db.seedTombstones([id.uuidString])
        let writer = FakeWriter()
        var reader = FakeReader(); reader.state = LocalVersionState(exists: true, isFinalized: false, updatedAt: Date())
        let binds = FakeBindings()
        let port = makePort(token: "t1", bindings: binds, db: db, reader: reader, fetcher: FakeFetcher(changes: changes), writer: writer)

        await port.bind(firebaseUID: "uidA")

        XCTAssertEqual(writer.appliedCount, 0, "a tombstoned (resurrected) record is never applied on pull")
        XCTAssertEqual(writer.deletedCount, 1, "the resurrected record is deleted locally instead (no-resurrection, §8)")
    }

    func testFinalizedLocalIsNotDeletedByTombstone() async {
        // Defensive: even if a finalized id were tombstoned, resolveDelete protects the
        // immutable legal record — it is neither applied nor deleted locally.
        let id = UUID()
        let changes = ZoneChanges(
            changed: [RemoteVersion(record: remoteRecord(id: id), modifiedAt: Date())],
            deletedRecordNames: [], newToken: nil
        )
        let db = FakeDatabase(); db.seedTombstones([id.uuidString])
        let writer = FakeWriter()
        var reader = FakeReader(); reader.state = LocalVersionState(exists: true, isFinalized: true, updatedAt: Date())
        let port = makePort(token: "t1", bindings: FakeBindings(), db: db, reader: reader, fetcher: FakeFetcher(changes: changes), writer: writer)

        await port.bind(firebaseUID: "uidA")

        XCTAssertEqual(writer.appliedCount, 0, "a tombstoned record is never applied")
        XCTAssertEqual(writer.deletedCount, 0, "a FINALIZED local is never deleted by sync (immutability wins over the tombstone)")
    }

    func testPushDoesNotSuppressFinalizedLocal() async {
        // A FINALIZED local whose id is tombstoned (an older draft of the same id was
        // deleted elsewhere) must still be PUSHED — a finalize WINS over a draft-tombstone
        // (immutable legal record); it must never be stranded off-cloud (A-F5).
        let db = FakeDatabase(); let binds = FakeBindings()
        let writer = FakeWriter()
        var reader = FakeReader(); reader.state = LocalVersionState(exists: true, isFinalized: true, updatedAt: Date())
        let port = makePort(token: "t1", bindings: binds, db: db, reader: reader, writer: writer)
        await port.bind(firebaseUID: "uidA")

        let m = meta()
        db.seedTombstones([m.id.uuidString])
        port.recordLocalChange(.versionUpserted(m))
        await port.flushPending()

        XCTAssertEqual(db.saved.count, 1, "a finalized local is pushed despite a draft-tombstone (finalize wins)")
        XCTAssertEqual(writer.deletedCount, 0, "a finalized local is never deleted by a tombstone")
    }

    func testPullAppliesFinalizedRecordDespiteTombstone() async {
        // A tombstoned but FINALIZED remote must be APPLIED, not suppressed — finalize
        // wins over an older draft-tombstone (the pull dual of A-F5).
        let id = UUID()
        let changes = ZoneChanges(
            changed: [RemoteVersion(record: remoteRecord(id: id, locked: true), modifiedAt: Date())],
            deletedRecordNames: [], newToken: Data("tok".utf8)
        )
        let db = FakeDatabase(); db.seedTombstones([id.uuidString])
        let writer = FakeWriter()
        var reader = FakeReader(); reader.state = .absent   // not present locally → apply
        let binds = FakeBindings()
        let port = makePort(token: "t1", bindings: binds, db: db, reader: reader, fetcher: FakeFetcher(changes: changes), writer: writer)

        await port.bind(firebaseUID: "uidA")

        XCTAssertEqual(writer.appliedCount, 1, "a tombstoned FINALIZED remote is applied (finalize wins over a draft-tombstone)")
        XCTAssertEqual(writer.deletedCount, 0, "and it is not deleted as a resurrection")
    }

    // MARK: - Reader pinned to the bound UID (fix B / landmine 1)

    /// Regression for fix B: `DiskVersionReader` resolved paths against the LIVE
    /// `appRoot`, so after an A→B account switch an in-flight A-port seed/pull read
    /// B's disk. A reader pinned to its bound UID must read THAT UID's store
    /// regardless of who is currently the active (live) user.
    func testDiskVersionReaderIsPinnedToBoundUIDNotLiveAppRoot() throws {
        let uidA = "fixB-A-\(UUID().uuidString)"
        let uidB = "fixB-B-\(UUID().uuidString)"
        let savedProvider = SessionScope.uidProvider
        defer {
            SessionScope.uidProvider = savedProvider
            try? FileManager.default.removeItem(at: FilePaths.userRoot(uid: uidA))
            try? FileManager.default.removeItem(at: FilePaths.userRoot(uid: uidB))
        }

        // A version exists ONLY in A's per-UID store.
        let id = UUID()
        let inspection = Inspection(id: id, clientName: "A-only", clientEmail: "", clientPhone: "",
                                    propertyAddress: "addr", inspectionDate: Date(), inspectorName: "I", sections: [])
        let v = InspectionVersion(id: id, versionNumber: 1, status: .draft, finalizedAt: nil, locked: false, inspection: inspection)
        let urlA = FilePaths.currentVersionFile(jobId: id, inRoot: FilePaths.userRoot(uid: uidA))
        try FileSecurity.ensureProtectedDirectory(urlA.deletingLastPathComponent())
        try FileSecurity.writeProtected(try JSONEncoder().encode(v), to: urlA)

        // The LIVE active user is B (B's store has nothing for `id`).
        SessionScope.uidProvider = { uidB }

        let pinnedA = DiskVersionReader(uid: uidA)
        XCTAssertTrue(pinnedA.localState(forVersionId: id).exists,
                      "a reader pinned to A must see A's version even though the live user is B")
        XCTAssertNotNil(pinnedA.versionData(forVersionId: id), "pinned-A reader must read A's payload")

        let live = DiskVersionReader()
        XCTAssertEqual(live.localState(forVersionId: id), .absent,
                       "an unpinned reader follows the live (B) appRoot and must NOT see A's version")
    }

    // MARK: - Pull / two-way (slice 4) — bind() triggers pull()

    func testPullAppliesNewRemoteVersionAndPersistsToken() async {
        let id = UUID()
        let changes = ZoneChanges(
            changed: [RemoteVersion(record: remoteRecord(id: id), modifiedAt: Date())],
            deletedRecordNames: [], newToken: Data("tok".utf8)
        )
        let writer = FakeWriter()
        var reader = FakeReader(); reader.state = .absent   // not present locally → apply
        let binds = FakeBindings()
        let port = makePort(token: "t1", bindings: binds, db: FakeDatabase(), reader: reader, fetcher: FakeFetcher(changes: changes), writer: writer)

        await port.bind(firebaseUID: "uidA")
        XCTAssertEqual(writer.appliedCount, 1, "A new remote version is applied locally.")
        XCTAssertNotNil(binds.current("uidA")?.changeToken, "The new change token is persisted for incremental pulls.")
    }

    func testPullNeverOverwritesLocalFinalized() async {
        let changes = ZoneChanges(
            changed: [RemoteVersion(record: remoteRecord(id: UUID(), locked: false), modifiedAt: Date())],
            deletedRecordNames: [], newToken: nil
        )
        let writer = FakeWriter()
        var reader = FakeReader(); reader.state = LocalVersionState(exists: true, isFinalized: true, updatedAt: Date())
        let port = makePort(token: "t1", bindings: FakeBindings(), db: FakeDatabase(), reader: reader, fetcher: FakeFetcher(changes: changes), writer: writer)

        await port.bind(firebaseUID: "uidA")
        XCTAssertEqual(writer.appliedCount, 0, "A finalized local version is never overwritten by a remote change.")
    }

    func testPullDoesNotAdvanceTokenWhenAnApplyFails() async {
        // A transient apply failure (e.g. disk write error) must NOT advance the
        // change token, so the next pull re-fetches and retries (review F5).
        let changes = ZoneChanges(
            changed: [RemoteVersion(record: remoteRecord(id: UUID()), modifiedAt: Date())],
            deletedRecordNames: [], newToken: Data("tok".utf8)
        )
        let writer = FakeWriter(); writer.applyResult = false
        var reader = FakeReader(); reader.state = .absent
        let binds = FakeBindings()
        let port = makePort(token: "t1", bindings: binds, db: FakeDatabase(), reader: reader, fetcher: FakeFetcher(changes: changes), writer: writer)

        await port.bind(firebaseUID: "uidA")
        XCTAssertEqual(writer.appliedCount, 1, "The apply was attempted.")
        XCTAssertNil(binds.current("uidA")?.changeToken, "A failed apply must not advance the change token.")
    }

    func testPullHoldsTokenOnTransientLocalReadFailure() async {
        // A TRANSIENT local read failure (data-protection/I/O) must NOT settle the
        // record: the pull holds the change token so the next pull retries, instead of
        // permanently skipping a legitimate remote update (fix D).
        let changes = ZoneChanges(
            changed: [RemoteVersion(record: remoteRecord(id: UUID()), modifiedAt: Date())],
            deletedRecordNames: [], newToken: Data("tok".utf8)
        )
        let writer = FakeWriter()
        var reader = FakeReader()
        reader.state = LocalVersionState(exists: true, isFinalized: true, updatedAt: Date(), readFailed: true)
        let binds = FakeBindings()
        let port = makePort(token: "t1", bindings: binds, db: FakeDatabase(), reader: reader, fetcher: FakeFetcher(changes: changes), writer: writer)

        await port.bind(firebaseUID: "uidA")
        XCTAssertEqual(writer.appliedCount, 0, "A transiently-unreadable local record is not overwritten.")
        XCTAssertNil(binds.current("uidA")?.changeToken, "A transient read failure must HOLD (not advance) the change token.")
    }

    func testPullAdvancesTokenOnSettledKeepLocal() async {
        // Contrast with the transient-read case: a SETTLED keepLocal (finalized local,
        // readFailed=false) never overwrites the local record but DOES advance the
        // token — it must not retry forever (fix D distinguishes the two).
        let changes = ZoneChanges(
            changed: [RemoteVersion(record: remoteRecord(id: UUID()), modifiedAt: Date())],
            deletedRecordNames: [], newToken: Data("tok".utf8)
        )
        let writer = FakeWriter()
        var reader = FakeReader()
        reader.state = LocalVersionState(exists: true, isFinalized: true, updatedAt: Date(), readFailed: false)
        let binds = FakeBindings()
        let port = makePort(token: "t1", bindings: binds, db: FakeDatabase(), reader: reader, fetcher: FakeFetcher(changes: changes), writer: writer)

        await port.bind(firebaseUID: "uidA")
        XCTAssertEqual(writer.appliedCount, 0, "A settled keepLocal does not overwrite the local record.")
        XCTAssertNotNil(binds.current("uidA")?.changeToken, "A settled keepLocal advances the token (does not retry forever).")
    }

    // MARK: - Asset pull (D-0203 / W2)

    private func assetRecord(jobId: UUID, relativePath: String, kind: SyncAssetKind, modifiedAt: Date = Date()) -> SyncAssetRecord {
        SyncAssetRecord(
            recordName: CloudKitSchema.assetRecordName(jobId: jobId, relativePath: relativePath),
            jobId: jobId, relativePath: relativePath, kind: kind,
            modifiedAt: modifiedAt, schemaVersion: CloudKitSchema.schemaVersion, payload: Data("x".utf8)
        )
    }

    func testPullAppliesAssetsWithScanRecordLast() async {
        let jobId = UUID(); let scanId = UUID()
        // Deliberately list the scan record FIRST so only the kind-ordering can move it
        // after its PNG/room siblings (receiver-side torn-save intent).
        let assets = [
            assetRecord(jobId: jobId, relativePath: "Inspections/\(jobId.uuidString)/lidar/\(scanId.uuidString).json", kind: .lidarScan),
            assetRecord(jobId: jobId, relativePath: "Inspections/\(jobId.uuidString)/lidar/\(scanId.uuidString)_floorplan.png", kind: .lidarFloorplan),
            assetRecord(jobId: jobId, relativePath: "Inspections/\(jobId.uuidString)/lidar/\(scanId.uuidString)_room.json", kind: .lidarRoom)
        ]
        let changes = ZoneChanges(changed: [], changedAssets: assets, deletedRecordNames: [], newToken: Data("tok".utf8))
        let writer = FakeWriter()
        let binds = FakeBindings()
        let port = makePort(token: "t1", bindings: binds, db: FakeDatabase(), fetcher: FakeFetcher(changes: changes), writer: writer)

        await port.bind(firebaseUID: "uidA")
        XCTAssertEqual(writer.appliedAssets.count, 3, "All three synced assets in the batch are applied.")
        XCTAssertEqual(writer.appliedAssetKinds.last, .lidarScan, "The scan record (<scanId>.json) is applied AFTER its PNG/room siblings in the same batch.")
        XCTAssertNotNil(binds.current("uidA")?.changeToken, "A clean asset batch advances the change token.")
    }

    func testPullUpsertWinsOverAssetTombstone() async {
        let jobId = UUID()
        let path = "Reports/123-Main-St/Inspection_Report.pdf"
        let key = "\(jobId.uuidString)/\(path)"
        let changes = ZoneChanges(changed: [], changedAssets: [assetRecord(jobId: jobId, relativePath: path, kind: .reportPDF)], deletedRecordNames: [], newToken: Data("tok".utf8))
        let db = FakeDatabase(); db.seedAssetTombstones([key])   // deleted-then-recreated elsewhere
        let writer = FakeWriter()
        let binds = FakeBindings()
        let port = makePort(token: "t1", bindings: binds, db: db, fetcher: FakeFetcher(changes: changes), writer: writer)

        await port.bind(firebaseUID: "uidA")
        XCTAssertEqual(writer.appliedAssets.count, 1, "An asset present in the changed set is applied even though its key is still tombstoned (upsert-wins).")
        XCTAssertEqual(writer.deletedAssetCount, 0, "It is NOT also deleted — the recreation wins over the stale tombstone.")
    }

    func testPullAppliesAssetTombstoneDeletion() async {
        let jobId = UUID()
        let path = "Inspections/\(jobId.uuidString)/thumbnails/\(UUID().uuidString).jpg"
        let key = "\(jobId.uuidString)/\(path)"
        let changes = ZoneChanges(changed: [], changedAssets: [], deletedRecordNames: [], newToken: Data("tok".utf8))
        let db = FakeDatabase(); db.seedAssetTombstones([key])
        let writer = FakeWriter()
        let binds = FakeBindings()
        let port = makePort(token: "t1", bindings: binds, db: db, fetcher: FakeFetcher(changes: changes), writer: writer)

        await port.bind(firebaseUID: "uidA")
        XCTAssertEqual(writer.deletedAssetCount, 1, "A tombstoned asset NOT re-created this batch is deleted locally.")
        XCTAssertEqual(writer.deletedAssets.first?.jobId, jobId, "The key parses back to the right jobId.")
        XCTAssertEqual(writer.deletedAssets.first?.relativePath, path, "The key parses back to the full root-relative path (split on the FIRST slash).")
    }

    func testPullHoldsTokenOnAssetWriteFailure() async {
        let jobId = UUID()
        let path = "Inspections/\(jobId.uuidString)/thumbnails/\(UUID().uuidString).jpg"
        let changes = ZoneChanges(changed: [], changedAssets: [assetRecord(jobId: jobId, relativePath: path, kind: .thumbnail)], deletedRecordNames: [], newToken: Data("tok".utf8))
        let writer = FakeWriter(); writer.applyAssetResult = false
        let binds = FakeBindings()
        let port = makePort(token: "t1", bindings: binds, db: FakeDatabase(), fetcher: FakeFetcher(changes: changes), writer: writer)

        await port.bind(firebaseUID: "uidA")
        XCTAssertEqual(writer.appliedAssets.count, 1, "The asset write was attempted.")
        XCTAssertNil(binds.current("uidA")?.changeToken, "A transient asset write failure holds (does not advance) the change token.")
    }

    func testPullDeletesLocalDraftButKeepsFinalizedOnTombstone() async {
        let draftChanges = ZoneChanges(changed: [], deletedRecordNames: [UUID().uuidString], newToken: nil)
        let w1 = FakeWriter()
        var rDraft = FakeReader(); rDraft.state = LocalVersionState(exists: true, isFinalized: false, updatedAt: Date())
        let p1 = makePort(token: "t1", bindings: FakeBindings(), db: FakeDatabase(), reader: rDraft, fetcher: FakeFetcher(changes: draftChanges), writer: w1)
        await p1.bind(firebaseUID: "uidA")
        XCTAssertEqual(w1.deletedCount, 1, "A remote tombstone deletes a local draft.")

        let finalChanges = ZoneChanges(changed: [], deletedRecordNames: [UUID().uuidString], newToken: nil)
        let w2 = FakeWriter()
        var rFinal = FakeReader(); rFinal.state = LocalVersionState(exists: true, isFinalized: true, updatedAt: Date())
        let p2 = makePort(token: "t1", bindings: FakeBindings(), db: FakeDatabase(), reader: rFinal, fetcher: FakeFetcher(changes: finalChanges), writer: w2)
        await p2.bind(firebaseUID: "uidB")
        XCTAssertEqual(w2.deletedCount, 0, "A finalized report is never deleted via a remote tombstone.")
    }
}
