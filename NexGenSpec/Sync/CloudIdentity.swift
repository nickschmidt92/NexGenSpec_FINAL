//
//  CloudIdentity.swift
//  NexGenSpec
//
//  Derives the opaque cloud-user token used by the identity binding (landmine 1).
//  CloudKit exposes a stable per-container user record (CKContainer.userRecordID
//  .recordName); we hash it so the binding can detect "same iCloud user vs a
//  different one" WITHOUT ever persisting the Apple ID. The token derivation is
//  pure (unit-testable); fetching the raw record name from CloudKit is the live
//  port's job (slice 2b). See docs/design/build-22-cloudkit-sync.md §2.
//

import Foundation

enum CloudIdentity {

    /// Opaque, stable token for the bound iCloud user. Equal tokens ⇒ same iCloud
    /// user; any change ⇒ refuse-and-isolate (see `SyncIdentityResolver`).
    static func token(forUserRecordName recordName: String) -> String {
        CloudKitSchema.sha256Hex(recordName)
    }
}
