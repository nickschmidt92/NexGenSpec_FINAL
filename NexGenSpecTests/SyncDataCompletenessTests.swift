//
//  SyncDataCompletenessTests.swift
//  NexGenSpecTests
//
//  Sync data completeness pass — the product gaps that make "all data transfers
//  between iPad/Mac/iPhone" true:
//    1. Invoice + archived side state syncs (InspectionSideStateStore riding the
//       MediaAsset machinery as SyncAssetKind.sideState), with a one-time legacy
//       UserDefaults hoist and LWW arbitration.
//    2. Cover photos sync (allowlist + emit + receiver placeholder).
//    3. Signature PNGs sync (allowlist + emit on SignatureStore.saveImage).
//    4. Finalize auto-publishes the report PDF (hook fires exactly once per
//       SUCCESSFUL finalize, never on an aborted one).
//  Plus the MANDATORY constraint-(a) guard: a finalized payload's integrity hash
//  is BYTE-STABLE across decode→re-encode, proving this branch introduced no
//  payload-perturbing model change (the sealed record stays verifiable).
//

import XCTest
@testable import NexGenSpec

// MARK: - Fakes (local to this file; the other sync test files' fakes are private)

private final class SDCFakeDatabase: CloudDatabase, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var savedAssets: [(record: SyncAssetRecord, zone: String)] = []
    private(set) var clearedAssetKeys: [String] = []
    func ensureZone(_ zoneName: String) async throws {}
    func save(_ record: InspectionVersionRecord, inZone zoneName: String) async throws {}
    func delete(recordName: String, inZone zoneName: String) async throws {}
    func deleteZone(_ zoneName: String) async throws {}
    func recordTombstone(versionId: String, inZone zoneName: String) async throws {}
    func tombstonedIds(inZone zoneName: String) async throws -> Set<String> { [] }
    func saveAsset(_ record: SyncAssetRecord, inZone zoneName: String) async throws {
        lock.withLock { savedAssets.append((record, zoneName)) }
    }
    func recordAssetTombstone(key: String, inZone zoneName: String) async throws {}
    func clearAssetTombstone(key: String, inZone zoneName: String) async throws {
        lock.withLock { clearedAssetKeys.append(key) }
    }
    func tombstonedAssetKeys(inZone zoneName: String) async throws -> Set<String> { [] }
    var savedAssetSnapshot: [(record: SyncAssetRecord, zone: String)] { lock.withLock { savedAssets } }
}

private struct SDCFakeAccount: CloudAccountProviding {
    let token: String?
    func currentUserToken() async -> String? { token }
}

private struct SDCStubReader: LocalVersionReader, @unchecked Sendable {
    func versionData(forVersionId id: UUID) -> Data? { nil }
    func allLocalVersions() -> [LocalVersionSnapshot] { [] }
    func localState(forVersionId id: UUID) -> LocalVersionState { .absent }
}

private struct SDCFakeFetcher: CloudZoneFetcher {
    var changes: ZoneChanges
    func fetchChanges(inZone zoneName: String, since token: Data?) async throws -> ZoneChanges { changes }
}

private final class SDCFakeBindings: BindingStoring, @unchecked Sendable {
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

/// Captures changes forwarded through a SyncCoordinator (the emit-path tests).
private final class SDCFakePort: SyncPort, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var changes: [SyncChange] = []
    var status: SyncStatus = .idle
    func bind(firebaseUID: String) async {}
    func unbind() {}
    func recordLocalChange(_ change: SyncChange) { lock.withLock { changes.append(change) } }
    func seedIfNeeded(firebaseUID: String) async {}
    func pull() async {}
    func flushPending() async {}
    var recorded: [SyncChange] { lock.withLock { changes } }
}

// MARK: - Tests

@MainActor
final class SyncDataCompletenessTests: XCTestCase {

    private var savedUIDProvider: (() -> String?)!
    private var rootsToRemove: [URL] = []
    private var defaultsKeysToRemove: [String] = []

    override func setUp() {
        super.setUp()
        savedUIDProvider = SessionScope.uidProvider
    }

    override func tearDown() {
        SessionScope.uidProvider = savedUIDProvider
        for url in rootsToRemove { try? FileManager.default.removeItem(at: url) }
        rootsToRemove = []
        for key in defaultsKeysToRemove { UserDefaults.standard.removeObject(forKey: key) }
        defaultsKeysToRemove = []
        super.tearDown()
    }

    /// Scopes the live per-UID store to a unique throwaway segment and schedules
    /// its cleanup, so tests never touch real data and never collide.
    private func useUID(_ uid: String) {
        SessionScope.uidProvider = { uid }
        rootsToRemove.append(FilePaths.userRoot(uid: uid))
    }

    private func makeVersion(id: UUID = UUID(), signatures: Int = 0, locked: Bool = false) -> InspectionVersion {
        var inspection = Inspection(
            id: id,
            clientName: "Client",
            clientEmail: "c@example.com",
            clientPhone: "555-0100",
            propertyAddress: "1 Test Way",
            inspectionDate: Date(timeIntervalSince1970: 1_700_000_000),
            inspectorName: "Inspector",
            sections: []
        )
        inspection.signatures = (0..<signatures).map { i in
            InspectionSignature(
                name: i == 0 ? "Inspector" : "Client",
                imageFileName: "\(UUID().uuidString).png",
                date: Date(timeIntervalSince1970: 1_700_000_100)
            )
        }
        return InspectionVersion(
            id: id, versionNumber: 1,
            status: locked ? .final : .draft,
            finalizedAt: locked ? Date(timeIntervalSince1970: 1_700_000_200) : nil,
            locked: locked,
            inspection: inspection,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_050)
        )
    }

    // MARK: - Allowlist (Items 1/2/3)

    func testAllowlistClassifiesCoverSignatureAndSideState() {
        let id = UUID().uuidString
        XCTAssertEqual(SyncAssetPaths.kind(forRelativePath: "Inspections/\(id)/cover.jpg"), .coverPhoto)
        XCTAssertEqual(SyncAssetPaths.kind(forRelativePath: "Inspections/\(id)/sidestate.json"), .sideState)
        XCTAssertEqual(SyncAssetPaths.kind(forRelativePath: "Inspections/\(id)/signatures/\(UUID().uuidString).png"), .signature)

        // Exclusions hold: only the FIXED names at the folder root classify, the
        // photo/video/USDZ/whole-home exclusions are untouched, and traversal is
        // still rejected.
        XCTAssertNil(SyncAssetPaths.kind(forRelativePath: "Inspections/\(id)/other.jpg"))
        XCTAssertNil(SyncAssetPaths.kind(forRelativePath: "Inspections/\(id)/photos/cover.jpg"))
        XCTAssertNil(SyncAssetPaths.kind(forRelativePath: "Inspections/\(id)/photos/\(UUID().uuidString).jpg"))
        XCTAssertNil(SyncAssetPaths.kind(forRelativePath: "Inspections/\(id)/signatures/\(UUID().uuidString).jpg"))
        XCTAssertNil(SyncAssetPaths.kind(forRelativePath: "Inspections/\(id)/lidar/whole_home_x.png"))
        XCTAssertNil(SyncAssetPaths.kind(forRelativePath: "Inspections/\(id)/../\(id)/cover.jpg"))
        XCTAssertNil(SyncAssetPaths.kind(forRelativePath: "cover.jpg"))

        // Both new kinds ride the MediaAsset record type (no NEW record type
        // beyond the already-planned Dev→Prod deploy).
        for kind: SyncAssetKind in [.coverPhoto, .signature, .sideState] {
            XCTAssertEqual(CloudKitSchema.recordType(forAssetKind: kind.rawValue), CloudKitSchema.RecordType.mediaAsset)
        }
    }

    // MARK: - Constraint (a): sealed payload byte-stability (MANDATORY)

    /// A finalized version's integrity hash is computed over the canonical
    /// (sorted-keys) encoding of the MODEL, and a receiving device recomputes it
    /// from the decoded payload. This branch must therefore not perturb the
    /// encoded bytes of pre-existing records: decoding a finalized payload and
    /// re-encoding it must yield a BYTE-IDENTICAL canonical encoding (and hence
    /// the identical sealed hash). Guards constraint (a) — the side-state design
    /// deliberately adds NO field to InspectionVersion, and this locks that in.
    func testFinalizedPayloadIntegrityHashIsByteStableAcrossDecodeReencode() throws {
        let version = makeVersion(signatures: 2, locked: true)

        // The hash sealed at finalization (canonical sorted-keys encoding).
        let sealedHash = try FinalizationService.canonicalHash(version)

        // Simulate the on-disk current.json bytes (writeVersionToFile uses a
        // plain JSONEncoder — non-canonical key order) and a receiver's decode.
        let fileBytes = try JSONEncoder().encode(version)
        let decoded = try JSONDecoder().decode(InspectionVersion.self, from: fileBytes)
        XCTAssertEqual(try FinalizationService.canonicalHash(decoded), sealedHash,
                       "decode→re-encode must reproduce the sealed hash byte-for-byte (constraint a)")

        // Determinism of the canonical encoder itself: same model → same bytes,
        // and canonical bytes survive a decode→re-encode round trip unchanged.
        let canonical = JSONEncoder()
        canonical.outputFormatting = [.sortedKeys]
        let bytes1 = try canonical.encode(version)
        let bytes2 = try canonical.encode(version)
        XCTAssertEqual(bytes1, bytes2, "canonical encoding must be deterministic")
        let decodedFromCanonical = try JSONDecoder().decode(InspectionVersion.self, from: bytes1)
        XCTAssertEqual(try canonical.encode(decodedFromCanonical), bytes1,
                       "canonical bytes must round-trip decode→re-encode byte-identically")

        // And the verification path agrees end-to-end.
        XCTAssertEqual(decoded, version, "the decoded model must equal the sealed model")
    }

    // MARK: - Item 1: side-state round trip (push → pull → apply) + LWW

    func testSideStateRoundTripPushPullApplyAcrossDevices() async throws {
        let uidA = "sdc-A-\(UUID().uuidString)"
        let uidB = "sdc-B-\(UUID().uuidString)"
        rootsToRemove.append(FilePaths.userRoot(uid: uidB))
        useUID(uidA)

        // DEVICE A: a local edit writes the side file (sent + amounts).
        let inspectionId = UUID()
        let sentAt = Date(timeIntervalSince1970: 1_700_100_000)
        let store = InspectionSideStateStore.shared
        store.setInvoiceFields(price: "450", services: "Radon add-on", total: "575", inspectionId: inspectionId.uuidString)
        store.setInvoiceSent(at: sentAt, inspectionId: inspectionId.uuidString)
        let rel = InspectionSideStateStore.relativePath(inspectionId: inspectionId.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: FilePaths.userRoot(uid: uidA).appendingPathComponent(rel).path),
                      "the side file is written under A's per-UID root")

        // PUSH through the real port: the change lands as ONE MediaAsset record
        // of kind .sideState whose payload is the file's bytes.
        let db = SDCFakeDatabase()
        let portA = CloudKitSyncPort(
            account: SDCFakeAccount(token: "tokA"), database: db, reader: SDCStubReader(),
            bindings: SDCFakeBindings(), fetcher: NoopZoneFetcher(), writer: NoopLocalVersionWriter()
        )
        await portA.bind(firebaseUID: uidA)
        portA.recordLocalChange(.mediaUpserted(jobId: inspectionId, relativePath: rel))
        // recordLocalChange spawns its own flush Task; pump until the push lands
        // (mirrors CloudKitSyncPortTests' finalize-promotion pump).
        for _ in 0..<200 where db.savedAssetSnapshot.isEmpty {
            await portA.flushPending()
            await Task.yield()
        }

        let pushed = db.savedAssetSnapshot
        XCTAssertEqual(pushed.count, 1, "exactly one side-state record is pushed")
        let record = try XCTUnwrap(pushed.first?.record)
        XCTAssertEqual(record.kind, .sideState)
        XCTAssertEqual(record.recordName, CloudKitSchema.assetRecordName(jobId: inspectionId, relativePath: rel))
        let pushedState = try JSONDecoder().decode(InspectionSideState.self, from: record.payload)
        XCTAssertEqual(pushedState.invoicePrice, "450")
        XCTAssertEqual(pushedState.invoiceTotal, "575")
        XCTAssertEqual(pushedState.invoiceSentAt?.timeIntervalSince1970 ?? 0, sentAt.timeIntervalSince1970, accuracy: 0.001)

        // DEVICE B: pull the record (server LWW clock = now) and apply through
        // the REAL writer pinned to B's root.
        SessionScope.uidProvider = { uidB }
        let remote = SyncAssetRecord(
            recordName: record.recordName, jobId: inspectionId, relativePath: rel,
            kind: .sideState, modifiedAt: Date(), schemaVersion: record.schemaVersion, payload: record.payload
        )
        let changes = ZoneChanges(changed: [], changedAssets: [remote], deletedRecordNames: [], newToken: Data("tok".utf8))
        let portB = CloudKitSyncPort(
            account: SDCFakeAccount(token: "tokB"), database: SDCFakeDatabase(), reader: SDCStubReader(),
            bindings: SDCFakeBindings(), fetcher: SDCFakeFetcher(changes: changes),
            writer: InspectionStoreVersionWriter(store: nil, boundUID: uidB)
        )
        await portB.bind(firebaseUID: uidB)

        XCTAssertTrue(FileManager.default.fileExists(atPath: FilePaths.userRoot(uid: uidB).appendingPathComponent(rel).path),
                      "the pulled side file lands under B's per-UID root")

        // B's store + badge derivation see A's state (cache invalidated by the
        // writer's noteRemoteChange).
        let stateOnB = InspectionSideStateStore.shared.state(for: inspectionId.uuidString)
        XCTAssertEqual(stateOnB?.invoicePrice, "450")
        XCTAssertEqual(stateOnB?.invoiceSentAt?.timeIntervalSince1970 ?? 0, sentAt.timeIntervalSince1970, accuracy: 0.001)
        let meta = VersionMetadata(
            id: UUID(), inspectionId: inspectionId, versionNumber: 1, status: .final,
            finalizedAt: Date(), locked: true, clientName: "Client", propertyAddress: "1 Test Way", inspectionDate: Date()
        )
        XCTAssertEqual(meta.badge, .invoiced, "the synced side state drives the badge on the receiving device")
    }

    func testSideStateReceiverLWWKeepsNewerLocalAndAppliesNewerRemote() async throws {
        let uid = "sdc-lww-\(UUID().uuidString)"
        useUID(uid)

        let inspectionId = UUID()
        let rel = InspectionSideStateStore.relativePath(inspectionId: inspectionId.uuidString)
        let localURL = FilePaths.userRoot(uid: uid).appendingPathComponent(rel)

        // Local state written NOW (fresh mtime).
        InspectionSideStateStore.shared.setInvoicePaid(at: Date(timeIntervalSince1970: 1_700_200_000), inspectionId: inspectionId.uuidString)
        let localBytes = try Data(contentsOf: localURL)

        var remoteState = InspectionSideState(inspectionId: inspectionId.uuidString)
        remoteState.archivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let remoteBytes = try JSONEncoder().encode(remoteState)
        let writer = InspectionStoreVersionWriter(store: nil, boundUID: uid)

        // OLDER remote (server clock an hour ago) → the newer local file wins.
        let older = SyncAssetRecord(
            recordName: CloudKitSchema.assetRecordName(jobId: inspectionId, relativePath: rel),
            jobId: inspectionId, relativePath: rel, kind: .sideState,
            modifiedAt: Date(timeIntervalSinceNow: -3600), schemaVersion: CloudKitSchema.schemaVersion, payload: remoteBytes
        )
        let keptLocal = await writer.applyRemoteAsset(older)
        XCTAssertTrue(keptLocal, "keep-local is a settled success (token advances)")
        XCTAssertEqual(try Data(contentsOf: localURL), localBytes, "an older remote must NOT clobber a newer local side file (LWW)")

        // NEWER remote (server clock in the future) → applies.
        let newer = SyncAssetRecord(
            recordName: older.recordName, jobId: inspectionId, relativePath: rel, kind: .sideState,
            modifiedAt: Date(timeIntervalSinceNow: 3600), schemaVersion: CloudKitSchema.schemaVersion, payload: remoteBytes
        )
        let applied = await writer.applyRemoteAsset(newer)
        XCTAssertTrue(applied)
        XCTAssertEqual(try Data(contentsOf: localURL), remoteBytes, "a newer remote side file replaces the local copy (LWW)")
        XCTAssertTrue(InspectionSideStateStore.shared.isArchived(inspectionId: inspectionId.uuidString),
                      "the store re-reads the applied remote state (cache invalidated)")
    }

    // MARK: - Item 1: legacy UserDefaults hoist

    func testLegacyUserDefaultsValuesHoistIntoSyncedStoreOnce() throws {
        let uid = "sdc-hoist-\(UUID().uuidString)"
        useUID(uid)

        let inspectionId = UUID()
        let id = inspectionId.uuidString
        let sentAt = Date(timeIntervalSince1970: 1_700_300_000)
        let defaults = UserDefaults.standard
        let sentKey = InspectionFlags.scopedKey("invoice.sentAt.\(id)")
        let priceKey = InspectionFlags.scopedKey("invoice.price.\(id)")
        let archivedKey = InspectionFlags.scopedKey("inspection.archivedAt.\(id)")
        defaultsKeysToRemove += [sentKey, priceKey, archivedKey]
        defaults.set(sentAt, forKey: sentKey)
        defaults.set("325", forKey: priceKey)
        defaults.set(Date(timeIntervalSince1970: 1_700_300_100), forKey: archivedKey)

        // First read hoists the legacy values into the synced file.
        let state = InspectionSideStateStore.shared.state(for: id)
        XCTAssertEqual(state?.invoicePrice, "325")
        XCTAssertEqual(state?.invoiceSentAt?.timeIntervalSince1970 ?? 0, sentAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNotNil(state?.archivedAt)
        XCTAssertTrue(InspectionSideStateStore.shared.isArchived(inspectionId: id))
        let fileURL = FilePaths.userRoot(uid: uid)
            .appendingPathComponent(InspectionSideStateStore.relativePath(inspectionId: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "the hoist persists a synced side file")

        // The file is now authoritative: a later UserDefaults change is IGNORED
        // (legacy is read-only fallback, consulted only when no file exists).
        defaults.set("999", forKey: priceKey)
        InspectionSideStateStore.shared.noteRemoteChange(inspectionId: id)   // drop the cache → re-read from disk
        XCTAssertEqual(InspectionSideStateStore.shared.state(for: id)?.invoicePrice, "325",
                       "after the hoist, the synced file wins over legacy UserDefaults")
    }

    // MARK: - Items 2/3: emit paths (cover + signature)

    func testSignatureSaveEmitsMediaUpsertedWithCanonicalPath() async {
        let uid = "sdc-sig-\(UUID().uuidString)"
        useUID(uid)

        let fake = SDCFakePort()
        let coord = SyncCoordinator(isEnabled: { true }, account: SDCFakeAccount(token: "tok"), makeCloudPort: { fake })
        coord.userDidChange(uid: uid)
        SyncCoordinator.active = coord
        defer { SyncCoordinator.active = nil }

        let jobId = UUID(), sigId = UUID()
        XCTAssertTrue(SignatureStore.saveImage(Data([0x89, 0x50, 0x4E, 0x47]), jobId: jobId, signatureId: sigId))

        // noteMediaUpserted hops through a MainActor Task — let it land.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let expected = SyncChange.mediaUpserted(
            jobId: jobId,
            relativePath: "Inspections/\(jobId.uuidString)/signatures/\(sigId.uuidString).png"
        )
        XCTAssertTrue(fake.recorded.contains(expected), "a durable signature write emits the sync change")
        // The emitted path is allowlisted, so the port will actually push it.
        XCTAssertEqual(SyncAssetPaths.kind(forRelativePath: SignatureStore.relativePath(jobId: jobId, signatureId: sigId)), .signature)
    }

    func testCoverPhotoEmitPathsForWriteAndRemove() async {
        let fake = SDCFakePort()
        let coord = SyncCoordinator(isEnabled: { true }, account: SDCFakeAccount(token: "tok"), makeCloudPort: { fake })
        coord.userDidChange(uid: "sdc-cover")
        SyncCoordinator.active = coord
        defer { SyncCoordinator.active = nil }

        let jobId = UUID()
        CoverPhotoSync.noteCoverWritten(jobId: jobId, fileName: FilePaths.defaultCoverPhotoFileName)
        CoverPhotoSync.noteCoverRemoved(jobId: jobId, fileName: FilePaths.defaultCoverPhotoFileName)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let rel = "Inspections/\(jobId.uuidString)/cover.jpg"
        XCTAssertTrue(fake.recorded.contains(.mediaUpserted(jobId: jobId, relativePath: rel)),
                      "writing a cover emits the upsert")
        XCTAssertTrue(fake.recorded.contains(.mediaDeleted(jobId: jobId, relativePath: rel)),
                      "removing a cover emits the delete (tombstone on other devices)")
        XCTAssertEqual(SyncAssetPaths.kind(forRelativePath: rel), .coverPhoto, "the emitted path is allowlisted")
    }

    // MARK: - Item 4: finalize auto-publish hook

    func testFinalizeAutoPublishHookFiresExactlyOnceOnSuccess() {
        let uid = "sdc-fin-\(UUID().uuidString)"
        useUID(uid)
        let savedToggle = InspectionStore.autoPublishReportPDFOnFinalize
        InspectionStore.autoPublishReportPDFOnFinalize = true
        defer { InspectionStore.autoPublishReportPDFOnFinalize = savedToggle }

        let store = InspectionStore()
        let version = makeVersion(signatures: 2)
        store.insert(version: version)

        var fired: [InspectionVersion] = []
        store.finalizeAutoPublishHook = { fired.append($0) }

        store.finalize(version: version)
        XCTAssertNil(store.saveError, "the finalize itself succeeds")
        XCTAssertEqual(fired.count, 1, "the auto-publish hook fires exactly once per successful finalize")
        XCTAssertEqual(fired.first?.id, version.id)
        XCTAssertEqual(fired.first?.locked, true, "the hook receives the FINALIZED (locked) version")

        // Finalizing the (now locked) version again is refused by the state
        // machine — the hook must NOT fire a second time.
        if let locked = store.loadFullVersion(id: version.id) {
            store.finalize(version: locked)
        }
        XCTAssertEqual(fired.count, 1, "an already-finalized version never re-fires the hook")
    }

    func testFinalizeAutoPublishHookNeverFiresOnAbortedFinalize() {
        let uid = "sdc-abort-\(UUID().uuidString)"
        useUID(uid)
        let savedToggle = InspectionStore.autoPublishReportPDFOnFinalize
        InspectionStore.autoPublishReportPDFOnFinalize = true
        defer { InspectionStore.autoPublishReportPDFOnFinalize = savedToggle }

        let store = InspectionStore()
        var fired = 0
        store.finalizeAutoPublishHook = { _ in fired += 1 }

        // Abort 1: missing signatures → the state machine refuses the transition.
        let unsigned = makeVersion(signatures: 0)
        store.insert(version: unsigned)
        store.finalize(version: unsigned)
        XCTAssertEqual(fired, 0, "an aborted finalize (missing signatures) must not auto-publish")
        XCTAssertEqual(store.loadFullVersion(id: unsigned.id)?.locked, false, "the version stays a draft")

        // Abort 2: unknown version (not in the index) → early return.
        store.finalize(version: makeVersion(signatures: 2))
        XCTAssertEqual(fired, 0, "a finalize that never ran must not auto-publish")

        // And the product toggle wins: flag off ⇒ no hook even on success.
        InspectionStore.autoPublishReportPDFOnFinalize = false
        let signed = makeVersion(signatures: 2)
        store.insert(version: signed)
        store.finalize(version: signed)
        XCTAssertEqual(store.loadFullVersion(id: signed.id)?.locked, true, "the finalize itself still succeeds")
        XCTAssertEqual(fired, 0, "toggle OFF disables the auto-publish cleanly")
    }

    // MARK: - Badge derivation from the synced store

    func testBadgesAndArchivedDeriveFromSyncedSideState() {
        let uid = "sdc-badge-\(UUID().uuidString)"
        useUID(uid)

        let inspectionId = UUID()
        let meta = VersionMetadata(
            id: UUID(), inspectionId: inspectionId, versionNumber: 1, status: .final,
            finalizedAt: Date(), locked: true, clientName: "C", propertyAddress: "A", inspectionDate: Date()
        )
        XCTAssertEqual(meta.badge, .finalized)
        XCTAssertFalse(meta.isArchived)

        let store = InspectionSideStateStore.shared
        store.setInvoiceSent(at: Date(), inspectionId: inspectionId.uuidString)
        XCTAssertEqual(meta.badge, .invoiced)
        store.setInvoicePaid(at: Date(), inspectionId: inspectionId.uuidString)
        XCTAssertEqual(meta.badge, .paid)
        store.setArchived(true, inspectionId: inspectionId.uuidString)
        XCTAssertTrue(meta.isArchived)
        store.setArchived(false, inspectionId: inspectionId.uuidString)
        XCTAssertFalse(meta.isArchived)
    }
}
