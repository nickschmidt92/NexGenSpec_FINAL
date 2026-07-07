//
//  CloudKitSyncPort.swift
//  NexGenSpec
//
//  The live CloudKit mirror (build 22, slice 2b). PUSH-ONLY: it reflects local
//  changes up to the user's private CloudKit zone and never applies cloud changes
//  back yet (apply-back is a later slice). It is an OBSERVER of the local-first
//  store — it never resolves appRoot, never wipes local data, and on an
//  iCloud-account change it REFUSES-AND-ISOLATES (landmine 1) rather than crossing
//  data between accounts.
//
//  CloudKit is reached only through injected protocols (CloudSyncProtocols.swift),
//  so this type is unit-testable with fakes and has no compile-time CloudKit
//  dependency. See docs/design/build-22-cloudkit-sync.md §3, §5.
//

import Foundation

final class CloudKitSyncPort: SyncPort, @unchecked Sendable {

    private let account: CloudAccountProviding
    private let database: CloudDatabase
    private let reader: LocalVersionReader
    private let bindings: BindingStoring
    private let fetcher: CloudZoneFetcher
    private let writer: LocalVersionWriter

    private let lock = NSLock()
    private var _status: SyncStatus = .off
    private var activeBinding: SyncBinding?
    private var pending: [SyncChange] = []
    /// Reentrancy guard for pull() — bind()'s tail pull and the foreground
    /// pullNow() can fire concurrently (review F6). Guarded by `lock`.
    private var _isPulling = false
    /// Serializes flushPending() so two concurrent flushes (one per
    /// recordLocalChange Task, plus the bind/foreground re-drives) can't double-push
    /// the same snapshot. `_flushAgain` re-runs once more if work was requested
    /// while a flush was in flight, so a change appended mid-flush is still drained
    /// promptly (build 22 fix F). Guarded by `lock`.
    private var _isFlushing = false
    private var _flushAgain = false

    init(
        account: CloudAccountProviding,
        database: CloudDatabase,
        reader: LocalVersionReader = DiskVersionReader(),
        bindings: BindingStoring = KeychainBindingStore(),
        fetcher: CloudZoneFetcher = NoopZoneFetcher(),
        writer: LocalVersionWriter = NoopLocalVersionWriter()
    ) {
        self.account = account
        self.database = database
        self.reader = reader
        self.bindings = bindings
        self.fetcher = fetcher
        self.writer = writer
    }

    var status: SyncStatus { lock.withLock { _status } }

    func bind(firebaseUID: String) async {
        let token = await account.currentUserToken()
        let existing = bindings.load(forUID: firebaseUID)
        switch SyncIdentityResolver.resolve(firebaseUID: firebaseUID, cloudToken: token, existing: existing) {
        case .noAccount:
            setState(.localOnly, binding: nil)

        case .bindNew(let zoneName):
            guard let token else { setState(.localOnly, binding: nil); return }
            do {
                try await database.ensureZone(zoneName)
                let newBinding = SyncBinding(
                    firebaseUID: firebaseUID,
                    cloudUserToken: token,
                    zoneName: zoneName,
                    boundAt: Date()
                )
                bindings.save(newBinding)
                setState(.idle, binding: newBinding)
            } catch {
                Diagnostics.logError(context: "CloudKitSyncPort.bind(bindNew) ensureZone failed", error: error)
                setState(.error("Couldn't set up iCloud sync."), binding: nil)
            }

        case .resume(let existingBinding):
            do {
                try await database.ensureZone(existingBinding.zoneName)
                setState(.idle, binding: existingBinding)
            } catch {
                Diagnostics.logError(context: "CloudKitSyncPort.bind(resume) ensureZone failed", error: error)
                setState(.error("Couldn't resume iCloud sync."), binding: nil)
            }

        case .refuseAndIsolate(let reason):
            // Detach only. NEVER push this UID's data to the new iCloud, NEVER pull
            // the new iCloud's data in, NEVER touch local. The binding is left in
            // storage intact (the original iCloud account may return later).
            setState(.paused(reason: reason), binding: nil)
        }
        // After a successful bind, run one-time seeding (no-op if not bound or
        // already seeded), then pull remote changes (two-way), then flush any
        // changes that queued while we were unbound/paused (fix F) — by now
        // `activeBinding` is set, so a previously-stranded edit finally pushes.
        await seedIfNeeded(firebaseUID: firebaseUID)
        await pull()
        await flushPending()
    }

    func unbind() {
        lock.withLock {
            _status = .off
            activeBinding = nil
            pending.removeAll()
        }
    }

    func recordLocalChange(_ change: SyncChange) {
        lock.withLock { pending.append(change) }
        Task { await flushPending() }
    }

    /// One-time local→cloud seeding for an existing (build-21) user. Idempotent,
    /// interrupt-safe, lossless:
    /// - guarded by `binding.seededAt` so it runs at most once per successful pass;
    /// - dedup-proof because each record's name is its versionId, so re-pushing
    ///   overwrites rather than duplicates;
    /// - marks `seededAt` ONLY after a fully clean pass, so a partial/interrupted
    ///   seed simply re-runs on the next bind;
    /// - push-only — it never deletes or mutates local data.
    func seedIfNeeded(firebaseUID: String) async {
        let binding: SyncBinding? = lock.withLock { activeBinding }
        guard let binding, binding.firebaseUID == firebaseUID, binding.seededAt == nil else { return }

        var allSucceeded = true
        for snapshot in reader.allLocalVersions() {
            // TOCTOU guard (fix B / landmine 1): an account switch can detach this
            // binding (unbind clears `activeBinding`) and cancel this task while we
            // are suspended at an `await`. Re-check both BEFORE every cloud write so
            // a captured A-binding can never push into A's zone after the device has
            // re-scoped to B. (The reader is also pinned to A's disk, so it only ever
            // reads A's data — this is defense in depth on top of that.)
            if Task.isCancelled { return }
            let stillBound = lock.withLock { activeBinding?.zoneName == binding.zoneName }
            guard stillBound else { return }
            do {
                let record = InspectionRecordMapper.make(meta: snapshot.meta, payload: snapshot.payload)
                // `save` is idempotent on re-seed: it never overwrites an already-
                // finalized server record, and re-pushing an unchanged draft is a
                // harmless overwrite (same recordName). (fix A unified the policy.)
                try await database.save(record, inZone: binding.zoneName)
            } catch {
                allSucceeded = false
                Diagnostics.logError(context: "CloudKitSyncPort.seed push failed", error: error)
            }
        }
        guard allSucceeded else { return }

        var seeded = binding
        seeded.seededAt = Date()
        bindings.save(seeded)
        lock.withLock {
            if activeBinding?.zoneName == binding.zoneName { activeBinding = seeded }
        }
    }

    /// Pull remote changes for the bound zone and apply them locally, resolving
    /// conflicts (finalized immutable; draft last-writer-wins). Persists the new
    /// change token so the next pull is incremental. No-op when not bound.
    func pull() async {
        // Reentrancy guard (review F6): bind()'s tail pull and the foreground
        // pullNow() can fire concurrently on launch / account switch. Two pulls
        // threading the same change token can persist them out of order (a slower
        // fetch clobbering a newer token → a redundant re-fetch). Admit one pull at
        // a time; a concurrent caller is safely dropped because the in-flight pull
        // already covers the same zone/token.
        let begin: Bool = lock.withLock {
            guard !_isPulling else { return false }
            _isPulling = true
            return true
        }
        guard begin else { return }
        defer { lock.withLock { _isPulling = false } }

        let binding: SyncBinding? = lock.withLock { activeBinding }
        guard let binding else { return }

        let changes: ZoneChanges
        do {
            changes = try await fetcher.fetchChanges(inZone: binding.zoneName, since: binding.changeToken)
        } catch {
            Diagnostics.logError(context: "CloudKitSyncPort.pull fetch failed", error: error)
            return
        }

        // Track whether every approved apply persisted. If any failed (e.g. a disk
        // write error), we must NOT advance the change token, so the next pull
        // re-fetches and retries this window instead of skipping the record
        // permanently (review F5). Applies are idempotent (upsert-by-id), so a
        // retry that re-applies an already-applied record is harmless.
        // Deletion log (§8): a stale device may have re-pushed a deleted draft, so a
        // pulled "changed" record can be a resurrection. Fetch the tombstones once and
        // treat a tombstoned draft as a delete. If the fetch FAILS transiently, DON'T
        // settle this batch without resurrection protection (fail-CLOSED): bail so the
        // next pull retries (the token isn't advanced). `tombstonedIds` already returns
        // [] for "no SyncMeta yet", so a throw here is a real transient error.
        let tombstoned: Set<String>
        do {
            tombstoned = try await database.tombstonedIds(inZone: binding.zoneName)
        } catch {
            Diagnostics.logError(context: "CloudKitSyncPort.pull tombstone fetch failed; deferring (token held)", error: error)
            return
        }

        var allApplied = true

        for remote in changes.changed {
            guard let versionId = UUID(uuidString: remote.record.recordName) else { continue }
            let local = reader.localState(forVersionId: versionId)
            // A TRANSIENT local read failure (data-protection/I/O) must NOT settle this
            // record: hold the token so the next pull retries instead of permanently
            // skipping a legitimate remote update (fix D). A genuine decode failure is
            // NOT readFailed and stays a settled keepLocal.
            if local.readFailed { allApplied = false; continue }
            // Tombstone suppression (§8): a stale device may have re-pushed a deleted
            // DRAFT — honor the deletion (delete-wins) rather than applying it. A
            // FINALIZED remote (remote.record.locked) is EXEMPT: a finalize WINS over an
            // older draft-tombstone (immutable legal record), so it falls through to the
            // normal resolver. A finalized LOCAL is protected by resolveDelete regardless.
            if tombstoned.contains(remote.record.recordName), !remote.record.locked {
                if SyncConflictResolver.resolveDelete(local: local) == .deleteLocal {
                    if await writer.deleteLocalVersion(recordName: remote.record.recordName) == false { allApplied = false }
                }
                continue
            }
            let decision = SyncConflictResolver.resolveUpsert(
                local: local, remoteLocked: remote.record.locked, remoteUpdatedAt: remote.modifiedAt
            )
            if decision == .applyRemote {
                // TOCTOU guard (fix B / landmine 1): bail before applying a remote
                // record if an account switch detached/cancelled this pull mid-flight,
                // so an A-zone record is never written into B's store. The writer is
                // additionally pinned to its bound UID; this is defense in depth.
                if Task.isCancelled { return }
                let stillBound = lock.withLock { activeBinding?.zoneName == binding.zoneName }
                guard stillBound else { return }
                if await writer.applyRemoteVersion(remote.record.payload) == false { allApplied = false }
            }
        }

        for recordName in changes.deletedRecordNames {
            guard let versionId = UUID(uuidString: recordName) else { continue }
            let local = reader.localState(forVersionId: versionId)
            // Same fix-D token-hold as the upsert loop: don't settle a delete against a
            // transiently-unreadable local copy — retry on the next pull.
            if local.readFailed { allApplied = false; continue }
            if SyncConflictResolver.resolveDelete(local: local) == .deleteLocal {
                if Task.isCancelled { return }
                let stillBound = lock.withLock { activeBinding?.zoneName == binding.zoneName }
                guard stillBound else { return }
                if await writer.deleteLocalVersion(recordName: recordName) == false { allApplied = false }
            }
        }

        // MARK: Asset pull (D-0203). Applied AFTER the version batch and BEFORE the
        // change token advances, so the token settles only when versions AND assets
        // land cleanly. Asset DELETION is tombstone-driven (the asset recordName is a
        // non-reversible hash, so CK-native deletions can't map back to a local file);
        // asset UPSERTS ride `changes.changedAssets`.
        //
        // Fail-CLOSED on the asset-tombstone fetch (mirrors the version-tombstone fetch
        // above): without it we can't distinguish a deleted asset from a live one, so a
        // transient throw defers the whole batch (token held) rather than risk leaving a
        // tombstoned asset on disk. `tombstonedAssetKeys` already returns [] for a
        // missing SyncMeta / `deletedAssets` field (Prod-without-the-schema), so a throw
        // here is a real transient error.
        let deadAssets: Set<String>
        do {
            deadAssets = try await database.tombstonedAssetKeys(inZone: binding.zoneName)
        } catch {
            Diagnostics.logError(context: "CloudKitSyncPort.pull asset-tombstone fetch failed; deferring (token held)", error: error)
            return
        }

        // Order asset writes so a scan record (<scanId>.json) is applied AFTER its
        // floor-plan PNG / room JSON siblings PRESENT IN THIS BATCH — preserves the
        // local torn-save intent on the receiver, so an interrupted write sequence never
        // surfaces a scan whose PNG/room JSON haven't landed. Cross-batch ordering can't
        // be controlled; readers tolerate the partial state (loadScans lists the scan,
        // the renderer skips a scan with no readable PNG, whole-home waits for room JSON).
        let assetOrder: [SyncAssetKind: Int] = [.lidarFloorplan: 0, .lidarRoom: 0, .thumbnail: 0, .reportPDF: 0, .lidarScan: 1]
        let orderedAssets = changes.changedAssets.sorted { (assetOrder[$0.kind] ?? 0) < (assetOrder[$1.kind] ?? 0) }

        // Keys present as a CHANGED asset in THIS batch. A record arriving in
        // changedAssets means it was (re)created and its tombstone was cleared on push
        // (§1.6 clear-then-save), so upsert-WINS: apply it and do NOT treat it as
        // tombstoned. Consequence: `deadAssets` only deletes assets NOT also re-created
        // in this same batch.
        let changedAssetKeys = Set(orderedAssets.map { "\($0.jobId.uuidString)/\($0.relativePath)" })

        for record in orderedAssets {
            // Same TOCTOU guard as the version loop: bail before writing if an account
            // switch detached/cancelled this pull mid-flight (defense in depth — the
            // writer is also pinned to its bound UID).
            if Task.isCancelled { return }
            let stillBound = lock.withLock { activeBinding?.zoneName == binding.zoneName }
            guard stillBound else { return }
            // false ⇒ a transient write failure: hold the token (don't advance) so the
            // next pull re-fetches and retries this window. Applies are idempotent.
            if await writer.applyRemoteAsset(record) == false { allApplied = false }
        }

        for key in deadAssets where !changedAssetKeys.contains(key) {
            // Parse "<uuid>/<relativePath>": split on the FIRST slash (relativePath
            // itself contains slashes). A malformed key (no slash / non-UUID prefix /
            // empty path) is skipped — never applied as a delete.
            guard let slash = key.firstIndex(of: "/") else { continue }
            guard let jobId = UUID(uuidString: String(key[..<slash])) else { continue }
            let relativePath = String(key[key.index(after: slash)...])
            guard !relativePath.isEmpty else { continue }
            if Task.isCancelled { return }
            let stillBound = lock.withLock { activeBinding?.zoneName == binding.zoneName }
            guard stillBound else { return }
            if await writer.deleteLocalAsset(jobId: jobId, relativePath: relativePath) == false { allApplied = false }
        }

        // Persist the new change token only when the whole batch applied cleanly.
        guard allApplied, let newToken = changes.newToken else { return }
        var updated = binding
        updated.changeToken = newToken
        bindings.save(updated)
        lock.withLock {
            if activeBinding?.zoneName == binding.zoneName { activeBinding = updated }
        }
    }

    /// Pushes pending changes. No-op when not bound (local-only / paused / refused)
    /// — the local store remains the source of truth and the queue is preserved for
    /// the next bind/foreground re-drive. A change is removed from the queue ONLY
    /// after its push succeeds, so a transient unbind never drops an edit (fix F).
    /// Exposed (non-private) so tests can flush deterministically.
    func flushPending() async {
        // Serialize: if a flush is already running, ask it to run once more when it
        // finishes (so a change appended mid-flush still drains) and return — never
        // run two flushes over an overlapping snapshot, which would double-push.
        let shouldRun: Bool = lock.withLock {
            guard !_isFlushing else { _flushAgain = true; return false }
            _isFlushing = true
            return true
        }
        guard shouldRun else { return }
        defer {
            let runAgain: Bool = lock.withLock {
                _isFlushing = false
                guard _flushAgain else { return false }
                _flushAgain = false
                return true
            }
            if runAgain { Task { await self.flushPending() } }
        }

        // Snapshot WITHOUT clearing: if we are not bound (local-only / paused /
        // bind-in-flight) the queued edits must survive — they re-drive on the next
        // bind() and on foreground. Clearing first (the old bug) dropped any edit
        // made during a transient unbind, and seeding runs only once so it never
        // re-pushed.
        let (binding, snapshot): (SyncBinding?, [SyncChange]) = lock.withLock {
            (activeBinding, pending)
        }
        guard let binding, !snapshot.isEmpty else { return }

        // Fetch the deletion log first (only when there's an upsert to check). If it
        // fails transiently we must NOT push — pushing without it could resurrect a
        // tombstoned draft (fail-CLOSED): keep the queue (snapshot not dequeued) and
        // retry on the next flush. Fetched before the .syncing status so a clean bail
        // doesn't leave a stale syncing state.
        let tombstoned: Set<String>
        if snapshot.contains(where: { if case .versionUpserted = $0 { return true } else { return false } }) {
            do {
                tombstoned = try await database.tombstonedIds(inZone: binding.zoneName)
            } catch {
                Diagnostics.logError(context: "CloudKitSyncPort.flush tombstone fetch failed; deferring push (queue preserved)", error: error)
                return
            }
        } else {
            tombstoned = []
        }

        lock.withLock { _status = .syncing }

        var failed: [SyncChange] = []
        for (i, change) in snapshot.enumerated() {
            // Stop pushing if a racing rebind/unbind detached this binding (or
            // cancelled the bind task) mid-flush — but PRESERVE the unprocessed
            // changes in the queue rather than dropping them (fix B + F).
            let proceed = !Task.isCancelled && lock.withLock { activeBinding?.zoneName == binding.zoneName }
            guard proceed else {
                failed.append(contentsOf: snapshot[i...])
                break
            }
            do {
                try await apply(change, binding: binding, tombstoned: tombstoned)
            } catch {
                failed.append(change)   // keep it queued; do NOT drop on failure
                Diagnostics.logError(context: "CloudKitSyncPort push failed", error: error)
            }
        }

        lock.withLock {
            // Only mutate the queue/status if this binding is still active — an
            // unbind() already cleared `pending` otherwise, and re-prepending here
            // would resurrect a detached binding's changes.
            guard activeBinding?.zoneName == binding.zoneName else { return }
            // Dequeue ONLY the changes we processed (the snapshot slice): keep the
            // ones that failed/were-skipped, plus anything appended during the flush.
            let appendedDuringFlush = pending.count > snapshot.count ? Array(pending[snapshot.count...]) : []
            pending = failed + appendedDuringFlush
            // Surface .error only on a GENUINE push failure (something stayed in
            // `failed`); changes merely appended mid-flush are drained by the re-run,
            // so they shouldn't masquerade as an upload error.
            _status = failed.isEmpty ? .idle : .error("Some changes couldn't be uploaded yet; still queued.")
        }
    }

    private func apply(_ change: SyncChange, binding: SyncBinding, tombstoned: Set<String>) async throws {
        switch change {
        case .versionUpserted(let meta):
            // Tombstone suppression (§8): a tombstoned DRAFT must not be resurrected
            // (delete-wins) — drop the local copy and don't push. But a FINALIZED local
            // (resolveDelete keeps it) is an immutable legal record that a later finalize
            // WINS with over an older draft-tombstone: fall through and push it (save's
            // server-side guard arbitrates). So only suppress when resolveDelete says
            // delete; never strand a finalized record off-cloud.
            if tombstoned.contains(meta.id.uuidString),
               SyncConflictResolver.resolveDelete(local: reader.localState(forVersionId: meta.id)) == .deleteLocal {
                _ = await writer.deleteLocalVersion(recordName: meta.id.uuidString)
                return
            }
            guard let data = reader.versionData(forVersionId: meta.id) else { return }
            let record = InspectionRecordMapper.make(meta: meta, payload: data)
            // Push the version (fix A). `database.save` overwrites a draft (LWW is
            // arbitrated on the receiver) and PROMOTES a draft to finalized (finalize
            // keeps the same versionId, so the draft record already exists). The save
            // refuses to overwrite an ALREADY-finalized server record (immutable legal
            // record — enforced inside `save` by a fetch-and-guard), and uses
            // `.ifServerRecordUnchanged` + a bounded re-fetch/retry (NEW-2) so a second
            // device's concurrent finalization of the same id in the fetch→save window
            // can't clobber the first.
            try await database.save(record, inZone: binding.zoneName)
        case .versionDeleted(let versionId):
            // Record the tombstone BEFORE deleting (§8) so a retry after a transient
            // failure re-runs both idempotently; the deletion log is what stops a stale
            // device from resurrecting this id.
            try await database.recordTombstone(versionId: versionId.uuidString, inZone: binding.zoneName)
            try await database.delete(recordName: versionId.uuidString, inZone: binding.zoneName)
        case .mediaUpserted(let jobId, let relativePath):
            // Excluded/foreign path (photos, videos, USDZ, whole-home cache, traversal)
            // → ignore. The same allowlist gates the receiver on pull (W2).
            guard let kind = SyncAssetPaths.kind(forRelativePath: relativePath) else { return }
            // Resolve against the pinned bound-UID root (mirrors DiskVersionReader),
            // never the live appRoot, so an in-flight push after an account switch can
            // never read another UID's disk.
            let root = FilePaths.userRoot(uid: binding.firebaseUID)
            let fileURL = root.appendingPathComponent(relativePath)
            let fm = FileManager.default
            guard fm.fileExists(atPath: fileURL.path) else { return }  // already deleted → nothing to push
            guard let data = try? Data(contentsOf: fileURL) else { return }
            let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
            let record = SyncAssetRecord(
                recordName: CloudKitSchema.assetRecordName(jobId: jobId, relativePath: relativePath),
                jobId: jobId, relativePath: relativePath, kind: kind,
                modifiedAt: mtime, schemaVersion: CloudKitSchema.schemaVersion, payload: data)
            // A synced asset that was deleted-then-recreated must win: clear any stale
            // asset tombstone first so a later pull doesn't re-delete this fresh copy.
            try await database.clearAssetTombstone(key: "\(jobId.uuidString)/\(relativePath)", inZone: binding.zoneName)
            try await database.saveAsset(record, inZone: binding.zoneName)

        case .mediaDeleted(let jobId, let relativePath):
            // Record-then-delete (mirrors versionDeleted): the tombstone is what stops a
            // stale device from re-pushing/resurrecting the asset; retry is idempotent.
            let key = "\(jobId.uuidString)/\(relativePath)"
            try await database.recordAssetTombstone(key: key, inZone: binding.zoneName)
            try await database.delete(recordName: CloudKitSchema.assetRecordName(jobId: jobId, relativePath: relativePath), inZone: binding.zoneName)
        }
    }

    private func setState(_ status: SyncStatus, binding: SyncBinding?) {
        lock.withLock {
            _status = status
            activeBinding = binding
        }
    }
}
