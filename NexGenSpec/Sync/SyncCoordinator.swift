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

    /// Whether sync may run at all (flag + local-only). Injected for testability.
    private let isEnabled: () -> Bool
    /// Builds the live CloudKit port. Injected so tests use a fake (no CloudKit).
    private let makeCloudPort: () -> SyncPort

    init(
        isEnabled: @escaping () -> Bool = { SyncFeature.effectiveSyncAllowed },
        makeCloudPort: @escaping () -> SyncPort = {
            CloudKitSyncPort(account: CKAccountProvider(), database: CKCloudDatabase())
        }
    ) {
        self.isEnabled = isEnabled
        self.makeCloudPort = makeCloudPort
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
        let active = makeCloudPort()
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
