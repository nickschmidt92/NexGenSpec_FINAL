//
//  SyncRoundTripRegressionTests.swift
//  NexGenSpecTests
//
//  SharedFakeZone round-trip regression for the update-propagation production bug:
//  devices sharing one CloudKit custom zone see a CREATE propagate, but an UPDATE
//  (field edit) or FINALIZE (locked=1) of an EXISTING record never reaches the
//  receivers — they keep the stale Draft despite "Up to date".
//
//  The existing unit tests exercise push and pull against DISCONNECTED fakes:
//  `FakeDatabase` records saves but never feeds a fetch, and `FakeFetcher` returns a
//  hand-canned `ZoneChanges` that ignores the `since` token. No test ever proved
//  that a record SAVED into the zone is RE-DELIVERED by an incremental fetch after
//  the receiver's change token has advanced past its create (H3). These tests close
//  that gap: TWO independently-instantiated sync stacks — A (editor) and B
//  (receiver) — share ONE in-memory zone (`SharedFakeZone`) that models the real
//  CloudKit semantics at the injected seam:
//    - every committed save bumps the record's change tag and appends it to the
//      zone's change log (a monotonically increasing sequence);
//    - fetchChanges(since: token) re-delivers ANY record whose last change is past
//      the token — updates and finalizes included, not just inserts — and returns
//      the advanced token, exactly like `recordZoneChanges` (net-state delivery:
//      the latest version of each changed record, coalesced);
//    - a conditional save against a stale change tag surfaces `serverRecordChanged`,
//      and the save loop mirrors CKCloudDatabase.save's fetch → locked-guard →
//      .ifServerRecordUnchanged commit → bounded re-fetch/retry.
//  Each device's local store is a stateful `FakeDeviceStore` (reader + writer over
//  one in-memory version table), so a pull's apply feeds the NEXT pull's conflict
//  resolution the way `current.json` does on a real device.
//
//  If these pass, the defect lives BELOW this seam (in the real CKCloudDatabase /
//  CKZoneFetcher backends or CloudKit itself); they then stand as regression
//  coverage for the coming fix. See docs/design/build-22-cloudkit-sync.md §4, §8.
//

import XCTest
@testable import NexGenSpec

// MARK: - Shared zone (server) double

private enum SharedZoneError: Error { case serverRecordChanged }

/// One in-memory CloudKit custom zone shared by every sync stack in a test.
/// Implements BOTH server-side seams (`CloudDatabase` for pushes, `CloudZoneFetcher`
/// for pulls) over one record table + change log, so what device A saves is exactly
/// what device B's incremental fetch delivers.
private final class SharedFakeZone: CloudDatabase, CloudZoneFetcher, @unchecked Sendable {

    /// One server-side record: the stored projection plus its optimistic-concurrency
    /// change tag, its position in the zone change log, and the value of its
    /// `modifiedAt` FIELD (which `CKCloudDatabase.apply` writes as the pushed
    /// `updatedAt ?? upload-time` — the LWW clock the fetcher hands back).
    private struct ServerRecord {
        var record: InspectionVersionRecord
        var changeTag: Int
        var changedAtSeq: Int
        var modifiedAtField: Date
    }

    private let lock = NSLock()
    /// The zone change-log clock. Bumped on every committed mutation; a change token
    /// is an encoded position in this sequence.
    private var seq = 0
    private var records: [String: ServerRecord] = [:]
    /// recordName → change-log position of its deletion (CK-native deletions).
    private var deletions: [String: Int] = [:]
    private var tombstones: Set<String> = []
    private var assetTombstones: Set<String> = []
    private(set) var ensuredZones: [String] = []
    /// Test hook: runs ONCE inside save()'s fetch→commit window — models another
    /// device's write landing concurrently, which the real backend surfaces as
    /// `serverRecordChanged` on its `.ifServerRecordUnchanged` save.
    var onFetchSaveWindow: ((SharedFakeZone) -> Void)?

    // MARK: CloudDatabase

    func ensureZone(_ zoneName: String) async throws {
        lock.withLock { ensuredZones.append(zoneName) }
    }

    /// Mirrors CKCloudDatabase.save (NEW-2 / fix A): fetch the server record, refuse
    /// to touch one that is already finalized/locked, then commit conditionally
    /// against the FETCHED change tag; on a stale-tag conflict, re-fetch and retry
    /// (bounded), throwing on exhaustion.
    func save(_ record: InspectionVersionRecord, inZone zoneName: String) async throws {
        let maxAttempts = 3
        for _ in 1...maxAttempts {
            let existing: ServerRecord? = lock.withLock { records[record.recordName] }
            if let existing, existing.record.locked { return }   // immutable — left untouched
            // A concurrent cross-device write may land in the fetch→save window.
            let interleave: ((SharedFakeZone) -> Void)? = lock.withLock {
                defer { onFetchSaveWindow = nil }
                return onFetchSaveWindow
            }
            interleave?(self)
            do {
                try commit(record, expectedTag: existing?.changeTag)
                return
            } catch SharedZoneError.serverRecordChanged {
                continue   // stale tag → re-fetch + retry, like the real backend
            }
        }
        throw SharedZoneError.serverRecordChanged
    }

    /// The conditional server commit (`.ifServerRecordUnchanged`): succeeds only when
    /// the caller's tag matches the record's CURRENT tag (nil = "creating, must not
    /// exist"); otherwise surfaces `serverRecordChanged`. A committed save bumps the
    /// change tag and moves the record to the head of the change log.
    private func commit(_ record: InspectionVersionRecord, expectedTag: Int?) throws {
        try lock.withLock {
            guard records[record.recordName]?.changeTag == expectedTag else {
                throw SharedZoneError.serverRecordChanged
            }
            seq += 1
            records[record.recordName] = ServerRecord(
                record: record, changeTag: seq, changedAtSeq: seq,
                modifiedAtField: record.updatedAt ?? Date()
            )
            deletions[record.recordName] = nil
        }
    }

    /// A write committed by "another device", used by the fetch→save-window hook.
    /// Unconditional at the call site but still bumps the tag/log like any commit.
    func commitAsOtherDevice(_ record: InspectionVersionRecord) {
        lock.withLock {
            seq += 1
            records[record.recordName] = ServerRecord(
                record: record, changeTag: seq, changedAtSeq: seq,
                modifiedAtField: record.updatedAt ?? Date()
            )
            deletions[record.recordName] = nil
        }
    }

    func delete(recordName: String, inZone zoneName: String) async throws {
        lock.withLock {
            guard records[recordName] != nil else { return }
            records[recordName] = nil
            seq += 1
            deletions[recordName] = seq
        }
    }

    func deleteZone(_ zoneName: String) async throws {
        lock.withLock { records.removeAll(); deletions.removeAll() }
    }

    func recordTombstone(versionId: String, inZone zoneName: String) async throws {
        lock.withLock { _ = tombstones.insert(versionId) }
    }
    func tombstonedIds(inZone zoneName: String) async throws -> Set<String> {
        lock.withLock { tombstones }
    }

    // Asset seams: inert for these version-round-trip tests, but must not throw
    // (pull/flush consult them on every pass).
    func saveAsset(_ record: SyncAssetRecord, inZone zoneName: String) async throws {}
    func recordAssetTombstone(key: String, inZone zoneName: String) async throws {
        lock.withLock { _ = assetTombstones.insert(key) }
    }
    func clearAssetTombstone(key: String, inZone zoneName: String) async throws {
        lock.withLock { _ = assetTombstones.remove(key) }
    }
    func tombstonedAssetKeys(inZone zoneName: String) async throws -> Set<String> {
        lock.withLock { assetTombstones }
    }

    // MARK: CloudZoneFetcher

    /// Mirrors CKZoneFetcher/recordZoneChanges: every record whose last change is
    /// PAST the token is delivered again (updates included), in change-log order,
    /// coalesced to its latest server state; deletions past the token ride alongside;
    /// the returned token is the current log head (always non-nil, like a real fetch).
    func fetchChanges(inZone zoneName: String, since token: Data?) async throws -> ZoneChanges {
        lock.withLock {
            let sinceSeq = Self.decodeToken(token)
            let changed: [RemoteVersion] = records.values
                .filter { $0.changedAtSeq > sinceSeq }
                .sorted { $0.changedAtSeq < $1.changedAtSeq }
                .map { server in
                    // Mirror CKZoneFetcher.remoteVersion: the delivered record's
                    // updatedAt AND the LWW clock both come from the record's
                    // modifiedAt field — the pushed edit time.
                    let r = server.record
                    let delivered = InspectionVersionRecord(
                        recordName: r.recordName, inspectionId: r.inspectionId,
                        versionNumber: r.versionNumber, status: r.status, locked: r.locked,
                        finalizedAt: r.finalizedAt, schemaVersion: r.schemaVersion,
                        updatedAt: server.modifiedAtField, payload: r.payload
                    )
                    return RemoteVersion(record: delivered, modifiedAt: server.modifiedAtField)
                }
            let deleted = deletions.compactMap { $0.value > sinceSeq ? $0.key : nil }
            return ZoneChanges(changed: changed, deletedRecordNames: deleted, newToken: Self.encodeToken(seq))
        }
    }

    // MARK: Introspection + token codec

    /// The record currently stored on the "server" under a name (nil = absent).
    func serverRecord(named recordName: String) -> InspectionVersionRecord? {
        lock.withLock { records[recordName]?.record }
    }
    /// Total committed mutations (change-log length) — for asserting log growth.
    var changeLogHead: Int { lock.withLock { seq } }

    private static func encodeToken(_ seq: Int) -> Data { Data("\(seq)".utf8) }
    private static func decodeToken(_ data: Data?) -> Int {
        guard let data, let s = String(data: data, encoding: .utf8), let v = Int(s) else { return 0 }
        return v
    }
}

// MARK: - Per-device local store double

/// One device's local-first store at the sync seam: a stateful in-memory version
/// table serving BOTH the reader (push payloads + conflict state) and the writer
/// (pull applies). Models the real pair faithfully:
/// - a genuine local write stamps `updatedAt` (InspectionStore.writeVersionToFile);
/// - `applyRemoteVersion` decodes the payload and upserts, PRESERVING the payload's
///   `updatedAt` — never re-stamped to pull time (InspectionStoreVersionWriter);
/// - `localState` reports exists/isFinalized/updatedAt from the stored version
///   (DiskVersionReader.localState).
private final class FakeDeviceStore: LocalVersionReader, LocalVersionWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var versions: [UUID: InspectionVersion] = [:]
    private(set) var appliedRemoteCount = 0

    /// The device's local write path (create / field edit / finalize): stamps the
    /// LWW clock like a real local write.
    func writeLocal(_ version: InspectionVersion, editedAt: Date) {
        var v = version
        v.updatedAt = editedAt
        lock.withLock { versions[v.id] = v }
    }

    /// What this device's store currently holds for a version (the assertion seam).
    func version(_ id: UUID) -> InspectionVersion? { lock.withLock { versions[id] } }

    // MARK: LocalVersionReader

    func versionData(forVersionId id: UUID) -> Data? {
        guard let v = lock.withLock({ versions[id] }) else { return nil }
        return try? JSONEncoder().encode(v)
    }

    func allLocalVersions() -> [LocalVersionSnapshot] {
        lock.withLock {
            versions.values.compactMap { v in
                guard let data = try? JSONEncoder().encode(v) else { return nil }
                return LocalVersionSnapshot(meta: VersionMetadata(from: v), payload: data)
            }
        }
    }

    func localState(forVersionId id: UUID) -> LocalVersionState {
        guard let v = lock.withLock({ versions[id] }) else { return .absent }
        return LocalVersionState(exists: true, isFinalized: v.locked, updatedAt: v.updatedAt)
    }

    // MARK: LocalVersionWriter

    func applyRemoteVersion(_ payload: Data) async -> Bool {
        guard let v = try? JSONDecoder().decode(InspectionVersion.self, from: payload) else { return true }
        lock.withLock {
            versions[v.id] = v          // updatedAt preserved from the payload
            appliedRemoteCount += 1
        }
        return true
    }

    func deleteLocalVersion(recordName: String) async -> Bool {
        guard let id = UUID(uuidString: recordName) else { return true }
        lock.withLock { versions[id] = nil }
        return true
    }

    func applyRemoteAsset(_ record: SyncAssetRecord) async -> Bool { true }
    func deleteLocalAsset(jobId: UUID, relativePath: String) async -> Bool { true }
}

// MARK: - Remaining per-device fakes

private struct FakeAccount: CloudAccountProviding {
    let token: String?
    func currentUserToken() async -> String? { token }
}

private final class FakeBindings: BindingStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: SyncBinding] = [:]
    func load(forUID uid: String) -> SyncBinding? { lock.withLock { store[uid] } }
    @discardableResult func save(_ binding: SyncBinding) -> Bool {
        lock.withLock { store[binding.firebaseUID] = binding }; return true
    }
    @discardableResult func delete(forUID uid: String) -> Bool {
        lock.withLock { store[uid] = nil }; return true
    }
}

// MARK: - Tests

final class SyncRoundTripRegressionTests: XCTestCase {

    /// One full sync stack — a "device". Both devices in a test share the zone but
    /// nothing else (own store, own bindings/keychain, own port), exactly like two
    /// installs signed into the same account.
    private struct Device {
        let store: FakeDeviceStore
        let bindings: FakeBindings
        let port: CloudKitSyncPort
    }

    private let uid = "roundtrip-uid"
    /// Strictly increasing edit clocks: create < edit < finalize.
    private let tCreate = Date(timeIntervalSince1970: 1_700_000_000)
    private let tEdit = Date(timeIntervalSince1970: 1_700_000_100)
    private let tFinalize = Date(timeIntervalSince1970: 1_700_000_200)

    private func makeDevice(zone: SharedFakeZone) -> Device {
        let store = FakeDeviceStore()
        let bindings = FakeBindings()
        let port = CloudKitSyncPort(
            account: FakeAccount(token: "icloud-tok"),
            database: zone, reader: store, bindings: bindings,
            fetcher: zone, writer: store
        )
        return Device(store: store, bindings: bindings, port: port)
    }

    private func makeDraft(id: UUID) -> InspectionVersion {
        let inspection = Inspection(
            id: id, clientName: "Round Trip Client", clientEmail: "", clientPhone: "",
            propertyAddress: "1 Sync Way", inspectionDate: Date(timeIntervalSince1970: 1_690_000_000),
            inspectorName: "Inspector", sections: []
        )
        return InspectionVersion(id: id, versionNumber: 1, status: .draft, finalizedAt: nil,
                                 locked: false, inspection: inspection)
    }

    /// Writes the version to the editor's local store (stamping `editedAt` as the
    /// LWW clock), records the local change, and pumps the push until the shared
    /// zone reflects THIS edit. The pump is the established idiom
    /// (testFinalizePromotionOverwritesDraftRecordInCloud): `await flushPending()`
    /// is not a strict barrier because recordLocalChange spawns its own flush Task.
    private func writeAndPush(_ version: InspectionVersion, editedAt: Date, on device: Device,
                              zone: SharedFakeZone,
                              file: StaticString = #filePath, line: UInt = #line) async {
        device.store.writeLocal(version, editedAt: editedAt)
        guard let stored = device.store.version(version.id) else {
            XCTFail("local write must land in the device store", file: file, line: line)
            return
        }
        device.port.recordLocalChange(.versionUpserted(VersionMetadata(from: stored)))
        // A short sleep per iteration is required, not just a yield: recordLocalChange
        // spawns its OWN flush Task which claims the port's `_isFlushing` serialization
        // lock; while it is in flight every explicit flushPending() call here is
        // rejected (sets `_flushAgain` and returns), and on a cold executor 200
        // yield-only iterations can spin to exhaustion before that Task ever resumes
        // (observed: the first test of this suite failed exactly that way).
        for _ in 0..<200 where zone.serverRecord(named: version.id.uuidString)?.updatedAt != editedAt {
            await device.port.flushPending()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(zone.serverRecord(named: version.id.uuidString)?.updatedAt, editedAt,
                       "precondition: the push must land in the shared zone before the receiver pulls",
                       file: file, line: line)
    }

    // MARK: 1. CREATE round-trips (guards the path that already works in production)

    func testCreateOnEditorPropagatesToReceiver() async {
        let zone = SharedFakeZone()
        let a = makeDevice(zone: zone)
        let b = makeDevice(zone: zone)
        await a.port.bind(firebaseUID: uid)
        await b.port.bind(firebaseUID: uid)

        let id = UUID()
        await writeAndPush(makeDraft(id: id), editedAt: tCreate, on: a, zone: zone)

        await b.port.pull()

        let received = b.store.version(id)
        XCTAssertNotNil(received, "CREATE must propagate: B's pull applies the new record from the shared zone")
        XCTAssertEqual(received?.locked, false)
        XCTAssertEqual(received?.status, .draft)
        XCTAssertEqual(received?.inspection.clientName, "Round Trip Client")
        XCTAssertEqual(received?.updatedAt, tCreate, "the payload's edit clock is preserved on apply (never re-stamped)")
        XCTAssertNotNil(b.bindings.load(forUID: uid)?.changeToken, "B persists the advanced change token")
    }

    // MARK: 2. UPDATE of an EXISTING record round-trips past a held token

    /// The heart of the production symptom's first half: B already pulled the create
    /// (so B holds a change token PAST the record's insert and a local copy of the
    /// draft). A then edits a field on the EXISTING record. B's next incremental
    /// pull must RE-deliver the updated record and overwrite B's stale draft.
    func testFieldEditOnExistingRecordPropagatesToReceiverWithHeldToken() async {
        let zone = SharedFakeZone()
        let a = makeDevice(zone: zone)
        let b = makeDevice(zone: zone)
        await a.port.bind(firebaseUID: uid)
        await b.port.bind(firebaseUID: uid)

        // A creates → B pulls: B now holds the draft AND a token past its insert.
        let id = UUID()
        await writeAndPush(makeDraft(id: id), editedAt: tCreate, on: a, zone: zone)
        await b.port.pull()
        XCTAssertEqual(b.store.version(id)?.inspection.clientName, "Round Trip Client")
        let tokenAfterCreate = b.bindings.load(forUID: uid)?.changeToken
        XCTAssertNotNil(tokenAfterCreate, "B holds a mid-stream change token after pulling the create")

        // A edits a field on the EXISTING record and pushes.
        guard var edited = a.store.version(id) else { return XCTFail("editor lost its own version") }
        edited.inspection.clientName = "Edited Client"
        await writeAndPush(edited, editedAt: tEdit, on: a, zone: zone)

        // B pulls incrementally from its held token.
        await b.port.pull()

        XCTAssertEqual(b.store.version(id)?.inspection.clientName, "Edited Client",
                       "UPDATE of an existing record must re-deliver past B's held token and replace the stale draft — the production symptom")
        XCTAssertEqual(b.store.version(id)?.updatedAt, tEdit, "B's copy carries the edit's LWW clock")
        XCTAssertEqual(b.store.appliedRemoteCount, 2,
                       "the incremental fetch re-delivered the UPDATED record (updates, not just inserts)")
        XCTAssertNotEqual(b.bindings.load(forUID: uid)?.changeToken, tokenAfterCreate,
                          "the second pull advances B's token past the update")
    }

    // MARK: 3. FINALIZE round-trips — receiver pulled between EVERY step

    /// THE production symptom: A finalizes (locked=1) an inspection B already has as
    /// a draft; B pulls and must show it finalized. B pulls between every step, so
    /// its token always sits just behind the next change (the worst case for a
    /// fetcher that only delivers inserts).
    func testFinalizePropagatesToReceiverWhoPulledAtEveryStep() async {
        let zone = SharedFakeZone()
        let a = makeDevice(zone: zone)
        let b = makeDevice(zone: zone)
        await a.port.bind(firebaseUID: uid)
        await b.port.bind(firebaseUID: uid)

        // Step 1: create → push → B pulls.
        let id = UUID()
        await writeAndPush(makeDraft(id: id), editedAt: tCreate, on: a, zone: zone)
        await b.port.pull()
        XCTAssertEqual(b.store.version(id)?.locked, false, "after step 1 B has the draft")

        // Step 2: field edit → push → B pulls.
        guard var edited = a.store.version(id) else { return XCTFail("editor lost its own version") }
        edited.inspection.clientName = "Edited Client"
        await writeAndPush(edited, editedAt: tEdit, on: a, zone: zone)
        await b.port.pull()
        XCTAssertEqual(b.store.version(id)?.inspection.clientName, "Edited Client",
                       "after step 2 B reflects the field edit")

        // Step 3: finalize → push → B pulls. (Finalize keeps the SAME versionId; the
        // zone's draft record is OVERWRITTEN with the locked one — fix A.)
        guard var finalized = a.store.version(id) else { return XCTFail("editor lost its own version") }
        finalized.status = .final
        finalized.locked = true
        finalized.finalizedAt = tFinalize
        await writeAndPush(finalized, editedAt: tFinalize, on: a, zone: zone)
        XCTAssertEqual(zone.serverRecord(named: id.uuidString)?.locked, true,
                       "the finalize overwrote the zone's draft record (fix A)")

        let tokenBeforeFinalPull = b.bindings.load(forUID: uid)?.changeToken
        await b.port.pull()

        let received = b.store.version(id)
        XCTAssertEqual(received?.locked, true,
                       "FINALIZE must propagate: B's pull re-delivers the locked record past B's held token — the production symptom")
        XCTAssertEqual(received?.status, .final)
        XCTAssertEqual(received?.finalizedAt, tFinalize)
        XCTAssertEqual(received?.inspection.clientName, "Edited Client", "the finalized payload carries the edit")
        XCTAssertNotEqual(b.bindings.load(forUID: uid)?.changeToken, tokenBeforeFinalPull,
                          "the finalize pull advances B's token")
    }

    // MARK: 4. FINALIZE round-trips — receiver pulls only ONCE at the end

    /// Same create → edit → finalize sequence, but B holds its token from BEFORE the
    /// create (bound against the empty zone) and pulls exactly once at the end. The
    /// single incremental fetch must deliver the record's NET state — finalized,
    /// with the edit — coalesced the way recordZoneChanges delivers the latest
    /// version of each changed record.
    func testFinalizePropagatesToReceiverWhoPullsOnlyAtTheEnd() async {
        let zone = SharedFakeZone()
        let a = makeDevice(zone: zone)
        let b = makeDevice(zone: zone)
        await a.port.bind(firebaseUID: uid)
        await b.port.bind(firebaseUID: uid)   // B's token now sits at the EMPTY zone's log head

        let id = UUID()
        await writeAndPush(makeDraft(id: id), editedAt: tCreate, on: a, zone: zone)

        guard var edited = a.store.version(id) else { return XCTFail("editor lost its own version") }
        edited.inspection.clientName = "Edited Client"
        await writeAndPush(edited, editedAt: tEdit, on: a, zone: zone)

        guard var finalized = a.store.version(id) else { return XCTFail("editor lost its own version") }
        finalized.status = .final
        finalized.locked = true
        finalized.finalizedAt = tFinalize
        await writeAndPush(finalized, editedAt: tFinalize, on: a, zone: zone)

        // B's ONLY pull after binding.
        await b.port.pull()

        let received = b.store.version(id)
        XCTAssertEqual(received?.locked, true, "a single end pull lands the finalized state")
        XCTAssertEqual(received?.status, .final)
        XCTAssertEqual(received?.finalizedAt, tFinalize)
        XCTAssertEqual(received?.inspection.clientName, "Edited Client")
        XCTAssertEqual(b.store.appliedRemoteCount, 1,
                       "three pushes to one record coalesce to ONE net-state delivery (like recordZoneChanges)")
    }

    // MARK: 5. The zone double itself surfaces conflicts like the real backend

    /// Guards the double's own semantics (so the round-trip tests can't silently
    /// pass on a toothless fake): a draft save whose fetch→commit window is crossed
    /// by another device's FINALIZE hits the stale-tag conflict, re-fetches, sees
    /// locked, and leaves the finalized record untouched — the exact
    /// serverRecordChanged path CKCloudDatabase.save implements.
    func testZoneSaveSurfacesStaleTagConflictAndPreservesFinalizedRecord() async throws {
        let zone = SharedFakeZone()
        let id = UUID()
        let zoneName = CloudKitSchema.zoneName(forFirebaseUID: uid)

        // The record exists as a draft (v1, tCreate).
        let draft = InspectionRecordMapper.make(
            meta: VersionMetadata(id: id, inspectionId: id, versionNumber: 1, status: .draft,
                                  finalizedAt: nil, locked: false, clientName: "C", propertyAddress: "P",
                                  inspectionDate: tCreate, updatedAt: tCreate),
            payload: Data("draft-v1".utf8)
        )
        try await zone.save(draft, inZone: zoneName)
        let logAfterDraft = zone.changeLogHead

        // Another device finalizes the SAME record inside our next save's
        // fetch→commit window.
        let finalized = InspectionRecordMapper.make(
            meta: VersionMetadata(id: id, inspectionId: id, versionNumber: 1, status: .final,
                                  finalizedAt: tFinalize, locked: true, clientName: "C", propertyAddress: "P",
                                  inspectionDate: tCreate, updatedAt: tFinalize),
            payload: Data("final".utf8)
        )
        zone.onFetchSaveWindow = { $0.commitAsOtherDevice(finalized) }

        // Our (now stale) draft edit: attempt 1 commits against the pre-finalize tag
        // → serverRecordChanged; attempt 2 re-fetches, sees locked → returns, leaving
        // the finalized record immutable. Must NOT throw (the other device won).
        let staleEdit = InspectionRecordMapper.make(
            meta: VersionMetadata(id: id, inspectionId: id, versionNumber: 1, status: .draft,
                                  finalizedAt: nil, locked: false, clientName: "C2", propertyAddress: "P",
                                  inspectionDate: tCreate, updatedAt: tEdit),
            payload: Data("draft-v2".utf8)
        )
        try await zone.save(staleEdit, inZone: zoneName)

        let server = zone.serverRecord(named: id.uuidString)
        XCTAssertEqual(server?.locked, true, "the concurrent finalize wins; the stale draft never clobbers it")
        XCTAssertEqual(server?.payload, Data("final".utf8))
        XCTAssertEqual(zone.changeLogHead, logAfterDraft + 1,
                       "only the finalize committed — the stale save surfaced serverRecordChanged and backed off")

        // And a receiver pulling from a pre-conflict token gets the finalized state.
        let changes = try await zone.fetchChanges(inZone: zoneName, since: nil)
        XCTAssertEqual(changes.changed.count, 1)
        XCTAssertEqual(changes.changed.first?.record.locked, true)
    }

    // MARK: 6. RECEIVER-side stale write-back (store level) — the confirmed defect

    /// The receiver-side production defect ABOVE the sync seam: the inspector has the
    /// draft OPEN in InspectionView while a remote FINALIZE of the same version is
    /// applied by a pull. When the view disappears, `InspectionView.onDisappear`
    /// unconditionally writes back its (now stale, unlocked) in-memory draft via
    /// `store.update(version:)` — and `update` validates only the PASSED version's
    /// state (`allowsEdit(version.state)`), NOT the authoritative `metadataList`/disk
    /// row, so the stale draft REVERTS the applied finalize, re-stamps `updatedAt`,
    /// and echo-pushes the reversion to every other device.
    ///
    /// EXPECTED TO FAIL on current code — the failure IS the reproduction. Do not
    /// weaken the assertions; they become the regression gate for the fix. Disk
    /// stash/restore mirrors Build22Slice4cSyncTests (the store has no injectable root).
    @MainActor
    func testStaleOpenDraftUpdateCannotRevertAppliedRemoteFinalize() throws {
        // --- Stash the real on-disk store aside; restore in teardown. ---
        let fm = FileManager.default
        try FileSecurity.ensureProtectedDirectory(FilePaths.appRoot)
        let stash = fm.temporaryDirectory.appendingPathComponent("ngs-stalewb-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stash, withIntermediateDirectories: true)
        let inspectionsDir = FilePaths.appRoot.appendingPathComponent("Inspections", isDirectory: true)
        let stashedPairs: [(name: String, live: URL)] = [
            ("Inspections", inspectionsDir),
            ("inspections.json", FilePaths.inspectionsIndex),
            ("inspections.json.backup", FilePaths.inspectionsIndexBackup)
        ]
        for (name, live) in stashedPairs where fm.fileExists(atPath: live.path) {
            try fm.moveItem(at: live, to: stash.appendingPathComponent(name))
        }
        addTeardownBlock {
            for (name, live) in stashedPairs {
                try? fm.removeItem(at: live)
                let src = stash.appendingPathComponent(name)
                if fm.fileExists(atPath: src.path) { try? fm.moveItem(at: src, to: live) }
            }
            try? fm.removeItem(at: stash)
        }

        let port = RecordingSyncPort()
        let coord = SyncCoordinator(isEnabled: { true }, makeCloudPort: { port })
        let store = InspectionStore()
        store.syncCoordinator = coord
        coord.userDidChange(uid: "stale-wb-uid")

        // 1) The inspector's local DRAFT exists (and is open in InspectionView).
        let id = UUID()
        let draft = makeDraft(id: id)
        store.insert(version: draft)
        XCTAssertEqual(store.metadataList.first { $0.id == id }?.locked, false)
        let pushesBeforeWriteBack: Int

        // 2) A remote FINALIZE of the SAME version arrives via pull and is applied.
        var finalized = draft
        finalized.status = .final
        finalized.locked = true
        finalized.finalizedAt = tFinalize
        finalized.updatedAt = tFinalize
        XCTAssertTrue(store.applyRemoteVersion(finalized), "the remote finalize applies cleanly")
        XCTAssertEqual(store.metadataList.first { $0.id == id }?.locked, true, "precondition: the row is finalized")
        XCTAssertEqual(store.loadFullVersion(id: id)?.locked, true, "precondition: disk is finalized")
        pushesBeforeWriteBack = port.count

        // 3) The still-open view disappears and writes back its STALE unlocked copy
        //    (InspectionView.onDisappear → updated(draft) → store.update(version:)).
        var staleOpenCopy = draft
        staleOpenCopy.inspection.clientName = "Stale Open Copy"
        store.update(version: staleOpenCopy)

        // THE DEFECT: update() must refuse the stale write-back against the
        // authoritative (finalized) row — currently it only checks the PASSED
        // version's state, so all three assertions fail on current code.
        XCTAssertEqual(store.metadataList.first { $0.id == id }?.locked, true,
                       "a stale open draft's write-back must not revert the applied remote finalize (metadata row)")
        XCTAssertEqual(store.loadFullVersion(id: id)?.locked, true,
                       "a stale open draft's write-back must not revert the finalized current.json on disk")
        XCTAssertEqual(port.count, pushesBeforeWriteBack,
                       "a refused stale write-back must not echo a sync push (it would propagate the reversion)")

        // Flush the debounced index save NOW so it can't fire after teardown restores
        // the real inspections.json (test hygiene, not part of the assertion).
        store.saveNow()
    }
}

/// Minimal recording SyncPort for the store-level test (the NexGenSpecTests.swift
/// original is file-private there).
private final class RecordingSyncPort: SyncPort, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var changes: [SyncChange] = []
    var status: SyncStatus = .idle
    func bind(firebaseUID: String) async {}
    func unbind() {}
    func recordLocalChange(_ change: SyncChange) { lock.withLock { changes.append(change) } }
    func seedIfNeeded(firebaseUID: String) async {}
    func pull() async {}
    func flushPending() async {}
    var count: Int { lock.withLock { changes.count } }
}
