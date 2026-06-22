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
    var failEnsureZone = false

    func ensureZone(_ zoneName: String) async throws {
        if failEnsureZone { throw NSError(domain: "test", code: 1) }
        lock.withLock { ensuredZones.append(zoneName) }
    }
    func save(_ record: InspectionVersionRecord, inZone zoneName: String) async throws {
        lock.withLock { saved.append((record, zoneName)) }
    }
    func delete(recordName: String, inZone zoneName: String) async throws {
        lock.withLock { deleted.append((recordName, zoneName)) }
    }
}

private struct FakeAccount: CloudAccountProviding {
    let token: String?
    func currentUserToken() async -> String? { token }
}

private struct FakeReader: LocalVersionReader {
    let data: Data?
    func versionData(forVersionId id: UUID) -> Data? { data }
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

// MARK: - Tests

final class CloudKitSyncPortTests: XCTestCase {

    private func meta(_ id: UUID = UUID()) -> VersionMetadata {
        VersionMetadata(
            id: id, inspectionId: UUID(), versionNumber: 1, status: .draft,
            finalizedAt: nil, locked: false, clientName: "Client",
            propertyAddress: "Addr", inspectionDate: Date()
        )
    }

    private func makePort(token: String?, bindings: FakeBindings, db: FakeDatabase, reader: FakeReader = FakeReader(data: Data("payload".utf8))) -> CloudKitSyncPort {
        CloudKitSyncPort(account: FakeAccount(token: token), database: db, reader: reader, bindings: bindings)
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
}
