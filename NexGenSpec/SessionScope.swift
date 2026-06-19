//
//  SessionScope.swift
//  NexGenSpec
//
//  Per-user storage namespacing for the local working store (B-0096).
//
//  The local-first store used to live at a single fixed root
//  (`Application Support/NexGenSpec/`) shared by every account on the device.
//  Logging out of account A and into account B on the SAME device therefore let
//  B read A's inspections, photos and client PII (B-0096). The fix gives every
//  Firebase account its own subtree under `…/NexGenSpec/Users/<uid>/`; this type
//  resolves which segment is active.
//

import Foundation
import FirebaseCore
import FirebaseAuth

enum SessionScope {

    /// Directory segment used when no user is signed in. The store is empty while
    /// signed out, so nothing sensitive is written here, but routing signed-out
    /// access to its own segment guarantees we never read or write the shared
    /// legacy root (reserved for one-time migration) or another user's namespace.
    static let signedOutSegment = "_nobody"

    /// UserDefaults key holding a UID pinned across an account-deletion wipe.
    private static let pinnedUIDKey = "ngs.session.pinnedUID"

    /// Resolves the active Firebase UID. Overridable in tests (which never
    /// configure Firebase). Production reads the LIVE Firebase user so the value
    /// is correct the instant any path is computed — Firebase restores
    /// `currentUser` synchronously during `configure()`, which runs in
    /// `NexGenSpecApp.init()` before the store loads. Guards on
    /// `FirebaseApp.app()` so a call before/without configuration (unit tests,
    /// previews) returns nil instead of trapping in `Auth.auth()`.
    static var uidProvider: () -> String? = {
        guard FirebaseApp.app() != nil else { return nil }
        return Auth.auth().currentUser?.uid
    }

    /// The live signed-in UID (ignores any deletion pin), or nil when signed out.
    static var activeUID: String? { uidProvider() }

    /// A UID pinned across an account-deletion wipe so that every `appRoot`-derived
    /// path keeps resolving to the DELETING user's namespace even after Firebase
    /// has cleared `currentUser`. Persisted in UserDefaults so it also survives a
    /// force-quit relaunch mid-deletion (the `deletion-pending-wipe` recovery
    /// path in `NexGenSpecApp` relies on it to wipe the right namespace). Cleared
    /// by `unpin()` once the wipe completes.
    static var pinnedUID: String? {
        UserDefaults.standard.string(forKey: pinnedUIDKey)
    }

    static func pin(_ uid: String) {
        UserDefaults.standard.set(uid, forKey: pinnedUIDKey)
    }

    static func unpin() {
        UserDefaults.standard.removeObject(forKey: pinnedUIDKey)
    }

    /// Active namespace segment: a pinned deletion target wins (so the wipe hits
    /// the deleted user's data), else the live Firebase UID, else the signed-out
    /// sentinel. In normal use `pinnedUID` is nil and this is just the live UID.
    static var currentSegment: String {
        pinnedUID ?? activeUID ?? signedOutSegment
    }
}
