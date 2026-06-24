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
        var allApplied = true

        for remote in changes.changed {
            guard let versionId = UUID(uuidString: remote.record.recordName) else { continue }
            let local = reader.localState(forVersionId: versionId)
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
            if SyncConflictResolver.resolveDelete(local: reader.localState(forVersionId: versionId)) == .deleteLocal {
                if Task.isCancelled { return }
                let stillBound = lock.withLock { activeBinding?.zoneName == binding.zoneName }
                guard stillBound else { return }
                if await writer.deleteLocalVersion(recordName: recordName) == false { allApplied = false }
            }
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
                try await apply(change, binding: binding)
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

    private func apply(_ change: SyncChange, binding: SyncBinding) async throws {
        switch change {
        case .versionUpserted(let meta):
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
            try await database.delete(recordName: versionId.uuidString, inZone: binding.zoneName)
        case .mediaUpserted, .mediaDeleted:
            break // JSON-only push in this slice; raw media is a later slice
        }
    }

    private func setState(_ status: SyncStatus, binding: SyncBinding?) {
        lock.withLock {
            _status = status
            activeBinding = binding
        }
    }
}
