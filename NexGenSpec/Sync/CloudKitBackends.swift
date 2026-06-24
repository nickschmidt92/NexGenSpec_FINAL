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

        // Stage the payload bytes once; reused across retries (the CKAsset wrapper is
        // rebuilt per attempt inside `apply`). The temp file is removed after the save
        // settles.
        let assetURL = try Self.writeTempPayload(record.payload, recordName: record.recordName)
        defer { try? FileManager.default.removeItem(at: assetURL) }

        // Optimistic-concurrency save with a bounded re-fetch/retry loop (NEW-2).
        //
        // Immutability at the source of truth (fix A): fetch the existing server
        // record first; if it is ALREADY finalized/locked, leave it untouched — a
        // second device's divergent finalization of the same versionId must never
        // clobber the first finalized record (the immutable legal/tamper-evidence
        // record). Reusing the fetched (non-locked) record carries its CURRENT change
        // tag, so the save cleanly overwrites THAT version (promoting a draft to
        // finalized) — or, for a fresh record, creates it.
        //
        // The fetch→save window is NOT atomic: another device can finalize the same
        // record in between. `.ifServerRecordUnchanged` makes CloudKit DETECT that
        // (serverRecordChanged) instead of silently overwriting the finalized record
        // back to a draft. On that conflict we loop: re-fetch, re-apply the
        // immutability guard (if it is NOW finalized, the other device won — stop and
        // succeed), else rebuild against the fresh tag and retry. Bounded so a
        // pathological ping-pong can't spin; on exhaustion we throw so the port keeps
        // the change queued (§11, no swallowed failures).
        let maxAttempts = 3
        var lastConflict: Error?
        for attempt in 1...maxAttempts {
            let existing: CKRecord?
            do {
                existing = try await database.record(for: recordID)
            } catch let ckError as CKError where ckError.code == .unknownItem {
                existing = nil  // not present yet → create
            }
            if let existing, (existing[CloudKitSchema.Field.locked] as? Int) == 1 {
                Diagnostics.logInfo("CKCloudDatabase: server record \(record.recordName) is already finalized; left immutable.")
                return
            }

            let ck = existing ?? CKRecord(recordType: CloudKitSchema.RecordType.inspectionVersion, recordID: recordID)
            Self.apply(record, to: ck, assetURL: assetURL)

            do {
                _ = try await database.modifyRecords(saving: [ck], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                return
            } catch let error where Self.isServerRecordChanged(error) {
                // Concurrent cross-device write landed in the fetch→save window.
                // Re-fetch + re-guard + retry with the fresh change tag next iteration.
                lastConflict = error
                Diagnostics.logInfo("CKCloudDatabase: \(record.recordName) changed on the server mid-save (attempt \(attempt)/\(maxAttempts)); re-fetching and retrying.")
                continue
            }
        }
        // Retries exhausted without converging — surface so the caller re-queues it.
        throw lastConflict ?? CKError(.serverRecordChanged)
    }

    func delete(recordName: String, inZone zoneName: String) async throws {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        _ = try await database.modifyRecords(saving: [], deleting: [recordID], savePolicy: .changedKeys, atomically: true)
    }

    func deleteZone(_ zoneName: String) async throws {
        // Account-deletion teardown (edge G / 5.1.1(v)): dropping the per-UID custom
        // zone removes every record (and its payload CKAssets) it holds in one
        // server op, so no residual client PII remains in the user's private iCloud.
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        _ = try await database.modifyRecordZones(saving: [], deleting: [zoneID])
    }

    func recordTombstone(versionId: String, inZone zoneName: String) async throws {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: CloudKitSchema.syncMetaRecordName, zoneID: zoneID)

        // Optimistic read-modify-write of the per-zone SyncMeta deletion log, with the
        // same bounded serverRecordChanged retry as save() so two devices tombstoning
        // concurrently can't clobber each other's entries (§8).
        let maxAttempts = 3
        var lastConflict: Error?
        for attempt in 1...maxAttempts {
            let existing: CKRecord?
            do {
                existing = try await database.record(for: recordID)
            } catch let ckError as CKError where ckError.code == .unknownItem {
                existing = nil
            }
            let meta = existing ?? CKRecord(recordType: CloudKitSchema.RecordType.syncMeta, recordID: recordID)
            var ids = (meta[CloudKitSchema.Field.deletedIds] as? [String]) ?? []
            if ids.contains(versionId) { return }   // already tombstoned — idempotent
            // NOTE (sync-GA follow-up): the deletion log is append-only and currently
            // UN-pruned. For a first release the count stays small, but before it can
            // approach the CKRecord field-size limit a GC pass is needed (drop
            // tombstones older than the max plausible offline window, or cap + evict
            // oldest). Tracked as a sync-GA item.
            ids.append(versionId)
            meta[CloudKitSchema.Field.deletedIds] = ids as CKRecordValue
            do {
                _ = try await database.modifyRecords(saving: [meta], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                return
            } catch let error where Self.isServerRecordChanged(error) {
                lastConflict = error
                Diagnostics.logInfo("CKCloudDatabase: SyncMeta changed mid-tombstone (attempt \(attempt)/\(maxAttempts)); re-fetching and retrying.")
                continue
            }
        }
        throw lastConflict ?? CKError(.serverRecordChanged)
    }

    func tombstonedIds(inZone zoneName: String) async throws -> Set<String> {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: CloudKitSchema.syncMetaRecordName, zoneID: zoneID)
        do {
            let meta = try await database.record(for: recordID)
            return Set((meta[CloudKitSchema.Field.deletedIds] as? [String]) ?? [])
        } catch let ckError as CKError where ckError.code == .unknownItem {
            return []   // no SyncMeta yet → nothing tombstoned
        }
    }

    /// Sets every InspectionVersion field (plus a freshly-wrapped payload CKAsset) on
    /// `ck` from `record`. Factored out so the save-retry loop can rebuild the record
    /// against a re-fetched change tag without duplicating the field mapping.
    private static func apply(_ record: InspectionVersionRecord, to ck: CKRecord, assetURL: URL) {
        ck[CloudKitSchema.Field.inspectionId] = record.inspectionId as CKRecordValue
        ck[CloudKitSchema.Field.versionNumber] = record.versionNumber as CKRecordValue
        ck[CloudKitSchema.Field.status] = record.status as CKRecordValue
        ck[CloudKitSchema.Field.locked] = (record.locked ? 1 : 0) as CKRecordValue
        if let finalizedAt = record.finalizedAt {
            ck[CloudKitSchema.Field.finalizedAt] = finalizedAt as CKRecordValue
        }
        ck[CloudKitSchema.Field.schemaVersion] = record.schemaVersion as CKRecordValue
        // The last-writer-wins clock: push the version's actual EDIT time, not the
        // upload time, so a pull on another device arbitrates draft conflicts by when
        // each side was edited (build 22 slice 4c). Falls back to now only for a legacy
        // version that predates `updatedAt`.
        ck[CloudKitSchema.Field.modifiedAt] = (record.updatedAt ?? Date()) as CKRecordValue
        ck[CloudKitSchema.Field.payload] = CKAsset(fileURL: assetURL)
    }

    /// True if `error` is (or, inside an atomic batch, wraps via `.partialFailure`) a
    /// CloudKit `serverRecordChanged` conflict — the optimistic-concurrency signal
    /// that the server record changed since we fetched it.
    private static func isServerRecordChanged(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        if ckError.code == .serverRecordChanged { return true }
        if ckError.code == .partialFailure,
           let partials = ckError.partialErrorsByItemID?.values {
            return partials.contains { ($0 as? CKError)?.code == .serverRecordChanged }
        }
        return false
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
