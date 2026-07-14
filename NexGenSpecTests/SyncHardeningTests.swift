//
//  SyncHardeningTests.swift
//  NexGenSpecTests
//
//  Regression tests for the sync-push hardening set (items A1–A8):
//   - A1: per-record modifyRecords Results are verified, never discarded — a
//     per-record .failure (or a missing result entry) re-queues the change and
//     never stamps a seed phase as done.
//   - A2: the pending queue is a durable per-UID outbox (sync-outbox.json) —
//     queued changes survive port teardown/force-quit; a corrupt file is
//     discarded, never a crash/wedge.
//   - A3: bind-time reconciliation re-enqueues every locally-finalized version
//     (NOT gated on seededAt); the server-side lock guard is the dedupe.
//   - A4: finalize() surfaces a version-file write failure instead of silently
//     proceeding as if the finalize persisted.
//   - A5: an existing-but-unreadable local file THROWS on the push read (change
//     retained); only CONFIRMED absence dequeues.
//   - A6: the coordinator mirrors the port's status after every pull/flush cycle,
//     so a failed upload reaches the Settings row and recovery clears it.
//   - A8: the asset writer HOLDS the change token on a cross-account mismatch and
//     on a real file-removal failure (parity with the version writer).
//
//  Uses the same fake/idiom style as CloudKitSyncPortTests. CloudKit is imported
//  ONLY to construct value types (CKRecord.ID / CKRecord / CKError) for the A1
//  result-verification helpers — no server round-trips.
//

import XCTest
import CloudKit
@testable import NexGenSpec

// MARK: - Fakes

private struct FakeAccount: CloudAccountProviding {
    let token: String?
    func currentUserToken() async -> String? { token }
}

/// A CloudAccountProviding stub with a mutable token (mirrors SyncCoordinatorTests).
private final class StubAccount: CloudAccountProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _token: String?
    init(token: String?) { _token = token }
    func currentUserToken() async -> String? { lock.withLock { _token } }
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

/// LocalVersionReader whose read behavior is mutable mid-test, so one port can be
/// driven through unreadable → readable → absent transitions (A5).
private final class MutableReader: LocalVersionReader, @unchecked Sendable {
    enum Mode { case data(Data), absent, unreadable }
    private let lock = NSLock()
    private var _mode: Mode
    private var _snapshots: [LocalVersionSnapshot] = []
    init(mode: Mode = .data(Data("payload".utf8))) { _mode = mode }
    var mode: Mode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }
    var snapshots: [LocalVersionSnapshot] {
        get { lock.withLock { _snapshots } }
        set { lock.withLock { _snapshots = newValue } }
    }
    func versionData(forVersionId id: UUID) throws -> Data? {
        switch mode {
        case .data(let d): return d
        case .absent: return nil
        case .unreadable: throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }
    }
    func allLocalVersions() -> [LocalVersionSnapshot] { snapshots }
    func localState(forVersionId id: UUID) -> LocalVersionState { .absent }
}

/// A CloudDatabase whose saves simulate the exact A1 failure shape: the
/// `modifyRecords` CALL succeeds (no throw from CloudKit) but the PER-RECORD
/// Result carries the failure — or is missing entirely. It routes the simulated
/// results through the REAL `CKCloudDatabase.verifySaveResults`, so the port-level
/// tests exercise the production verification logic end to end.
private final class ResultFakeDatabase: CloudDatabase, @unchecked Sendable {
    enum ResultMode { case success, perRecordFailure, missingEntry }
    private let lock = NSLock()
    private var _saveMode: ResultMode = .success
    private var _assetSaveMode: ResultMode = .success
    private var saved: [(record: InspectionVersionRecord, zone: String)] = []
    private var savedAssets: [(record: SyncAssetRecord, zone: String)] = []
    private var tombstones: Set<String> = []
    private var assetTombstones: Set<String> = []
    /// Models the live zone's record store (keyed by recordName) INCLUDING
    /// CKCloudDatabase's server-side immutability guard (fix A): saving over an
    /// already-locked stored record is a guard-skip SUCCESS — no throw, no
    /// mutation, no `saved` append. Needed by the A3 reconciliation tests.
    private var stored: [String: InspectionVersionRecord] = [:]

    var saveMode: ResultMode {
        get { lock.withLock { _saveMode } }
        set { lock.withLock { _saveMode = newValue } }
    }
    var assetSaveMode: ResultMode {
        get { lock.withLock { _assetSaveMode } }
        set { lock.withLock { _assetSaveMode = newValue } }
    }
    var savedCount: Int { lock.withLock { saved.count } }
    var savedAssetCount: Int { lock.withLock { savedAssets.count } }
    /// The record currently stored under a name (nil if never stored).
    func record(named recordName: String) -> InspectionVersionRecord? { lock.withLock { stored[recordName] } }
    /// Pre-seed the fake server's record store (e.g. a stale draft another
    /// device pushed, or an already-finalized immutable record).
    func seedStored(_ record: InspectionVersionRecord) { lock.withLock { stored[record.recordName] = record } }

    private func verifySimulatedSave(recordName: String, zone: String, mode: ResultMode) throws {
        let zoneID = CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName)
        let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let results: [CKRecord.ID: Result<CKRecord, Error>]
        switch mode {
        case .success:
            results = [id: .success(CKRecord(recordType: "Test", recordID: id))]
        case .perRecordFailure:
            results = [id: .failure(CKError(.quotaExceeded))]
        case .missingEntry:
            results = [:]
        }
        try CKCloudDatabase.verifySaveResults(results, submitted: [id])
    }

    func ensureZone(_ zoneName: String) async throws {}
    func save(_ record: InspectionVersionRecord, inZone zoneName: String) async throws {
        // Server-side immutability guard first (mirrors CKCloudDatabase.save's
        // fetch-and-guard, which SKIPS before any modifyRecords happens).
        let guarded: Bool = lock.withLock { stored[record.recordName]?.locked == true }
        if guarded { return }
        try verifySimulatedSave(recordName: record.recordName, zone: zoneName, mode: saveMode)
        lock.withLock {
            stored[record.recordName] = record
            saved.append((record, zoneName))
        }
    }
    func delete(recordName: String, inZone zoneName: String) async throws {}
    func deleteZone(_ zoneName: String) async throws {}
    func recordTombstone(versionId: String, inZone zoneName: String) async throws {
        lock.withLock { _ = tombstones.insert(versionId) }
    }
    func tombstonedIds(inZone zoneName: String) async throws -> Set<String> { lock.withLock { tombstones } }
    func saveAsset(_ record: SyncAssetRecord, inZone zoneName: String) async throws {
        try verifySimulatedSave(recordName: record.recordName, zone: zoneName, mode: assetSaveMode)
        lock.withLock { savedAssets.append((record, zoneName)) }
    }
    func recordAssetTombstone(key: String, inZone zoneName: String) async throws {
        lock.withLock { _ = assetTombstones.insert(key) }
    }
    func clearAssetTombstone(key: String, inZone zoneName: String) async throws {
        lock.withLock { _ = assetTombstones.remove(key) }
    }
    func tombstonedAssetKeys(inZone zoneName: String) async throws -> Set<String> { lock.withLock { assetTombstones } }
}

/// SyncPort whose flushPending outcome is scriptable, for the A6 coordinator
/// status-mirroring test.
private final class StatusPort: SyncPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: SyncStatus = .idle
    private var _flushFails = false
    var status: SyncStatus { lock.withLock { _status } }
    var flushFails: Bool {
        get { lock.withLock { _flushFails } }
        set { lock.withLock { _flushFails = newValue } }
    }
    func bind(firebaseUID: String) async {}
    func unbind() {}
    func recordLocalChange(_ change: SyncChange) {}
    func seedIfNeeded(firebaseUID: String) async {}
    func pull() async {}
    func flushPending() async {
        lock.withLock {
            _status = _flushFails ? .error("Some changes couldn't be uploaded yet; still queued.") : .idle
        }
    }
}

// MARK: - Tests

final class SyncHardeningTests: XCTestCase {

    private func meta(_ id: UUID = UUID()) -> VersionMetadata {
        VersionMetadata(
            id: id, inspectionId: UUID(), versionNumber: 1, status: .draft,
            finalizedAt: nil, locked: false, clientName: "Client",
            propertyAddress: "Addr", inspectionDate: Date()
        )
    }

    private func makePort(db: ResultFakeDatabase,
                          reader: MutableReader = MutableReader(),
                          bindings: FakeBindings = FakeBindings()) -> CloudKitSyncPort {
        CloudKitSyncPort(account: FakeAccount(token: "tok"), database: db, reader: reader, bindings: bindings)
    }

    /// `await flushPending()` is not a strict barrier (the `_flushAgain` re-run can
    /// hold the flush lock) — pump until the condition holds or attempts run out,
    /// same as CloudKitSyncPortTests.
    private func pumpFlush(_ port: CloudKitSyncPort, until condition: () -> Bool = { false }, attempts: Int = 50) async {
        for _ in 0..<attempts where !condition() {
            await port.flushPending()
            await Task.yield()
        }
    }

    /// Polls until `condition` holds (the port's status is written at the END of a
    /// flush that may run on a spawned Task, so assert eventually, not instantly).
    @discardableResult
    private func waitUntil(_ condition: () -> Bool, timeoutMs: Int = 2000) async -> Bool {
        for _ in 0..<(timeoutMs / 10) {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func isError(_ status: SyncStatus) -> Bool {
        if case .error = status { return true }
        return false
    }

    // MARK: - A1: per-record result verification (helper level)

    private func recordID(_ name: String = "r1", owner: String = CKCurrentUserDefaultName) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: CKRecordZone.ID(zoneName: "zone", ownerName: owner))
    }

    func testVerifySaveResultsThrowsThePerRecordFailure() {
        let id = recordID()
        let results: [CKRecord.ID: Result<CKRecord, Error>] = [id: .failure(CKError(.quotaExceeded))]
        XCTAssertThrowsError(try CKCloudDatabase.verifySaveResults(results, submitted: [id]),
                             "a per-record .failure returned in the results must THROW, not be discarded (A1)") { error in
            XCTAssertEqual((error as? CKError)?.code, .quotaExceeded, "the concrete per-record error is re-thrown")
        }
    }

    func testVerifySaveResultsThrowsOnMissingResultEntry() {
        let id = recordID()
        XCTAssertThrowsError(try CKCloudDatabase.verifySaveResults([:], submitted: [id]),
                             "no per-record result = no evidence the save landed; must fail closed (A1)") { error in
            XCTAssertTrue((error as NSError).localizedDescription.contains("r1"),
                          "the synthetic error names the record so diagnostics are actionable")
        }
    }

    func testVerifySaveResultsMatchesByRecordNameNotIDEquality() {
        // The re-fetched server record's zoneID carries the RESOLVED owner name,
        // not CKCurrentUserDefaultName — CKRecord.ID-equality matching would MISS
        // the result and misreport a clean save as missing (A1's recordName rule).
        let constructed = recordID("r1", owner: CKCurrentUserDefaultName)
        let serverSide = recordID("r1", owner: "_resolvedOwner123")
        let results: [CKRecord.ID: Result<CKRecord, Error>] =
            [serverSide: .success(CKRecord(recordType: "Test", recordID: serverSide))]
        XCTAssertNoThrow(try CKCloudDatabase.verifySaveResults(results, submitted: [constructed]),
                         "a clean save keyed under a different zone OWNER must match by recordName")
    }

    func testVerifyDeleteResultsUnknownItemIsIdempotentSuccessButRealFailuresThrow() {
        let id = recordID()
        // Already-absent is the delete's goal state — throwing would wedge the
        // queue forever on a change that can never succeed "harder".
        let absent: [CKRecord.ID: Result<Void, Error>] = [id: .failure(CKError(.unknownItem))]
        XCTAssertNoThrow(try CKCloudDatabase.verifyDeleteResults(absent, submitted: [id]),
                         "delete of an already-absent record is idempotent success")

        let failed: [CKRecord.ID: Result<Void, Error>] = [id: .failure(CKError(.networkFailure))]
        XCTAssertThrowsError(try CKCloudDatabase.verifyDeleteResults(failed, submitted: [id]),
                             "a real per-record delete failure must throw (A1)")

        XCTAssertThrowsError(try CKCloudDatabase.verifyDeleteResults([:], submitted: [id]),
                             "a missing delete result must fail closed (A1)")
    }

    // MARK: - A1: per-record failure keeps the change queued (port level)

    func testPerRecordSaveFailureKeepsChangeQueuedThenRepushes() async {
        // Unique UID: the durable outbox (A2) persists per-UID across tests/runs,
        // so shared UIDs would leak queued changes between tests.
        let uid = "hardening-a1-fail-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: FilePaths.userRoot(uid: uid)) }
        let db = ResultFakeDatabase()
        let port = makePort(db: db)
        await port.bind(firebaseUID: uid)

        db.saveMode = .perRecordFailure
        port.recordLocalChange(.versionUpserted(meta()))
        await pumpFlush(port)

        XCTAssertEqual(db.savedCount, 0, "a per-record .failure must never count as a successful push (A1)")
        // The status is written at the END of a flush that may run on a spawned
        // Task — wait for it to settle rather than sampling mid-flush.
        let flippedToError = await waitUntil { self.isError(port.status) }
        XCTAssertTrue(flippedToError, "a failed push must surface as .error, got \(port.status)")

        // The change stayed QUEUED: once the per-record results are clean it pushes.
        db.saveMode = .success
        await pumpFlush(port, until: { db.savedCount == 1 }, attempts: 200)
        XCTAssertEqual(db.savedCount, 1, "the change was re-queued across the failure and pushed on recovery (A1)")
        let recovered = await waitUntil { port.status == .idle }
        XCTAssertTrue(recovered, "a clean flush clears the error status, got \(port.status)")
    }

    func testMissingSaveResultEntryKeepsChangeQueuedThenRepushes() async {
        let uid = "hardening-a1-missing-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: FilePaths.userRoot(uid: uid)) }
        let db = ResultFakeDatabase()
        let port = makePort(db: db)
        await port.bind(firebaseUID: uid)

        db.saveMode = .missingEntry
        port.recordLocalChange(.versionUpserted(meta()))
        await pumpFlush(port)

        XCTAssertEqual(db.savedCount, 0, "a missing per-record result must never count as a successful push (A1)")
        let flippedToError = await waitUntil { self.isError(port.status) }
        XCTAssertTrue(flippedToError, "a missing-result push must surface as .error, got \(port.status)")

        db.saveMode = .success
        await pumpFlush(port, until: { db.savedCount == 1 }, attempts: 200)
        XCTAssertEqual(db.savedCount, 1, "the change survived the missing-result failure and pushed on recovery (A1)")
    }

    func testAssetSeedPerRecordFailureDoesNotStampAssetsSeededAt() async throws {
        let uid = "hardening-seed-\(UUID().uuidString)"
        let root = FilePaths.userRoot(uid: uid)
        defer { try? FileManager.default.removeItem(at: root) }

        // One local version whose inspection folder holds one seedable thumbnail.
        let inspectionId = UUID()
        let m = VersionMetadata(
            id: inspectionId, inspectionId: inspectionId, versionNumber: 1, status: .draft,
            finalizedAt: nil, locked: false, clientName: "C", propertyAddress: "A", inspectionDate: Date()
        )
        let thumbDir = root.appendingPathComponent("Inspections/\(inspectionId.uuidString)/thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: thumbDir.appendingPathComponent("photo.jpg"))

        let db = ResultFakeDatabase()
        db.assetSaveMode = .perRecordFailure   // versions clean, assets fail per-record
        let reader = MutableReader()
        reader.snapshots = [LocalVersionSnapshot(meta: m, payload: Data("seed".utf8))]
        let bindings = FakeBindings()
        let port = CloudKitSyncPort(account: FakeAccount(token: "tok"), database: db, reader: reader, bindings: bindings)

        await port.bind(firebaseUID: uid)

        XCTAssertEqual(db.savedCount, 1, "the version seed phase pushed the snapshot")
        XCTAssertNotNil(bindings.load(forUID: uid)?.seededAt, "the clean version phase is marked seeded")
        XCTAssertEqual(db.savedAssetCount, 0, "the per-record asset failure must not count as pushed (A1)")
        XCTAssertNil(bindings.load(forUID: uid)?.assetsSeededAt,
                     "a failed asset seed phase must NOT stamp assetsSeededAt — it re-runs on the next bind (A1)")
    }

    // MARK: - A5: absence vs read failure on the push read

    func testDiskVersionReaderThrowsOnUnreadableFileAndNilOnlyWhenAbsent() throws {
        let uid = "hardening-reader-\(UUID().uuidString)"
        let root = FilePaths.userRoot(uid: uid)
        let id = UUID()
        let url = FilePaths.currentVersionFile(jobId: id, inRoot: root)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? fm.removeItem(at: root)
        }

        let reader = DiskVersionReader(uid: uid)
        XCTAssertThrowsError(try reader.versionData(forVersionId: id),
                             "an existing-but-unreadable current.json must THROW, not masquerade as absence (A5)")
        XCTAssertNil(try reader.versionData(forVersionId: UUID()),
                     "a confirmed-absent file returns nil without throwing (settle the change)")
    }

    func testUnreadableVersionFileKeepsChangeQueuedButConfirmedAbsenceDequeues() async {
        let uid = "hardening-a5-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: FilePaths.userRoot(uid: uid)) }
        let db = ResultFakeDatabase()
        let reader = MutableReader(mode: .unreadable)
        let port = makePort(db: db, reader: reader)
        await port.bind(firebaseUID: uid)

        // Unreadable read → the change must survive the flush (re-queued).
        port.recordLocalChange(.versionUpserted(meta()))
        await pumpFlush(port)
        XCTAssertEqual(db.savedCount, 0, "an unreadable payload must not be pushed")
        let flippedToError = await waitUntil { self.isError(port.status) }
        XCTAssertTrue(flippedToError, "an unreadable payload is a push FAILURE, not a skip — got \(port.status)")

        // The file becomes readable → the retained change pushes.
        reader.mode = .data(Data("payload".utf8))
        await pumpFlush(port, until: { db.savedCount == 1 }, attempts: 200)
        XCTAssertEqual(db.savedCount, 1, "the change was retained across the read failure and pushed on recovery (A5)")

        // Confirmed absence → the change is settled (dequeued), no error.
        reader.mode = .absent
        port.recordLocalChange(.versionUpserted(meta()))
        await pumpFlush(port)
        XCTAssertEqual(db.savedCount, 1, "a confirmed-absent file settles the change without a push")
        let settledIdle = await waitUntil { port.status == .idle }
        XCTAssertTrue(settledIdle, "confirmed absence is a settle, not an error — got \(port.status)")

        // Prove it was DEQUEUED: making data readable again must not resurrect it.
        reader.mode = .data(Data("payload".utf8))
        await pumpFlush(port)
        XCTAssertEqual(db.savedCount, 1, "the settled change does not come back")
    }

    func testUnreadableMediaFileKeepsChangeQueuedThenRepushes() async throws {
        let uid = "hardening-media-\(UUID().uuidString)"
        let root = FilePaths.userRoot(uid: uid)
        let fm = FileManager.default
        let jobId = UUID()
        let rel = "Inspections/\(jobId.uuidString)/thumbnails/\(UUID().uuidString).jpg"
        let fileURL = root.appendingPathComponent(rel)
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: fileURL)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
            try? fm.removeItem(at: root)
        }

        let db = ResultFakeDatabase()
        let port = makePort(db: db)
        await port.bind(firebaseUID: uid)

        port.recordLocalChange(.mediaUpserted(jobId: jobId, relativePath: rel))
        await pumpFlush(port)
        XCTAssertEqual(db.savedAssetCount, 0, "an unreadable media file must not be pushed")
        let flippedToError = await waitUntil { self.isError(port.status) }
        XCTAssertTrue(flippedToError, "an unreadable media file is a push FAILURE (re-queued), not a silent dequeue — got \(port.status)")

        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        await pumpFlush(port, until: { db.savedAssetCount == 1 }, attempts: 200)
        XCTAssertEqual(db.savedAssetCount, 1, "the media change was retained across the read failure and pushed on recovery (A5)")
    }

    // MARK: - A2: durable outbox

    func testSyncChangeCodableRoundTrip() throws {
        let changes: [SyncChange] = [
            .versionUpserted(meta()),
            .versionDeleted(versionId: UUID()),
            .mediaUpserted(jobId: UUID(), relativePath: "Inspections/x/thumbnails/t.jpg"),
            .mediaDeleted(jobId: UUID(), relativePath: "Reports/folder/Inspection_Report.pdf")
        ]
        let data = try JSONEncoder().encode(changes)
        let decoded = try JSONDecoder().decode([SyncChange].self, from: data)
        XCTAssertEqual(decoded, changes, "SyncChange must round-trip Codable losslessly — it is the outbox's on-disk format (A2)")
    }

    func testOutboxSurvivesPortTeardownAndPushesOnNextBind() async throws {
        let uid = "hardening-a2-outbox-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: FilePaths.userRoot(uid: uid)) }
        let binds = FakeBindings()

        // Port 1: every push fails per-record, so the change stays queued — and,
        // with A2, persisted to the outbox file.
        let db1 = ResultFakeDatabase()
        let port1 = makePort(db: db1, bindings: binds)
        await port1.bind(firebaseUID: uid)
        db1.saveMode = .perRecordFailure
        let m = meta()
        port1.recordLocalChange(.versionUpserted(m))
        await pumpFlush(port1)
        XCTAssertEqual(db1.savedCount, 0, "the push failed; nothing landed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: CloudKitSyncPort.outboxURL(forUID: uid).path),
                      "the queued change is persisted to the per-UID outbox (A2)")
        // Tear the port down. unbind persists-then-clears MEMORY but leaves the
        // FILE — the file is the durability.
        port1.unbind()
        XCTAssertTrue(FileManager.default.fileExists(atPath: CloudKitSyncPort.outboxURL(forUID: uid).path),
                      "unbind leaves the outbox file in place (A2 d)")

        // Port 2 — a fresh instance (new-process analog): bind restores the outbox
        // and the bind-tail flush pushes the change.
        let db2 = ResultFakeDatabase()
        let port2 = makePort(db: db2, bindings: binds)
        await port2.bind(firebaseUID: uid)
        await pumpFlush(port2, until: { db2.savedCount == 1 }, attempts: 200)
        XCTAssertEqual(db2.savedCount, 1, "the change queued before teardown flushes from the restored outbox (A2)")
        XCTAssertNotNil(db2.record(named: m.id.uuidString), "and it is the SAME change that was stranded")
    }

    func testCorruptOutboxIsDiscardedAndSyncContinues() async throws {
        let uid = "hardening-a2-corrupt-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: FilePaths.userRoot(uid: uid)) }
        let url = CloudKitSyncPort.outboxURL(forUID: uid)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is {{{ not json".utf8).write(to: url)

        let db = ResultFakeDatabase()
        let port = makePort(db: db)
        await port.bind(firebaseUID: uid)   // must not crash or wedge

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a corrupt outbox is deleted, not retried forever (A2)")
        let idle = await waitUntil { port.status == .idle }
        XCTAssertTrue(idle, "sync continues normally after discarding the corrupt outbox, got \(port.status)")

        // And the port still works end to end afterwards.
        port.recordLocalChange(.versionUpserted(meta()))
        await pumpFlush(port, until: { db.savedCount == 1 }, attempts: 200)
        XCTAssertEqual(db.savedCount, 1, "a fresh change enqueues, persists, and pushes normally")
    }

    // MARK: - A3: bind-time locked-state reconciliation

    private func lockedMeta(_ id: UUID = UUID()) -> VersionMetadata {
        VersionMetadata(
            id: id, inspectionId: UUID(), versionNumber: 1, status: .final,
            finalizedAt: Date(), locked: true, clientName: "C",
            propertyAddress: "A", inspectionDate: Date()
        )
    }

    private func serverRecord(id: UUID, locked: Bool, payload: Data) -> InspectionVersionRecord {
        InspectionVersionRecord(
            recordName: id.uuidString, inspectionId: UUID().uuidString, versionNumber: 1,
            status: locked ? "Final" : "Draft", locked: locked,
            finalizedAt: locked ? Date(timeIntervalSince1970: 1000) : nil,
            schemaVersion: 1, updatedAt: nil, payload: payload
        )
    }

    /// A binding whose seed phases are BOTH already stamped — proving A3's
    /// reconciliation is not gated on seededAt (the flag that blocks recovery).
    private func preSeededBinding(uid: String) -> SyncBinding {
        var binding = SyncBinding(
            firebaseUID: uid, cloudUserToken: "tok",
            zoneName: CloudKitSchema.zoneName(forFirebaseUID: uid), boundAt: Date()
        )
        binding.seededAt = Date()
        binding.assetsSeededAt = Date()
        return binding
    }

    func testBindReconciliationPromotesStrandedFinalizeOverServerDraft() async throws {
        let uid = "hardening-a3-promote-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: FilePaths.userRoot(uid: uid)) }
        let vid = UUID()

        // The field failure state: locally finalized, but the server still holds
        // the stale DRAFT (the live finalize push was silently lost), and the
        // binding is long-seeded so seeding will never re-push it.
        let db = ResultFakeDatabase()
        db.seedStored(serverRecord(id: vid, locked: false, payload: Data("stale-draft".utf8)))
        let reader = MutableReader()
        reader.snapshots = [LocalVersionSnapshot(meta: lockedMeta(vid), payload: Data("finalized-json".utf8))]
        let binds = FakeBindings()
        binds.save(preSeededBinding(uid: uid))
        let port = makePort(db: db, reader: reader, bindings: binds)

        await port.bind(firebaseUID: uid)
        await pumpFlush(port, until: { db.record(named: vid.uuidString)?.locked == true }, attempts: 200)

        let server = db.record(named: vid.uuidString)
        XCTAssertEqual(server?.locked, true,
                       "bind reconciliation pushes the locally-finalized version over the server draft — NOT gated on seededAt (A3)")
        XCTAssertEqual(server?.status, "Final", "the server record is promoted to Final")
    }

    func testBindReconciliationGuardSkipsAlreadyLockedServerRecord() async throws {
        let uid = "hardening-a3-skip-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: FilePaths.userRoot(uid: uid)) }
        let vid = UUID()

        let db = ResultFakeDatabase()
        let original = serverRecord(id: vid, locked: true, payload: Data("original-finalize".utf8))
        db.seedStored(original)
        let reader = MutableReader()
        reader.snapshots = [LocalVersionSnapshot(meta: lockedMeta(vid), payload: Data("divergent".utf8))]
        let binds = FakeBindings()
        binds.save(preSeededBinding(uid: uid))
        let port = makePort(db: db, reader: reader, bindings: binds)

        await port.bind(firebaseUID: uid)
        let settled = await waitUntil { port.status == .idle }

        XCTAssertTrue(settled, "the guard-skip is the save's SUCCESS path — the flush settles idle, got \(port.status)")
        XCTAssertEqual(db.savedCount, 0, "an already-locked server record is never mutated (A3 idempotence lives server-side)")
        XCTAssertEqual(db.record(named: vid.uuidString)?.payload, Data("original-finalize".utf8),
                       "the immutable server record is untouched")
        // The change DEQUEUED (guard-skip = success): the persisted outbox drained.
        let outboxData = try Data(contentsOf: CloudKitSyncPort.outboxURL(forUID: uid))
        let outbox = try JSONDecoder().decode([SyncChange].self, from: outboxData)
        XCTAssertTrue(outbox.isEmpty, "the reconcile enqueue dequeues via the guard's success path — outbox drained")
    }

    func testReconcileEnqueueSurvivesKillViaDurableOutbox() async throws {
        let uid = "hardening-a3-a2-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: FilePaths.userRoot(uid: uid)) }
        let vid = UUID()
        let binds = FakeBindings()
        binds.save(preSeededBinding(uid: uid))

        // Bind 1: reconciliation enqueues the finalized version, but every push
        // fails per-record — the mid-flush-kill analog: the change made it to the
        // outbox, not to the server.
        let db1 = ResultFakeDatabase()
        db1.saveMode = .perRecordFailure
        db1.seedStored(serverRecord(id: vid, locked: false, payload: Data("stale-draft".utf8)))
        let reader1 = MutableReader()
        reader1.snapshots = [LocalVersionSnapshot(meta: lockedMeta(vid), payload: Data("finalized-json".utf8))]
        let port1 = makePort(db: db1, reader: reader1, bindings: binds)
        await port1.bind(firebaseUID: uid)
        await pumpFlush(port1)
        XCTAssertEqual(db1.savedCount, 0, "the reconcile push failed — nothing on the server yet")
        // Force-quit analog: port1 is ABANDONED (no unbind). The outbox already
        // holds the reconcile enqueue.

        // Bind 2 in a fresh port whose reader has NO snapshots: reconciliation
        // finds nothing, so the ONLY possible source of the push is the restored
        // outbox (A2 x A3).
        let db2 = ResultFakeDatabase()
        db2.seedStored(serverRecord(id: vid, locked: false, payload: Data("stale-draft".utf8)))
        let reader2 = MutableReader()   // snapshots deliberately empty
        let port2 = makePort(db: db2, reader: reader2, bindings: binds)
        await port2.bind(firebaseUID: uid)
        await pumpFlush(port2, until: { db2.record(named: vid.uuidString)?.locked == true }, attempts: 200)

        XCTAssertEqual(db2.record(named: vid.uuidString)?.locked, true,
                       "the A3 reconcile enqueue survived the kill via the A2 outbox and healed the server draft")
    }

    // MARK: - A4: finalize() must not swallow the version-file write throw

    @MainActor
    func testFinalizeVersionWriteFailureSetsSaveErrorAndStaysDraft() async throws {
        let savedProvider = SessionScope.uidProvider
        let uid = "hardening-finalize-\(UUID().uuidString)"
        SessionScope.uidProvider = { uid }
        let root = FilePaths.userRoot(uid: uid)
        let fm = FileManager.default
        defer {
            SessionScope.uidProvider = savedProvider
            try? fm.removeItem(at: root)
        }

        // The version id differs from the inspection id, so the integrity snapshot
        // (written under Inspections/<inspectionId>/versions) succeeds while the
        // current.json write (under Inspections/<versionId>) is made to fail.
        let inspectionId = UUID()
        let versionId = UUID()
        let signatures = [
            InspectionSignature(name: "Inspector", date: Date()),
            InspectionSignature(name: "Client", date: Date())
        ]
        let inspection = Inspection(
            id: inspectionId, clientName: "C", propertyAddress: "1 Test Way",
            inspectionDate: Date(), inspectorName: "I", sections: [], signatures: signatures
        )
        let version = InspectionVersion(
            id: versionId, versionNumber: 1, status: .draft, finalizedAt: nil,
            locked: false, inspection: inspection
        )

        let store = InspectionStore()
        store.insert(version: version)
        XCTAssertTrue(fm.fileExists(atPath: FilePaths.currentVersionFile(jobId: versionId, inRoot: root).path))

        // Attach a sync seam AFTER the insert, so any change the finalize emitted
        // would be visible as a recorded change on the port.
        let recordingPort = RecordingPort()
        let recordingCoordinator = SyncCoordinator(isEnabled: { true }, account: StubAccount(token: "tok"), makeCloudPort: { recordingPort })
        recordingCoordinator.userDidChange(uid: uid)
        store.syncCoordinator = recordingCoordinator
        let emitted = recordingPort.changes

        // Make the version-file write fail: the inspection folder is read-only.
        let versionFolder = FilePaths.inspectionFolder(jobId: versionId, inRoot: root)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: versionFolder.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: versionFolder.path) }

        store.finalize(version: version)

        XCTAssertNotNil(store.saveError, "a failed version-file write must surface saveError (A4)")
        XCTAssertTrue(store.saveError?.contains("has not been finalized") == true,
                      "the message mirrors the integrity-snapshot abort style")

        // pendingFinalizedMetadata must be EMPTY: flushing must not promote the row.
        store.flushPendingMetadata()
        let row = store.metadataList.first(where: { $0.id == versionId })
        XCTAssertEqual(row?.status, .draft, "the metadata row stays a draft (A4)")
        XCTAssertEqual(row?.locked, false, "the metadata row is not locked (A4)")

        // No sync change was emitted for the failed finalize (the emit lives inside
        // writeVersionToFile, after the write).
        XCTAssertEqual(recordingPort.changes.count, emitted.count,
                       "a failed finalize must not emit a sync change (A4)")

        // And the on-disk current.json is still the draft.
        let data = try Data(contentsOf: FilePaths.currentVersionFile(jobId: versionId, inRoot: root))
        let onDisk = try JSONDecoder().decode(InspectionVersion.self, from: data)
        XCTAssertFalse(onDisk.locked, "current.json on disk is still the draft")
    }

    // MARK: - A6: live status mirroring in the coordinator

    @MainActor
    func testCoordinatorMirrorsFlushErrorAndRecoveryAcrossCycles() async {
        let port = StatusPort()
        port.flushFails = true
        let coordinator = SyncCoordinator(isEnabled: { true }, account: StubAccount(token: "tok"), makeCloudPort: { port })
        coordinator.userDidChange(uid: "u")
        // Let the bind task publish its (clean) status first.
        try? await Task.sleep(nanoseconds: 50_000_000)

        await coordinator.pullAndRefresh()
        guard case .error = coordinator.status else {
            return XCTFail("a failing flush must flip the PUBLISHED status to .error (A6), got \(coordinator.status)")
        }

        port.flushFails = false
        await coordinator.pullAndRefresh()
        XCTAssertEqual(coordinator.status, .idle, "a subsequent clean cycle flips the published status back (A6)")
    }

    // MARK: - A8: asset writer parity with the version writer

    func testApplyRemoteAssetCrossAccountMismatchHoldsToken() async {
        let savedProvider = SessionScope.uidProvider
        defer { SessionScope.uidProvider = savedProvider }
        SessionScope.uidProvider = { "live-user-B" }

        let writer = InspectionStoreVersionWriter(store: nil, boundUID: "bound-user-A")
        let jobId = UUID()
        let rel = "Inspections/\(jobId.uuidString)/thumbnails/t.jpg"
        let record = SyncAssetRecord(
            recordName: CloudKitSchema.assetRecordName(jobId: jobId, relativePath: rel),
            jobId: jobId, relativePath: rel, kind: .thumbnail,
            modifiedAt: Date(), schemaVersion: CloudKitSchema.schemaVersion, payload: Data("x".utf8)
        )

        let applied = await writer.applyRemoteAsset(record)
        XCTAssertFalse(applied, "a cross-account mismatch must HOLD the token (return false), matching applyRemoteVersion (A8)")

        let deleted = await writer.deleteLocalAsset(jobId: jobId, relativePath: rel)
        XCTAssertFalse(deleted, "a cross-account delete mismatch must HOLD the token (return false) (A8)")
    }

    func testDeleteLocalAssetRemovalFailureHoldsTokenAndAbsenceIsIdempotent() async throws {
        let savedProvider = SessionScope.uidProvider
        let uid = "hardening-del-\(UUID().uuidString)"
        SessionScope.uidProvider = { uid }
        let root = FilePaths.userRoot(uid: uid)
        let fm = FileManager.default
        let jobId = UUID()
        let rel = "Inspections/\(jobId.uuidString)/thumbnails/locked.jpg"
        let fileURL = root.appendingPathComponent(rel)
        let dir = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: fileURL)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            SessionScope.uidProvider = savedProvider
            try? fm.removeItem(at: root)
        }

        let writer = InspectionStoreVersionWriter(store: nil, boundUID: uid)

        let held = await writer.deleteLocalAsset(jobId: jobId, relativePath: rel)
        XCTAssertFalse(held, "a real removal failure must HOLD the token so the next pull retries (A8)")
        XCTAssertTrue(fm.fileExists(atPath: fileURL.path), "the file is still on disk after the failed removal")

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        let removed = await writer.deleteLocalAsset(jobId: jobId, relativePath: rel)
        XCTAssertTrue(removed, "removal succeeds once the directory is writable")
        XCTAssertFalse(fm.fileExists(atPath: fileURL.path))

        let alreadyAbsent = await writer.deleteLocalAsset(jobId: jobId, relativePath: rel)
        XCTAssertTrue(alreadyAbsent, "deleting an already-absent asset is idempotent success")
    }
}

/// SyncPort that records forwarded changes (for the A4 "no sync change emitted"
/// assertion).
private final class RecordingPort: SyncPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _changes: [SyncChange] = []
    var changes: [SyncChange] { lock.withLock { _changes } }
    var status: SyncStatus = .idle
    func bind(firebaseUID: String) async {}
    func unbind() {}
    func recordLocalChange(_ change: SyncChange) { lock.withLock { _changes.append(change) } }
    func seedIfNeeded(firebaseUID: String) async {}
    func pull() async {}
    func flushPending() async {}
}
