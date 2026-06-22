//
//  InspectionStoreVersionWriter.swift
//  NexGenSpec
//
//  The live LocalVersionWriter (build 22, slice 4c). Bridges remote (synced-in)
//  versions into the local-first InspectionStore on the main actor, relying on the
//  store's `isApplyingRemote` flag to suppress the push-back loop. Carries NO
//  CloudKit dependency — it only decodes the version payload the port already
//  pulled and hands it to the store. The apply-vs-keep-local decision was already
//  made upstream by `CloudKitSyncPort.pull()` via `SyncConflictResolver`; this
//  writer only performs the approved apply. See docs/design/build-22-cloudkit-sync.md §8.
//

import Foundation

final class InspectionStoreVersionWriter: LocalVersionWriter, @unchecked Sendable {

    /// Weak: the writer never owns the @MainActor store (which lives for the app's
    /// lifetime as an `@StateObject`). A nil store — sync torn down — makes every
    /// apply a safe no-op. Set once at init; only ever read.
    private weak var store: InspectionStore?

    init(store: InspectionStore?) {
        self.store = store
    }

    func applyRemoteVersion(_ payload: Data) async -> Bool {
        guard let version = try? JSONDecoder().decode(InspectionVersion.self, from: payload) else {
            // A payload we authored ourselves should always decode; a failure here
            // is a real (not silently-swallowed) problem worth surfacing. This is a
            // device-only path — never exercised by the fake-backed unit tests, so
            // the Crashlytics sink is always configured when it can run. Return true
            // (not false): the bytes are PERMANENTLY undecodable, so retrying the
            // same window forever would only wedge sync — skip past it instead.
            Diagnostics.logError(context: "InspectionStoreVersionWriter: undecodable remote version payload; skipped")
            return true
        }
        // No store (sync detached mid-pull) ⇒ nothing to apply; don't wedge the token.
        guard let store = self.store else { return true }
        return await MainActor.run { store.applyRemoteVersion(version) }
    }

    func deleteLocalVersion(recordName: String) async -> Bool {
        // Not a version record name (e.g. a later slice's ReportPDF) ⇒ nothing to do.
        guard let id = UUID(uuidString: recordName) else { return true }
        guard let store = self.store else { return true }
        return await MainActor.run { store.applyRemoteDelete(id: id) }
    }
}
