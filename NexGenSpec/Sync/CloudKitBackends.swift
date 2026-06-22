//
//  CloudKitBackends.swift
//  NexGenSpec
//
//  The concrete CloudKit implementations of the sync seams (build 22, slice 2c).
//  This is the ONLY sync file that imports CloudKit. They are exercised on real
//  devices/iCloud (not unit tests); the testable orchestration lives in
//  CloudKitSyncPort + SyncIdentityResolver. PUSH-ONLY for now. Private database,
//  per-UID custom zone. See docs/design/build-22-cloudkit-sync.md §3, §4.
//

import Foundation
import CloudKit

/// Resolves the current iCloud user. Returns nil unless an account is available,
/// so the port degrades to local-only (graceful degradation, §9).
struct CKAccountProvider: CloudAccountProviding, @unchecked Sendable {
    let container: CKContainer

    init(container: CKContainer = CKContainer(identifier: CloudKitSchema.containerIdentifier)) {
        self.container = container
    }

    func currentUserToken() async -> String? {
        do {
            guard try await container.accountStatus() == .available else { return nil }
            let recordID = try await container.userRecordID()
            return CloudIdentity.token(forUserRecordName: recordID.recordName)
        } catch {
            Diagnostics.logError(context: "CKAccountProvider.currentUserToken failed", error: error)
            return nil
        }
    }
}

/// The user's PRIVATE CloudKit database. Per-user isolation is enforced by Apple
/// (private DB) and per-firebaseUID isolation by the custom zone.
struct CKCloudDatabase: CloudDatabase, @unchecked Sendable {
    let container: CKContainer

    init(container: CKContainer = CKContainer(identifier: CloudKitSchema.containerIdentifier)) {
        self.container = container
    }

    private var database: CKDatabase { container.privateCloudDatabase }

    func ensureZone(_ zoneName: String) async throws {
        let zone = CKRecordZone(zoneName: zoneName)
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
    }

    func save(_ record: InspectionVersionRecord, inZone zoneName: String) async throws {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: record.recordName, zoneID: zoneID)
        let ck = CKRecord(recordType: CloudKitSchema.RecordType.inspectionVersion, recordID: recordID)
        ck[CloudKitSchema.Field.inspectionId] = record.inspectionId as CKRecordValue
        ck[CloudKitSchema.Field.versionNumber] = record.versionNumber as CKRecordValue
        ck[CloudKitSchema.Field.status] = record.status as CKRecordValue
        ck[CloudKitSchema.Field.locked] = (record.locked ? 1 : 0) as CKRecordValue
        if let finalizedAt = record.finalizedAt {
            ck[CloudKitSchema.Field.finalizedAt] = finalizedAt as CKRecordValue
        }
        ck[CloudKitSchema.Field.schemaVersion] = record.schemaVersion as CKRecordValue
        ck[CloudKitSchema.Field.modifiedAt] = Date() as CKRecordValue

        let assetURL = try Self.writeTempPayload(record.payload, recordName: record.recordName)
        defer { try? FileManager.default.removeItem(at: assetURL) }
        ck[CloudKitSchema.Field.payload] = CKAsset(fileURL: assetURL)

        _ = try await database.modifyRecords(saving: [ck], deleting: [], savePolicy: .changedKeys, atomically: true)
    }

    func delete(recordName: String, inZone zoneName: String) async throws {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        _ = try await database.modifyRecords(saving: [], deleting: [recordID], savePolicy: .changedKeys, atomically: true)
    }

    /// CKAsset must point at a file on disk. Stage the payload in a temp dir;
    /// the caller removes it after the upload completes.
    private static func writeTempPayload(_ data: Data, recordName: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ngs-ck-assets", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(recordName).json", isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }
}
