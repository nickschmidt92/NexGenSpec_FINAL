//
//  SyncIdentityTests.swift
//  NexGenSpecTests
//
//  Slice 2 (build 22) — the identity-contract core (landmine 1) and CloudKit
//  schema/mapper. Exercises the full edge matrix from
//  docs/design/build-22-cloudkit-sync.md §2.3: no iCloud, first bind, resume,
//  refuse-and-isolate on Apple-ID change, and two app accounts on one iCloud
//  getting isolated zones. These are the assertions P6 will adversarially verify.
//

import XCTest
@testable import NexGenSpec

final class SyncIdentityTests: XCTestCase {

    private func binding(uid: String, token: String, zone: String) -> SyncBinding {
        SyncBinding(firebaseUID: uid, cloudUserToken: token, zoneName: zone, boundAt: Date())
    }

    // MARK: - SyncIdentityResolver (edge matrix)

    func testNoICloudAccountResolvesToNoAccount() {
        // Edge D: no iCloud → run local-only, never bind.
        let d = SyncIdentityResolver.resolve(firebaseUID: "uidA", cloudToken: nil, existing: nil)
        XCTAssertEqual(d, .noAccount)
    }

    func testFirstBindCreatesPerUIDZone() {
        // Edge A first-run: no binding yet → bindNew with this UID's zone.
        let d = SyncIdentityResolver.resolve(firebaseUID: "uidA", cloudToken: "tokICloud1", existing: nil)
        XCTAssertEqual(d, .bindNew(zoneName: CloudKitSchema.zoneName(forFirebaseUID: "uidA")))
    }

    func testMatchingBindingResumes() {
        // Edges A steady / E re-login: same iCloud user → resume.
        let b = binding(uid: "uidA", token: "tokICloud1", zone: CloudKitSchema.zoneName(forFirebaseUID: "uidA"))
        let d = SyncIdentityResolver.resolve(firebaseUID: "uidA", cloudToken: "tokICloud1", existing: b)
        XCTAssertEqual(d, .resume(b))
    }

    func testAppleIDChangeUnderUIDRefusesAndIsolates() {
        // Edges B / F: bound to iCloud user 1, now device shows iCloud user 2 →
        // REFUSE. Must never cross data between the two accounts.
        let b = binding(uid: "uidA", token: "tokICloud1", zone: CloudKitSchema.zoneName(forFirebaseUID: "uidA"))
        let d = SyncIdentityResolver.resolve(firebaseUID: "uidA", cloudToken: "tokICloud2", existing: b)
        switch d {
        case .refuseAndIsolate:
            break // correct — fail closed
        default:
            XCTFail("Apple-ID change under a UID must refuse-and-isolate, got \(d)")
        }
    }

    func testTwoAppAccountsOnOneICloudGetDistinctZones() {
        // Edge C: same iCloud user token, two different Firebase UIDs. Each UID
        // binds its OWN zone; neither refuses; zones differ → no cross-contamination.
        let token = "tokSharedICloud"
        let dA = SyncIdentityResolver.resolve(firebaseUID: "uidA", cloudToken: token, existing: nil)
        let dB = SyncIdentityResolver.resolve(firebaseUID: "uidB", cloudToken: token, existing: nil)
        guard case let .bindNew(zoneA) = dA, case let .bindNew(zoneB) = dB else {
            return XCTFail("Both UIDs should bindNew; got \(dA), \(dB)")
        }
        XCTAssertNotEqual(zoneA, zoneB, "Per-UID zones must differ even on one iCloud account.")
    }

    func testBindingForDifferentUIDIsTreatedAsUnbound() {
        // Defensive: a stale binding row for another UID never resumes; this UID
        // binds its own zone.
        let b = binding(uid: "OTHER", token: "tok", zone: "zOther")
        let d = SyncIdentityResolver.resolve(firebaseUID: "uidA", cloudToken: "tok", existing: b)
        XCTAssertEqual(d, .bindNew(zoneName: CloudKitSchema.zoneName(forFirebaseUID: "uidA")))
    }

    // MARK: - Schema / token

    func testZoneNameIsDeterministicDistinctAndPrefixed() {
        XCTAssertEqual(CloudKitSchema.zoneName(forFirebaseUID: "uidA"),
                       CloudKitSchema.zoneName(forFirebaseUID: "uidA"), "Deterministic.")
        XCTAssertNotEqual(CloudKitSchema.zoneName(forFirebaseUID: "uidA"),
                          CloudKitSchema.zoneName(forFirebaseUID: "uidB"), "Distinct per UID.")
        XCTAssertTrue(CloudKitSchema.zoneName(forFirebaseUID: "uidA").hasPrefix("ngs-"))
        XCTAssertFalse(CloudKitSchema.zoneName(forFirebaseUID: "uidA").contains("uidA"),
                       "Raw UID must not appear in the zone name.")
    }

    func testCloudTokenIsDeterministicAndUserDistinct() {
        XCTAssertEqual(CloudIdentity.token(forUserRecordName: "_abc"),
                       CloudIdentity.token(forUserRecordName: "_abc"))
        XCTAssertNotEqual(CloudIdentity.token(forUserRecordName: "_abc"),
                          CloudIdentity.token(forUserRecordName: "_def"))
        XCTAssertFalse(CloudIdentity.token(forUserRecordName: "_abc").contains("_abc"),
                       "Token must not expose the raw record name.")
    }

    // MARK: - Record mapper (PII minimization + immutability flag)

    func testMapperProjectsMetadataAndKeepsPIIInPayload() {
        let versionId = UUID()
        let inspectionId = UUID()
        let meta = VersionMetadata(
            id: versionId,
            inspectionId: inspectionId,
            versionNumber: 3,
            status: .final,
            finalizedAt: Date(timeIntervalSince1970: 1_700_000_000),
            locked: true,
            clientName: "Jane Homeowner",
            propertyAddress: "123 Private Way",
            inspectionDate: Date(),
            coverPhotoFileName: "cover.jpg"
        )
        let payload = Data("full-inspection-json".utf8)
        let rec = InspectionRecordMapper.make(meta: meta, payload: payload)

        XCTAssertEqual(rec.recordName, versionId.uuidString)
        XCTAssertEqual(rec.inspectionId, inspectionId.uuidString)
        XCTAssertEqual(rec.versionNumber, 3)
        XCTAssertEqual(rec.status, meta.status.rawValue)
        XCTAssertTrue(rec.locked, "Finalized version must carry locked=true (immutability).")
        XCTAssertEqual(rec.schemaVersion, CloudKitSchema.schemaVersion)
        XCTAssertEqual(rec.payload, payload)
        // PII (client name / address) must NOT leak into any queryable field —
        // it only exists inside the opaque payload.
        let mirror = Mirror(reflecting: rec)
        for child in mirror.children where child.label != "payload" {
            if let s = child.value as? String {
                XCTAssertFalse(s.contains("Jane"), "Client name leaked into field \(child.label ?? "?").")
                XCTAssertFalse(s.contains("Private Way"), "Address leaked into field \(child.label ?? "?").")
            }
        }
    }
}
