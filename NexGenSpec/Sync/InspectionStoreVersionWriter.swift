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

    /// The Firebase UID this writer was bound to at sync-bind time, passed through to
    /// the store's apply so the cross-account guard runs ATOMICALLY on the MainActor
    /// with the disk write (build 22 fix B / landmine 1). Doing the check here (off
    /// the MainActor) before the `MainActor.run` hop had a real TOCTOU gap — an A→B
    /// switch in the gap would still let the live-appRoot write land in B's store —
    /// so the authoritative guard lives in `InspectionStore.applyRemote*`. nil ⇒ no
    /// pinning (back-compat for any non-bound construction).
    private let boundUID: String?

    init(store: InspectionStore?, boundUID: String? = nil) {
        self.store = store
        self.boundUID = boundUID
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
        // The cross-account guard runs inside applyRemoteVersion (atomic with the write).
        return await MainActor.run { store.applyRemoteVersion(version, expectedUID: boundUID) }
    }

    func deleteLocalVersion(recordName: String) async -> Bool {
        // Not a version record name (e.g. a later slice's ReportPDF) ⇒ nothing to do.
        guard let id = UUID(uuidString: recordName) else { return true }
        guard let store = self.store else { return true }
        return await MainActor.run { store.applyRemoteDelete(id: id, expectedUID: boundUID) }
    }

    // MARK: - Asset sync (D-0203)

    func applyRemoteAsset(_ record: SyncAssetRecord) async -> Bool {
        // Defense-in-depth: re-validate the path on the RECEIVER and confirm the
        // declared kind matches; a foreign/excluded/traversal path is a safe skip
        // (never a token-holding failure).
        guard SyncAssetPaths.kind(forRelativePath: record.relativePath) == record.kind else { return true }
        // Cross-account safety: assets don't route through InspectionStore, so the
        // guard here is (a) the writer's pinned bound-UID root and (b) an explicit
        // active-segment check that mirrors InspectionStore.applyRemoteVersion's
        // intent — on a mismatch, hold (safe no-op) rather than write into another
        // UID's disk after an A→B switch. Unpinned construction (boundUID nil) skips
        // the segment check for back-compat, matching the version writer.
        if let boundUID, await MainActor.run(body: { SessionScope.currentSegment }) != boundUID {
            Diagnostics.logError(context: "applyRemoteAsset: refused cross-account write (bound=\(boundUID)); holding")
            return true
        }
        let root = FilePaths.userRoot(uid: boundUID ?? SessionScope.currentSegment)
        let dest = root.appendingPathComponent(record.relativePath)
        let fm = FileManager.default
        // LWW: if a local file exists and is newer-or-equal, keep it (a local
        // re-export/regeneration wins over an older remote copy — no clobber/flicker).
        // `record.modifiedAt` is the CloudKit SERVER modificationDate on the pull path
        // (D-0203 review), so the remote comparand is a single authoritative clock
        // rather than the pushing device's skewed client mtime. (The receiver's own
        // local file mtime remains device-local; fully server-domain comparison would
        // require restamping received files to the server date — deferred as it would
        // shift mtime-derived UI such as My Reports' report dates.)
        if let attrs = try? fm.attributesOfItem(atPath: dest.path),
           let localMtime = attrs[.modificationDate] as? Date,
           localMtime >= record.modifiedAt {
            return true
        }
        do {
            try FileSecurity.writeProtected(record.payload, to: dest)
            Self.notifyApplied(record)
            return true
        } catch {
            Diagnostics.logError(context: "applyRemoteAsset write failed \(record.relativePath)", error: error)
            return false   // transient → hold token, retry next pull
        }
    }

    /// Kind-specific UI/store notification after a synced-in asset lands on disk
    /// (sync data completeness pass). Most asset kinds are read lazily at render
    /// time and need nothing; the two below back LIVE UI state:
    /// - sideState: invalidate the side-state cache + re-derive badges/lists.
    /// - coverPhoto: the dashboard thumbnail cache and the Overview cover view
    ///   listen for `.coverPhotoDidUpdate` (same signal a local cover write posts),
    ///   which also releases the receiver's cover placeholder.
    private static func notifyApplied(_ record: SyncAssetRecord) {
        switch record.kind {
        case .sideState:
            InspectionSideStateStore.shared.noteRemoteChange(inspectionId: record.jobId.uuidString)
        case .coverPhoto:
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .coverPhotoDidUpdate,
                    object: nil,
                    userInfo: ["jobId": record.jobId]
                )
            }
        default:
            break
        }
    }

    func deleteLocalAsset(jobId: UUID, relativePath: String) async -> Bool {
        guard SyncAssetPaths.kind(forRelativePath: relativePath) != nil else { return true }
        if let boundUID, await MainActor.run(body: { SessionScope.currentSegment }) != boundUID {
            Diagnostics.logError(context: "deleteLocalAsset: refused cross-account delete (bound=\(boundUID)); holding")
            return true
        }
        let root = FilePaths.userRoot(uid: boundUID ?? SessionScope.currentSegment)
        let dest = root.appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: dest)   // absent = success (idempotent)
        return true
    }
}
