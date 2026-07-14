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
                let (saveResults, _) = try await database.modifyRecords(saving: [ck], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                // A1: a per-record failure comes back in the RESULTS, not as a throw
                // — discarding it silently dequeued a change that never landed. A
                // per-record serverRecordChanged thrown here is caught by the SAME
                // catch below, so it still routes into the fetch-retry loop.
                try Self.verifySaveResults(saveResults, submitted: [ck.recordID])
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
        let (_, deleteResults) = try await database.modifyRecords(saving: [], deleting: [recordID], savePolicy: .changedKeys, atomically: true)
        // A1: surface a per-record delete failure instead of discarding it, so the
        // port re-queues the change. (An already-absent record is idempotent success
        // — see verifyDeleteResults.)
        try Self.verifyDeleteResults(deleteResults, submitted: [recordID])
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
                let (saveResults, _) = try await database.modifyRecords(saving: [meta], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                // A1: a per-record failure must throw (re-queue), and a per-record
                // serverRecordChanged routes into the same retry catch below.
                try Self.verifySaveResults(saveResults, submitted: [meta.recordID])
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

    // MARK: - Asset sync (D-0203)

    func saveAsset(_ record: SyncAssetRecord, inZone zoneName: String) async throws {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: record.recordName, zoneID: zoneID)

        // Stage the payload bytes to a temp file the CKAsset points at; removed after.
        let assetURL = try Self.writeTempPayload(record.payload, recordName: record.recordName)
        defer { try? FileManager.default.removeItem(at: assetURL) }

        // Assets are regenerable deliverables (thumbnail regen, PDF re-export, scan
        // rename all overwrite the same recordName), NOT immutable legal records — so
        // unlike `save(_:)` there is no fetch-first immutability guard and no
        // serverRecordChanged retry: a simple `.changedKeys` last-writer-overwrites is
        // correct. A stale copy losing a race just re-pushes on its next change.
        let ck = CKRecord(recordType: CloudKitSchema.recordType(forAssetKind: record.kind.rawValue), recordID: recordID)
        ck[CloudKitSchema.Field.assetJobId] = record.jobId.uuidString as CKRecordValue
        ck[CloudKitSchema.Field.assetRelativePath] = record.relativePath as CKRecordValue
        ck[CloudKitSchema.Field.assetKind] = record.kind.rawValue as CKRecordValue
        ck[CloudKitSchema.Field.assetModifiedAt] = record.modifiedAt as CKRecordValue
        ck[CloudKitSchema.Field.schemaVersion] = record.schemaVersion as CKRecordValue
        ck[CloudKitSchema.Field.payload] = CKAsset(fileURL: assetURL)

        let (saveResults, _) = try await database.modifyRecords(saving: [ck], deleting: [], savePolicy: .changedKeys, atomically: true)
        // A1: a per-record failure returned in the results (e.g. quota, zone gone,
        // Prod schema missing the asset record type) must THROW so flushPending
        // re-queues the change — discarding it was the silent asset-loss hole.
        try Self.verifySaveResults(saveResults, submitted: [ck.recordID])
    }

    func recordAssetTombstone(key: String, inZone zoneName: String) async throws {
        try await modifyAssetTombstones(inZone: zoneName) { keys in
            guard !keys.contains(key) else { return false }   // already tombstoned — idempotent
            keys.append(key)
            return true
        }
    }

    func clearAssetTombstone(key: String, inZone zoneName: String) async throws {
        try await modifyAssetTombstones(inZone: zoneName) { keys in
            guard let idx = keys.firstIndex(of: key) else { return false }   // absent — idempotent no-op
            keys.remove(at: idx)
            return true
        }
    }

    func tombstonedAssetKeys(inZone zoneName: String) async throws -> Set<String> {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: CloudKitSchema.syncMetaRecordName, zoneID: zoneID)
        do {
            let meta = try await database.record(for: recordID)
            return Set((meta[CloudKitSchema.Field.deletedAssets] as? [String]) ?? [])
        } catch let ckError as CKError where ckError.code == .unknownItem {
            return []   // no SyncMeta yet → nothing tombstoned
        }
    }

    /// Read-modify-write of the per-zone SyncMeta `deletedAssets` field ONLY (never
    /// touches `deletedIds`, so an asset-tombstone write that fails on a Prod schema
    /// missing this field can't break version-deletion sync). `mutate` edits the key
    /// list in place and returns whether it changed anything; on no-change we skip the
    /// save. Same bounded serverRecordChanged retry as `recordTombstone`.
    private func modifyAssetTombstones(inZone zoneName: String, _ mutate: (inout [String]) -> Bool) async throws {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: CloudKitSchema.syncMetaRecordName, zoneID: zoneID)

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
            var keys = (meta[CloudKitSchema.Field.deletedAssets] as? [String]) ?? []
            guard mutate(&keys) else { return }   // no change → nothing to persist
            meta[CloudKitSchema.Field.deletedAssets] = keys as CKRecordValue
            do {
                let (saveResults, _) = try await database.modifyRecords(saving: [meta], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                // A1: same per-record verification as recordTombstone.
                try Self.verifySaveResults(saveResults, submitted: [meta.recordID])
                return
            } catch let error where Self.isServerRecordChanged(error) {
                lastConflict = error
                Diagnostics.logInfo("CKCloudDatabase: SyncMeta changed mid-asset-tombstone (attempt \(attempt)/\(maxAttempts)); re-fetching and retrying.")
                continue
            }
        }
        throw lastConflict ?? CKError(.serverRecordChanged)
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

    // MARK: - Per-record result verification (A1)

    /// Unwraps the per-record save Results of a `modifyRecords` call for every
    /// record we submitted. The iOS 17 async `modifyRecords` reports per-record
    /// failures IN THE RESULTS DICTIONARY, not (only) as a thrown error — so the
    /// old `_ = try await …` discarded genuine failures, the caller returned as if
    /// the save landed, and `CloudKitSyncPort.flushPending` DEQUEUED the change:
    /// the #1 silent-loss hole. Any `.failure` is re-thrown; a submitted record
    /// with NO result entry throws a synthetic descriptive error (fail closed —
    /// "no evidence it saved" must never count as success).
    ///
    /// Matching is by `recordName`, NOT `CKRecord.ID` equality: a re-fetched
    /// server record's zone `ownerName` (the resolved owner) can differ from our
    /// constructed ID (`CKCurrentUserDefaultName`), which would make a dictionary
    /// lookup by ID miss and misreport a clean save as a missing result.
    /// Internal (not private) so unit tests can exercise it with constructed
    /// CloudKit value types — no server round-trip needed.
    static func verifySaveResults(
        _ results: [CKRecord.ID: Result<CKRecord, Error>],
        submitted: [CKRecord.ID]
    ) throws {
        for id in submitted {
            guard let entry = results.first(where: { $0.key.recordName == id.recordName }) else {
                throw Self.missingResultError(recordName: id.recordName, operation: "save")
            }
            if case .failure(let error) = entry.value { throw error }
        }
    }

    /// Delete-side twin of `verifySaveResults`. One deliberate carve-out: a
    /// per-record `.unknownItem` on a DELETE is idempotent success — the record is
    /// already absent, which IS the goal state. Deletes retry after transient
    /// failures (and can target records that were never pushed), so throwing here
    /// would wedge the queue permanently on a change that cannot ever succeed
    /// "harder" than the record already being gone.
    static func verifyDeleteResults(
        _ results: [CKRecord.ID: Result<Void, Error>],
        submitted: [CKRecord.ID]
    ) throws {
        for id in submitted {
            guard let entry = results.first(where: { $0.key.recordName == id.recordName }) else {
                throw Self.missingResultError(recordName: id.recordName, operation: "delete")
            }
            if case .failure(let error) = entry.value {
                if let ckError = error as? CKError, ckError.code == .unknownItem { continue }
                throw error
            }
        }
    }

    private static func missingResultError(recordName: String, operation: String) -> Error {
        NSError(
            domain: "NexGenSpec.CloudKitBackends",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "modifyRecords returned no per-record \(operation) result for record \(recordName); treating as failed so the change is re-queued (A1)"]
        )
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
        var changedAssets: [SyncAssetRecord] = []
        var deleted: [String] = []
        var moreComing = true

        while moreComing {
            let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: serverToken)
            for (_, modificationResult) in result.modificationResultsByID {
                switch modificationResult {
                case .success(let modification):
                    // A record is EITHER a version OR an asset (remoteVersion returns
                    // nil for the asset record types, and vice versa) — no double-count.
                    if let remote = Self.remoteVersion(from: modification.record) {
                        changed.append(remote)
                    } else if let asset = Self.remoteAsset(from: modification.record) {
                        changedAssets.append(asset)
                    }
                case .failure(let error):
                    // A single record failing to materialize must not abort the
                    // whole pull; log it and keep going (no swallowed errors, §11).
                    Diagnostics.logError(context: "CKZoneFetcher: per-record change failed", error: error)
                }
            }
            // Symmetric with the change path's recordType guard (review F2): only
            // forward InspectionVersion deletions. Asset deletions are NOT taken from
            // CK-native deletions — the asset recordName is a non-reversible hash that
            // can't map back to a (jobId, relativePath), so asset deletion is driven
            // entirely by the `deletedAssets` tombstone log (see CloudKitSyncPort.pull).
            for deletion in result.deletions where deletion.recordType == CloudKitSchema.RecordType.inspectionVersion {
                deleted.append(deletion.recordID.recordName)
            }
            serverToken = result.changeToken
            moreComing = result.moreComing
        }

        return ZoneChanges(changed: changed, changedAssets: changedAssets, deletedRecordNames: deleted, newToken: Self.encodeToken(serverToken))
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

    /// Decodes one asset CKRecord (D-0203) into the transport projection. Returns nil
    /// for non-asset records or a record that fails receiver-side validation, so the
    /// caller simply skips it.
    private static func remoteAsset(from ck: CKRecord) -> SyncAssetRecord? {
        let type = ck.recordType
        guard type == CloudKitSchema.RecordType.reportPDF || type == CloudKitSchema.RecordType.mediaAsset else { return nil }
        guard let jobIdStr = ck[CloudKitSchema.Field.assetJobId] as? String, let jobId = UUID(uuidString: jobIdStr),
              let relPath = ck[CloudKitSchema.Field.assetRelativePath] as? String,
              let kindRaw = ck[CloudKitSchema.Field.assetKind] as? String, let kind = SyncAssetKind(rawValue: kindRaw),
              // Re-validate the path on the RECEIVER (defense-in-depth: reject
              // traversal/foreign, and confirm the declared kind matches the path).
              SyncAssetPaths.kind(forRelativePath: relPath) == kind,
              let asset = ck[CloudKitSchema.Field.payload] as? CKAsset, let fileURL = asset.fileURL,
              let payload = try? Data(contentsOf: fileURL) else { return nil }
        // LWW clock (D-0203 review): prefer CloudKit's SERVER modificationDate over the
        // pusher's client-supplied `assetModifiedAt` so last-writer-wins arbitrates on a
        // single authoritative clock — skew between a user's OWN devices can no longer
        // permanently drop an asset update (e.g. a scan rename) the way comparing the
        // receiver's local mtime against the pushing device's client mtime could. Unlike
        // a version — whose embedded model `updatedAt` travels with the content and is
        // compared like-for-like — a synced asset is an opaque blob with no embedded
        // logical clock, so the server date is the skew-minimal comparand. Falls back to
        // the client field, then distantPast (any local copy wins) — never nil.
        let modifiedAt = ck.modificationDate ?? (ck[CloudKitSchema.Field.assetModifiedAt] as? Date) ?? .distantPast
        return SyncAssetRecord(recordName: ck.recordID.recordName, jobId: jobId, relativePath: relPath,
                               kind: kind, modifiedAt: modifiedAt,
                               schemaVersion: (ck[CloudKitSchema.Field.schemaVersion] as? Int) ?? 1, payload: payload)
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
