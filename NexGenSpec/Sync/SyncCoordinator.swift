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
    /// Optional cloud-port factory. Injected (non-nil) so tests substitute a fake
    /// port with no CloudKit. nil ⇒ the production CloudKit port, built lazily in
    /// `buildCloudPort()` once `store` is wired.
    private let makeCloudPortOverride: (() -> SyncPort)?

    init(
        isEnabled: @escaping () -> Bool = { SyncFeature.effectiveSyncAllowed },
        makeCloudPort: (() -> SyncPort)? = nil
    ) {
        self.isEnabled = isEnabled
        self.makeCloudPortOverride = makeCloudPort
    }

    /// Constructs the active cloud port: the injected fake when provided, otherwise
    /// the real CloudKit port wired with the live two-way backends (slice 4c) — the
    /// device-verified `CKZoneFetcher` to pull and an InspectionStore-backed writer
    /// to apply pulled changes locally.
    private func buildCloudPort() -> SyncPort {
        if let makeCloudPortOverride { return makeCloudPortOverride() }
        return CloudKitSyncPort(
            account: CKAccountProvider(),
            database: CKCloudDatabase(),
            fetcher: CKZoneFetcher(),
            writer: InspectionStoreVersionWriter(store: store)
        )
    }

    /// Begin observing iCloud account changes. Call once after construction.
    func start() {
        guard accountObserver == nil else { return }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebind() }
        }
    }

    /// Called from the identity seam when the signed-in Firebase UID changes
    /// (login / logout / account switch). nil ⇒ signed out.
    func userDidChange(uid: String?) {
        currentUID = uid
        rebind()
    }

    /// Forward a local mutation to the active port (no-op when not bound).
    func recordLocalChange(_ change: SyncChange) {
        port.recordLocalChange(change)
    }

    /// Pull remote changes now — e.g. when the app returns to the foreground, so a
    /// device that was backgrounded while another device edited catches up without
    /// a relaunch. Inert with sync off: the active port is then a `NoopSyncPort`
    /// whose `pull()` does nothing. Cross-device pulls also run on each bind.
    func pullNow() {
        let active = port
        Task { @MainActor in await active.pull() }
    }

    /// Re-evaluate which port should be active and (re)bind. Port SELECTION is
    /// synchronous; the bind itself runs async. Disabled/no-user ⇒ detach to Noop.
    private func rebind() {
        guard isEnabled(), let uid = currentUID else {
            port.unbind()
            port = NoopSyncPort()
            status = .off
            return
        }
        // Always detach the old port and bind a FRESH one to the current UID, so
        // no prior account's binding or queued changes can cross into this UID's
        // zone during the bind's await window (cross-account isolation — review
        // finding). unbind() clears the old port's activeBinding + pending.
        port.unbind()
        let active = buildCloudPort()
        port = active
        Task { @MainActor in
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
