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

    private let lock = NSLock()
    private var _status: SyncStatus = .off
    private var activeBinding: SyncBinding?
    private var pending: [SyncChange] = []

    init(
        account: CloudAccountProviding,
        database: CloudDatabase,
        reader: LocalVersionReader = DiskVersionReader(),
        bindings: BindingStoring = KeychainBindingStore()
    ) {
        self.account = account
        self.database = database
        self.reader = reader
        self.bindings = bindings
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
        // already seeded).
        await seedIfNeeded(firebaseUID: firebaseUID)
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
            do {
                let record = InspectionRecordMapper.make(meta: snapshot.meta, payload: snapshot.payload)
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

    /// Drains pending changes and pushes each. No-op when not bound (local-only /
    /// paused / refused) — the local store remains the source of truth and a later
    /// bind re-seeds. Exposed (non-private) so tests can flush deterministically.
    func flushPending() async {
        let (binding, changes): (SyncBinding?, [SyncChange]) = lock.withLock {
            let drained = pending
            pending.removeAll()
            return (activeBinding, drained)
        }
        guard let binding, !changes.isEmpty else { return }
        lock.withLock { _status = .syncing }

        var hadError = false
        for change in changes {
            do {
                try await apply(change, binding: binding)
            } catch {
                hadError = true
                Diagnostics.logError(context: "CloudKitSyncPort push failed", error: error)
            }
        }

        lock.withLock {
            // Only settle status if this binding is still the active one (not torn
            // down by an unbind/refuse that raced the push).
            if activeBinding?.zoneName == binding.zoneName {
                _status = hadError ? .error("Some changes couldn't be uploaded; will retry.") : .idle
            }
        }
    }

    private func apply(_ change: SyncChange, binding: SyncBinding) async throws {
        switch change {
        case .versionUpserted(let meta):
            guard let data = reader.versionData(forVersionId: meta.id) else { return }
            let record = InspectionRecordMapper.make(meta: meta, payload: data)
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
