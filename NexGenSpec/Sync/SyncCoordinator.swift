//
//  SyncCoordinator.swift
//  NexGenSpec
//
//  Owns the active SyncPort and decides Noop-vs-CloudKit (build 22, slice 2c).
//  Hooked from the identity seam (NexGenSpecApp `onChange(currentUID)`) and a
//  CKAccountStatus observer. With the feature flag OFF — its default — this
//  always holds a NoopSyncPort, so `recordLocalChange` is a no-op and the app is
//  behaviorally identical to build 21. The real CloudKit port is constructed
//  lazily ONLY when sync is enabled. See docs/design/build-22-cloudkit-sync.md §5.
//

import Foundation
import Combine

@MainActor
final class SyncCoordinator: ObservableObject {

    @Published private(set) var status: SyncStatus = .off

    /// Weak handle to the live coordinator so decoupled services (PhotoLoadService,
    /// FilesAppPublisher, LiDARScanStore, capture bridge, …) can record media-file
    /// changes without threading a store reference through every call site. Set once
    /// at app wiring; survives port rebinds (the coordinator instance is stable, only
    /// the underlying port swaps).
    @MainActor static weak var active: SyncCoordinator?

    /// The active port. NoopSyncPort whenever sync is disabled / no user.
    private var port: SyncPort = NoopSyncPort()
    private var currentUID: String?
    private var accountObserver: NSObjectProtocol?

    /// The local-first store, set by NexGenSpecApp. The CloudKit port's
    /// LocalVersionWriter applies pulled remote changes through it (slice 4c). Weak:
    /// the app owns the store as an `@StateObject`; the coordinator only observes.
    weak var store: InspectionStore?

    /// Whether sync may run at all (flag + local-only). Injected for testability.
    private let isEnabled: () -> Bool
    /// Resolves the current iCloud user token — used ONLY to tell a benign same-account
    /// `.CKAccountChanged` (token refresh / re-auth) from a real account switch, so a
    /// spurious notification doesn't tear down the live port and drop its queued
    /// outbound edits (NEW-1). Injected for testability.
    private let account: CloudAccountProviding
    /// The iCloud token the live port is bound to (nil ⇒ Noop / no bound user). Set by
    /// `rebind()` after a (re)bind; compared in `handleAccountChange()`.
    private var boundCloudToken: String?
    /// Optional cloud-port factory. Injected (non-nil) so tests substitute a fake
    /// port with no CloudKit. nil ⇒ the production CloudKit port, built lazily in
    /// `buildCloudPort()` once `store` is wired.
    private let makeCloudPortOverride: (() -> SyncPort)?

    init(
        isEnabled: @escaping () -> Bool = { SyncFeature.effectiveSyncAllowed },
        account: CloudAccountProviding = CKAccountProvider(),
        makeCloudPort: (() -> SyncPort)? = nil
    ) {
        self.isEnabled = isEnabled
        self.account = account
        self.makeCloudPortOverride = makeCloudPort
    }

    /// In-flight bind task for the active port, retained so a racing rebind can
    /// cancel it before swapping ports — otherwise a stale port's suspended
    /// seed/pull could resume after an account switch and cross data between UIDs
    /// (build 22 fix B / landmine 1).
    private var bindTask: Task<Void, Never>?

    /// Constructs the active cloud port: the injected fake when provided, otherwise
    /// the real CloudKit port wired with the live two-way backends (slice 4c) — the
    /// device-verified `CKZoneFetcher` to pull and an InspectionStore-backed writer
    /// to apply pulled changes locally. The reader and writer are PINNED to `uid`'s
    /// per-UID store root (fix B) so a captured binding can never touch another
    /// UID's disk after an account switch re-points the live `appRoot`.
    private func buildCloudPort(uid: String) -> SyncPort {
        if let makeCloudPortOverride { return makeCloudPortOverride() }
        return CloudKitSyncPort(
            account: CKAccountProvider(),
            database: CKCloudDatabase(),
            reader: DiskVersionReader(uid: uid),
            fetcher: CKZoneFetcher(),
            writer: InspectionStoreVersionWriter(store: store, boundUID: uid)
        )
    }

    /// Begin observing iCloud account changes. Call once after construction.
    func start() {
        guard accountObserver == nil else { return }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.handleAccountChange() }
        }
        // Cold-launch sweep (fix C): retry any account-deletion zone teardowns a prior
        // run couldn't finish. Independent of the deletion pin; a no-op when sync is off
        // or nothing is owed (a fast Keychain check before any CloudKit call).
        Task { await Self.runTeardownSweep() }
    }

    /// Retries owed account-deletion zone teardowns at launch (fix C). Static + builds
    /// its own CloudKit backends so it never touches the live port's state.
    private static func runTeardownSweep() async {
        guard SyncFeature.isEnabled else { return }
        await SyncTeardownSweep.run(
            database: CKCloudDatabase(),
            account: CKAccountProvider(),
            owed: KeychainTeardownOwedStore(),
            isEnabled: true
        )
    }

    /// Entry point for a `.CKAccountChanged` notification. Apple posts this on benign
    /// SAME-account events (token refresh / re-auth), not just real switches. A naive
    /// `rebind()` on every notification tears down the live port — and `unbind()`
    /// clears the un-pushed `pending` queue, which `seedIfNeeded` won't re-enqueue
    /// (one-shot) — so a queued outbound edit would be silently dropped: cross-device
    /// push divergence (NEW-1). Gate it: only a GENUINE iCloud identity change (the
    /// token actually changed) tears down + rebuilds (cross-account isolation); an
    /// unchanged token keeps the live port + its queue and just re-drives a pull/flush.
    /// Internal (not private) so it is unit-testable without posting a real
    /// NotificationCenter event.
    func handleAccountChange() async {
        // Not bound / sync off ⇒ fall through to rebind (which detaches to Noop).
        guard isEnabled(), currentUID != nil else { rebind(); return }
        // Wait for any in-flight bind to finish publishing `boundCloudToken` before
        // comparing. A `.CKAccountChanged` arriving in the bind→token window would
        // otherwise compare a real token against a still-nil `boundCloudToken`,
        // spuriously rebuild, and DROP the un-pushed queue — the exact NEW-1 bug,
        // narrowed but not closed. (bindTask is nil when no bind is in flight.)
        await bindTask?.value
        let token = await account.currentUserToken()
        if token == boundCloudToken {
            // Same iCloud identity → keep the live port and its pending queue intact;
            // re-drive a pull + flush (pullNow awaits pull then flushPending) so a token
            // refresh still catches up.
            pullNow()
            return
        }
        // The iCloud account genuinely changed → full rebind: tear down (clearing the
        // queue), and bind fresh / refuse-and-isolate per SyncIdentityResolver.
        rebind()
    }

    /// Called from the identity seam when the signed-in Firebase UID changes
    /// (login / logout / account switch). nil ⇒ signed out.
    func userDidChange(uid: String?) {
        currentUID = uid
        rebind()
    }

    /// Forward a local mutation to the active port (no-op when not bound).
    func recordLocalChange(_ change: SyncChange) {
        let active = port
        active.recordLocalChange(change)
        // `recordLocalChange` kicks its own background flush; that flush can set the
        // port's status to `.error` when an upload fails, but nothing published that
        // back to the @Published `status` the settings UI observes. Await a
        // (serialized, idempotent) flush purely to learn its settled status and
        // reflect it — the port coalesces, so this never double-pushes. Guard on the
        // port identity so a detached port can't clobber a freshly-rebound one's status.
        Task { @MainActor [weak self] in
            await active.flushPending()
            self?.reflectStatus(of: active)
        }
    }

    /// Publish `port`'s current status into the @Published `status`, but only while
    /// `port` is still the active port — so a stale/detached port whose async work
    /// lands after a rebind can't overwrite the new port's status (mirrors the
    /// `port === active` guard in `rebind()`).
    private func reflectStatus(of active: SyncPort) {
        guard port === active else { return }
        status = active.status
    }

    /// Record that a synced media file was written. Main-actor-hopping so services on
    /// any queue/thread can call it after a successful byte write. Inert when sync is
    /// off / no user (the active port is a NoopSyncPort).
    nonisolated static func noteMediaUpserted(jobId: UUID, relativePath: String) {
        Task { @MainActor in active?.recordLocalChange(.mediaUpserted(jobId: jobId, relativePath: relativePath)) }
    }

    /// Record that a synced media file was removed. See `noteMediaUpserted`.
    nonisolated static func noteMediaDeleted(jobId: UUID, relativePath: String) {
        Task { @MainActor in active?.recordLocalChange(.mediaDeleted(jobId: jobId, relativePath: relativePath)) }
    }

    /// Pull remote changes now — e.g. when the app returns to the foreground, so a
    /// device that was backgrounded while another device edited catches up without
    /// a relaunch. Inert with sync off: the active port is then a `NoopSyncPort`
    /// whose `pull()` does nothing. Cross-device pulls also run on each bind.
    func pullNow() {
        let active = port
        Task { @MainActor [weak self] in
            // A live RoomPlan capture owns the main thread; applying pulled
            // records mid-scan causes visible jitter (main-actor applyRemoteVersion
            // + metadata publishes). Defer to a one-shot catch-up pull that fires
            // when the capture ends.
            if LiDARCaptureActivity.shared.isActive {
                LiDARCaptureActivity.shared.setPendingPull { self?.pullNow() }
                return
            }
            await active.pull()
            // Also re-drive any outbound changes queued during a transient unbind
            // window (fix F). Inert on a NoopSyncPort (flag off).
            await active.flushPending()
            // Reflect the pull/flush outcome (e.g. a flush that set `.error`) into the
            // @Published status the settings UI observes — otherwise a live-flush error
            // never reaches the coordinator's status after the one-shot bind publish.
            self?.reflectStatus(of: active)
        }
    }

    /// Tear down a DELETED account's CloudKit footprint (edge G / 5.1.1(v)): drop
    /// its custom zone — removing every record + payload CKAsset from the user's
    /// private iCloud — and delete the local binding. Best-effort and STRICTLY
    /// gated: a strict no-op unless sync is enabled AND a binding exists, so the
    /// flag-OFF shipping build never touches CloudKit. Call from BOTH account-
    /// deletion paths (AppSettingsView.finishLocalWipeAndDismiss and the
    /// NexGenSpecApp interrupted-deletion recovery) BEFORE the local wipe. Never
    /// blocks the wipe — the zone delete runs detached and failures only log.
    func tearDownDeletedAccount(uid: String) {
        // The account is gone — detach the live port so nothing re-binds to the
        // deleted UID. Inert when the flag is off (the port is already a Noop).
        bindTask?.cancel()
        bindTask = nil
        port.unbind()
        port = NoopSyncPort()
        status = .off
        // Flag-OFF ⇒ no CloudKit is ever touched (strict no-op). Gate on the MASTER
        // flag, not effectiveSyncAllowed, so a zone created before the user turned on
        // local-only mode is still torn down. The helper re-checks binding-exists.
        guard SyncFeature.isEnabled else { return }
        let database = CKCloudDatabase()
        let account = CKAccountProvider()
        Task {
            await SyncAccountTeardown.tearDown(
                uid: uid, database: database, account: account, bindings: KeychainBindingStore(),
                owed: KeychainTeardownOwedStore(), isEnabled: true
            )
        }
    }

    /// Re-evaluate which port should be active and (re)bind. Port SELECTION is
    /// synchronous; the bind itself runs async. Disabled/no-user ⇒ detach to Noop.
    private func rebind() {
        guard isEnabled(), let uid = currentUID else {
            bindTask?.cancel()
            bindTask = nil
            port.unbind()
            port = NoopSyncPort()
            boundCloudToken = nil
            status = .off
            return
        }
        // Always detach the old port and bind a FRESH one to the current UID, so
        // no prior account's binding or queued changes can cross into this UID's
        // zone during the bind's await window (cross-account isolation — review
        // finding). Cancel the old port's in-flight bind task FIRST so its suspended
        // seed/pull can't resume against the new UID's disk (fix B), then unbind()
        // clears the old port's activeBinding + pending.
        bindTask?.cancel()
        port.unbind()
        let active = buildCloudPort(uid: uid)
        port = active
        bindTask = Task { @MainActor in
            // Record the iCloud token this port is bound to, so a later
            // `.CKAccountChanged` can tell a benign same-account refresh from a real
            // switch (NEW-1). The port fetches its own copy at bind; approximate
            // consistency is fine for the gate.
            self.boundCloudToken = await self.account.currentUserToken()
            await active.bind(firebaseUID: uid)
            // Only reflect status if this is still the active port.
            if self.port === active { self.status = active.status }
        }
    }

    deinit {
        if let accountObserver {
            NotificationCenter.default.removeObserver(accountObserver)
        }
    }
}

/// Pure, CloudKit-free account-deletion teardown (build 22 fix C / edge G). Kept
/// out of `SyncCoordinator` so it is unit-testable with the in-memory fakes
/// (FakeDatabase / FakeBindings): deleting a bound account drops its CloudKit zone
/// and local binding; an unbound account or a disabled flag is a strict no-op.
enum SyncAccountTeardown {
    static func tearDown(
        uid: String,
        database: CloudDatabase,
        account: CloudAccountProviding,
        bindings: BindingStoring,
        owed: TeardownOwedStoring,
        isEnabled: Bool
    ) async {
        // Strict no-op unless sync is on AND a binding actually exists for this UID.
        guard isEnabled, let binding = bindings.load(forUID: uid) else { return }

        // Best-effort zone delete, ONLY when this device's current iCloud user still
        // OWNS the zone (finding #4): the zone lives in the iCloud account bound at
        // `binding.cloudUserToken`. After an Apple-ID switch — or while iCloud is
        // unavailable (`currentToken == nil`) — deleteZone would target the wrong /
        // another private DB, so we DON'T attempt it; instead we record a teardown-owed
        // marker so the cold-launch sweep retries it later, under the owning account.
        let currentToken = await account.currentUserToken()
        if currentToken == binding.cloudUserToken {
            do {
                try await database.deleteZone(binding.zoneName)
                // Zone is gone — clear any prior owed marker for this UID.
                owed.remove(forUID: uid)
            } catch {
                // Durable retry (fix C): never block the wipe, but record what's owed so
                // a later launch retries the residual zone (no longer logged-and-lost).
                owed.record(SyncTeardownOwed(firebaseUID: uid, zoneName: binding.zoneName, cloudUserToken: binding.cloudUserToken))
                Diagnostics.logError(context: "SyncAccountTeardown.deleteZone failed for \(uid); recorded teardown-owed for the cold-launch sweep", error: error)
            }
        } else {
            // Not reachable from the current iCloud user — record it owed so the sweep
            // retries when the owning account returns (never deleteZone the wrong DB).
            owed.record(SyncTeardownOwed(firebaseUID: uid, zoneName: binding.zoneName, cloudUserToken: binding.cloudUserToken))
            Diagnostics.logError(
                context: "SyncAccountTeardown: zone for \(uid) not reachable from the current iCloud user (account changed or unavailable); recorded teardown-owed for retry",
                persistToDisk: false
            )
        }
        // Drop the local binding (never blocks the wipe). Any residual zone is now
        // tracked by the teardown-owed marker above and retried by SyncTeardownSweep at
        // the next launch — INDEPENDENT of the deletion pin (which a normal completed
        // deletion clears, so the old recovery path couldn't re-fire). This closes the
        // round-3 KNOWN LIMITATION (fix C). See build-22-p6-remediation.md.
        bindings.delete(forUID: uid)
    }
}
