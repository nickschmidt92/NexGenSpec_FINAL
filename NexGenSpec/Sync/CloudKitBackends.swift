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

    func save(_ record: InspectionVersionRecord, inZone zoneName: String, ifAbsent: Bool) async throws {
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
        // The last-writer-wins clock: push the version's actual EDIT time, not the
        // upload time, so a pull on another device arbitrates draft conflicts by
        // when each side was edited (build 22 slice 4c). Falls back to now only for
        // a legacy version that predates `updatedAt`.
        ck[CloudKitSchema.Field.modifiedAt] = (record.updatedAt ?? Date()) as CKRecordValue

        let assetURL = try Self.writeTempPayload(record.payload, recordName: record.recordName)
        defer { try? FileManager.default.removeItem(at: assetURL) }
        ck[CloudKitSchema.Field.payload] = CKAsset(fileURL: assetURL)

        // Immutable (locked) records use a never-clobber policy: a freshly-built
        // record has no change tag, so .ifServerRecordUnchanged creates it when
        // absent but FAILS (serverRecordChanged) if one already exists — which for
        // a finalized report is the correct "leave it immutable" outcome. Drafts
        // overwrite with .changedKeys (last-writer-wins). Full draft conflict
        // arbitration by modifiedAt is slice 4.
        let policy: CKModifyRecordsOperation.RecordSavePolicy = ifAbsent ? .ifServerRecordUnchanged : .changedKeys
        do {
            _ = try await database.modifyRecords(saving: [ck], deleting: [], savePolicy: policy, atomically: true)
        } catch {
            if ifAbsent, Self.isAlreadyPresentConflict(error) {
                Diagnostics.logInfo("CKCloudDatabase: locked record \(record.recordName) already present; left immutable.")
                return
            }
            throw error
        }
    }

    /// True when a save failed because the record already exists on the server
    /// (a `serverRecordChanged` conflict, possibly wrapped in a partial error).
    private static func isAlreadyPresentConflict(_ error: Error) -> Bool {
        if let ckError = error as? CKError {
            if ckError.code == .serverRecordChanged { return true }
            if let partials = ckError.partialErrorsByItemID {
                return partials.values.contains { ($0 as? CKError)?.code == .serverRecordChanged }
            }
        }
        return false
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

/// The live incremental zone fetcher (build 22, slice 4c). Pulls the changes a
/// zone accumulated since a server change token using the iOS 17 async
/// `CKDatabase.recordZoneChanges(inZoneWith:since:)`, decodes each `InspectionVersion`
/// record (payload `CKAsset` → `Data`), and hands the batch + the new token back
/// to `CloudKitSyncPort.pull()`, which arbitrates conflicts via `SyncConflictResolver`.
/// Like `CKCloudDatabase`, this is exercised only on real devices/iCloud — the
/// unit tests use `FakeFetcher`. See docs/design/build-22-cloudkit-sync.md §4, §8.
struct CKZoneFetcher: CloudZoneFetcher, @unchecked Sendable {
    let container: CKContainer

    init(container: CKContainer = CKContainer(identifier: CloudKitSchema.containerIdentifier)) {
        self.container = container
    }

    private var database: CKDatabase { container.privateCloudDatabase }

    func fetchChanges(inZone zoneName: String, since token: Data?) async throws -> ZoneChanges {
        do {
            return try await fetchPages(zoneName: zoneName, token: Self.decodeToken(token))
        } catch let ckError as CKError where ckError.code == .changeTokenExpired {
            // The server change token aged out: discard it and resync the whole
            // zone from scratch. Idempotent — applying the full set is safe because
            // record names are stable and the conflict resolver re-arbitrates each.
            Diagnostics.logInfo("CKZoneFetcher: change token expired; resyncing zone from scratch.")
            return try await fetchPages(zoneName: zoneName, token: nil)
        }
    }

    /// Pages through `recordZoneChanges` until `moreComing` is false, threading the
    /// server change token across pages, and returns the accumulated batch.
    private func fetchPages(zoneName: String, token startToken: CKServerChangeToken?) async throws -> ZoneChanges {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        var serverToken = startToken
        var changed: [RemoteVersion] = []
        var deleted: [String] = []
        var moreComing = true

        while moreComing {
            let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: serverToken)
            for (_, modificationResult) in result.modificationResultsByID {
                switch modificationResult {
                case .success(let modification):
                    if let remote = Self.remoteVersion(from: modification.record) {
                        changed.append(remote)
                    }
                case .failure(let error):
                    // A single record failing to materialize must not abort the
                    // whole pull; log it and keep going (no swallowed errors, §11).
                    Diagnostics.logError(context: "CKZoneFetcher: per-record change failed", error: error)
                }
            }
            // Symmetric with the change path's recordType guard (review F2): only
            // forward InspectionVersion deletions. A later slice's ReportPDF /
            // MediaAsset deletion must not be mistaken for a version tombstone.
            for deletion in result.deletions where deletion.recordType == CloudKitSchema.RecordType.inspectionVersion {
                deleted.append(deletion.recordID.recordName)
            }
            serverToken = result.changeToken
            moreComing = result.moreComing
        }

        return ZoneChanges(changed: changed, deletedRecordNames: deleted, newToken: Self.encodeToken(serverToken))
    }

    /// Decodes one `InspectionVersion` CKRecord into the transport projection plus
    /// its LWW clock. Returns nil for non-version records (e.g. a later slice's
    /// ReportPDF/MediaAsset) or a record whose payload asset can't be read, so the
    /// caller simply skips them.
    private static func remoteVersion(from ck: CKRecord) -> RemoteVersion? {
        guard ck.recordType == CloudKitSchema.RecordType.inspectionVersion else { return nil }
        guard let asset = ck[CloudKitSchema.Field.payload] as? CKAsset,
              let fileURL = asset.fileURL,
              let payload = try? Data(contentsOf: fileURL) else { return nil }

        let editedAt = ck[CloudKitSchema.Field.modifiedAt] as? Date
        // LWW clock: the pushed edit time; fall back to CloudKit's own record
        // modification time, then to distantPast (so any local copy wins) — never nil.
        let modifiedAt = editedAt ?? ck.modificationDate ?? .distantPast
        let lockedInt = (ck[CloudKitSchema.Field.locked] as? Int) ?? 0

        let record = InspectionVersionRecord(
            recordName: ck.recordID.recordName,
            inspectionId: (ck[CloudKitSchema.Field.inspectionId] as? String) ?? "",
            versionNumber: (ck[CloudKitSchema.Field.versionNumber] as? Int) ?? 0,
            status: (ck[CloudKitSchema.Field.status] as? String) ?? "",
            locked: lockedInt == 1,
            finalizedAt: ck[CloudKitSchema.Field.finalizedAt] as? Date,
            schemaVersion: (ck[CloudKitSchema.Field.schemaVersion] as? Int) ?? 1,
            updatedAt: editedAt,
            payload: payload
        )
        return RemoteVersion(record: record, modifiedAt: modifiedAt)
    }

    // MARK: - Change token archiving

    /// Archives a `CKServerChangeToken` to `Data` for persistence in the binding
    /// (`SyncBinding.changeToken`). Secure-coding round-trips the token verbatim.
    static func encodeToken(_ token: CKServerChangeToken?) -> Data? {
        guard let token else { return nil }
        do {
            return try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        } catch {
            // §11 no swallowed errors: surface the (theoretical) archive failure.
            // The fallback — a nil token → the next pull re-fetches the same window
            // idempotently — is harmless, so this is observability, not control flow.
            Diagnostics.logError(context: "CKZoneFetcher.encodeToken failed", error: error)
            return nil
        }
    }

    /// Reconstructs a `CKServerChangeToken` from persisted `Data`; nil ⇒ a full
    /// (token-less) initial fetch.
    static func decodeToken(_ data: Data?) -> CKServerChangeToken? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}
