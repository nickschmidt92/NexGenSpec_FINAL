//
//  InspectionStore.swift
//  NexGenSpec
//

import Foundation
import Combine
import UIKit

@MainActor
public final class InspectionStore: ObservableObject {

    /// Lightweight list for dashboard. Full version loaded via loadFullVersion(id).
    @Published public private(set) var metadataList: [VersionMetadata] = []
    @Published public private(set) var saveError: String?
    @Published public private(set) var loadError: String?
    @Published public private(set) var lastSavedAt: Date?
    @Published public private(set) var isSaving = false
    /// True when the inspection template failed to load (e.g. missing JSON). Create inspection will no-op.
    /// Accessing this lazily loads the template (see `heavyTemplate`).
    public var templateLoadFailed: Bool { heavyTemplate == nil }

    /// The ~115 KB bundled inspection template, parsed lazily on first use.
    /// It is only needed when *creating* an inspection, so parsing it in
    /// `init()` taxed every cold launch with a synchronous main-thread JSON
    /// decode for no reason. Backed by `heavyTemplateCache` + a loaded flag so
    /// a parse failure (nil) is cached too and not retried on every access.
    private var heavyTemplateCache: HeavyTemplate?
    private var heavyTemplateLoaded = false
    private var heavyTemplate: HeavyTemplate? {
        if !heavyTemplateLoaded {
            heavyTemplateLoaded = true
            heavyTemplateCache = Self.loadHeavyTemplateFromBundle()
        }
        return heavyTemplateCache
    }
    /// COMPUTED, never stored: the index path must follow the active user's
    /// per-UID `appRoot` (B-0096). A stored `let` here froze the path to whatever
    /// segment was active when the store was constructed (at launch = signed-out
    /// `_nobody`), so after login every account read the SAME index file and saw
    /// each other's inspections — the on-device cross-account leak. Computed, it
    /// resolves to the current user's index on every read/write.
    private var indexURL: URL { FilePaths.inspectionsIndex }
    /// Gates index writes after a failed load so a bad load can never overwrite a
    /// good primary/backup with an empty in-memory list. See `load()` (B-0044).
    private var didLoadSucceed = true
    private var saveWorkItem: DispatchWorkItem?
    private let saveDebounceInterval: DispatchTimeInterval = .milliseconds(400)
    private let ioQueue = DispatchQueue(label: "com.nexgenspec.inspectionstore.io")

    /// Build 22 sync seam: the local-first store stays the source of truth and
    /// forwards each successful version write/delete to the CloudKit mirror. nil
    /// (or a flag-OFF SyncCoordinator holding a NoopSyncPort) ⇒ no sync ⇒
    /// behavior identical to build 21. Set by NexGenSpecApp.
    weak var syncCoordinator: SyncCoordinator?

    /// Product default (sync data completeness, Item 4 — pending Nick's final
    /// confirmation): after a SUCCESSFUL finalize, auto-generate the report PDF
    /// and publish it through `FilesAppPublisher` — the same machinery the manual
    /// Export / Send flow uses — so a ReportPDF sync record reaches the user's
    /// other devices with no manual export step. Single toggle: set false to
    /// restore manual-only publishing.
    public static var autoPublishReportPDFOnFinalize = true

    /// Test seam for the finalize auto-publish: when set, it REPLACES the default
    /// export+publish and is invoked exactly once per SUCCESSFUL finalize with the
    /// finalized (locked) version — never on an aborted/failed finalize.
    var finalizeAutoPublishHook: ((InspectionVersion) -> Void)?

    /// Watermark decision for the auto-published PDF, wired by NexGenSpecApp to
    /// the live SubscriptionManager (`{ !subscriptions.hasFeatureAccess }`) so it
    /// matches the manual Export/Send flow. Defaults to watermark-on when unset
    /// (free-tier-safe: never leaks a clean deliverable).
    var autoPublishWatermarkProvider: (() -> Bool)?

    /// True from the moment a Delete-Account wipe begins (`beginWipe()`) until
    /// the off-main disk wipe finishes (`performDiskWipe()`). While set, every
    /// disk-write path (`save`, `writeVersionToFile`, `writeVersionFileOnlyForAutoSave`)
    /// no-ops so nothing can re-create the directory being deleted mid-wipe.
    public private(set) var isWiping = false

    /// True only while a synced-in remote version/delete is being applied to the
    /// local store (`applyRemoteVersion` / `applyRemoteDelete`, build 22 slice 4c).
    /// While set, the local write paths do NOT (a) re-stamp `updatedAt` — the
    /// remote's edit time is authoritative — nor (b) emit a `recordLocalChange`,
    /// which would otherwise push the just-applied remote change straight back to
    /// CloudKit and loop (apply→push→apply). Mirrors the `isWiping` gating pattern.
    /// Set/cleared synchronously on the main actor, so there is no flag race.
    public private(set) var isApplyingRemote = false

    /// Finalize metadata updates staged by `finalize(version:)` but NOT yet
    /// published into `metadataList`. Deliberately a plain (non-`@Published`)
    /// property: publishing the finalized row immediately re-renders the
    /// Dashboard/Calendar/Archived `ForEach` that listed this inspection, which
    /// tears the pushed `InspectionView` off the navigation stack and pops the
    /// user back to the list — the finalize→Invoice "bounce to Workspace" bug.
    /// The version file + integrity snapshot are written to disk synchronously
    /// in `finalize`, and `saveMetadataIndex()` folds these staged entries into
    /// the on-disk index, so disk is always correct. The in-memory published
    /// list is reconciled by `flushPendingMetadata()` once the user returns to a
    /// list screen (never while the inspection is on screen). Keyed by versionID.
    private var pendingFinalizedMetadata: [UUID: VersionMetadata] = [:]

    public init() {
        load()
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveWorkItem?.cancel()
                self?.saveWorkItem = nil
                self?.save()
            }
        }
    }

    private static func loadHeavyTemplateFromBundle() -> HeavyTemplate? {
        let name = "InspectionTemplate"
        if let url = Bundle.main.url(forResource: name, withExtension: "json")
            ?? Bundle(for: Self.self).url(forResource: name, withExtension: "json") {
            return HeavyTemplateImporter.load(from: url)
        }
        return InspectionStore.fallbackTemplate
    }

    /// Discriminates a missing index file from one that exists but could not be
    /// READ (e.g. a `.completeUnlessOpen`-protected file while the device is
    /// locked at launch). Collapsing these into one `nil` is what let a transient
    /// locked-file launch masquerade as corruption and trigger a destructive
    /// overwrite (B-0044).
    private enum IndexFileRead {
        case missing
        case unreadable
        case data(Data)
    }

    private nonisolated static func readIndexFile(_ url: URL) -> IndexFileRead {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return .data(data)
    }

    /// Outcome of rebuilding the index from the per-inspection `current.json`
    /// source-of-truth files. `.incomplete` means at least one `current.json`
    /// existed but could not be read/decoded, so the scan is NOT authoritative
    /// and must never be persisted (it would silently drop those inspections).
    private enum RebuildResult {
        case rebuilt([VersionMetadata])
        case empty
        case incomplete
    }

    private func load() {
        // Never load while an account-deletion wipe is in flight. The new
        // onChange(currentUID→nil) during deletion would otherwise reload from
        // the (pinned, being-wiped) namespace and repopulate metadataList — or
        // its rebuild/backup branches could re-write inspections.json into the
        // namespace being deleted (residual PII). beginWipe() already emptied the
        // list; keep it empty until the wipe completes. (audit hardening)
        guard !isWiping else { return }
        loadError = nil
        // Reset the gate every load so a later healthy launch — or a restored
        // backup via reloadFromDisk() — re-enables index writes automatically.
        didLoadSucceed = true
        // The on-disk index already reflects any staged finalize updates
        // (saveMetadataIndex folds them in), so a fresh load is authoritative
        // and any pending staging is moot. Clear it so a reload can't later
        // re-apply a stale finalized snapshot over freshly-loaded data.
        pendingFinalizedMetadata.removeAll()

        // Resolve the per-UID paths ON the main actor (indexURL is now computed
        // from the active user's appRoot) so the getter isn't re-evaluated on the
        // ioQueue thread.
        let primaryIndexURL = indexURL
        let backupIndexURL = FilePaths.inspectionsIndexBackup
        let (primaryRead, backupRead): (IndexFileRead, IndexFileRead) = ioQueue.sync {
            (Self.readIndexFile(primaryIndexURL), Self.readIndexFile(backupIndexURL))
        }

        // Clean first launch: neither index nor backup exists.
        if case .missing = primaryRead, case .missing = backupRead {
            metadataList = []
            return
        }

        // Healthy path: the primary decodes. Byte-for-byte the prior behaviour.
        if case .data(let primaryData) = primaryRead, applyDecodedIndex(primaryData) {
            return
        }

        // Primary missing or undecodable: fall back to the backup, and if it
        // decodes, rewrite a fresh primary from the recovered list.
        if case .data(let backupData) = backupRead, applyDecodedIndex(backupData) {
            try? saveMetadataIndex()
            return
        }

        // Neither candidate decoded. Distinguish a transient unreadable file
        // (locked at launch) from real corruption: only a file that READ
        // successfully but failed to DECODE is corruption.
        let primaryReadable: Bool = { if case .data = primaryRead { return true } else { return false } }()
        let backupReadable: Bool = { if case .data = backupRead { return true } else { return false } }()

        if !primaryReadable && !backupReadable {
            // A file exists but could not be read. Treat as temporary: do NOT
            // rebuild, do NOT touch disk. Close the write-gate so a backgrounding
            // save can't overwrite the (intact) on-disk index with an empty list;
            // the next launch resets the gate and loads normally.
            metadataList = []
            didLoadSucceed = false
            loadError = "Inspections are temporarily unavailable because the device was locked at launch. Reopen the app after unlocking."
            return
        }

        // Readable-but-undecodable: real corruption. Rebuild from the
        // per-inspection current.json files (the source of truth).
        switch rebuildIndexFromVersionFiles() {
        case .rebuilt(let recovered):
            metadataList = recovered
            didLoadSucceed = true
            loadError = nil
            try? saveMetadataIndex()
        case .empty, .incomplete:
            metadataList = []
            didLoadSucceed = false
            loadError = "Inspection index could not be read and no complete set of inspection files was found to rebuild it. The file may be corrupted; restore a backup before creating new inspections."
        }
    }

    /// Applies a decoded index to `metadataList`, preserving the legacy→current
    /// migration exactly. Returns `false` if the data did not decode.
    @discardableResult
    private func applyDecodedIndex(_ data: Data) -> Bool {
        guard let decoded = Self.decodeIndexData(data) else { return false }
        switch decoded {
        case .metadata(let metadata):
            metadataList = metadata
        case .legacyVersions(let legacy):
            metadataList = legacy.map { VersionMetadata(from: $0) }
            // One-shot build-21→22 migration: write each legacy version to its
            // current.json. Reuse the remote-apply guard so the write PRESERVES
            // each version's own `updatedAt` (we must not stamp a fake migration
            // clock onto legacy data, nor rewrite a finalized legacy record's
            // bytes) AND does not echo a per-file push — bulk legacy data is pushed
            // once by seeding. This keeps the index (built above from the same
            // versions) in agreement with the bytes on disk (review F1 follow-up).
            isApplyingRemote = true
            for v in legacy {
                try? writeVersionToFile(v)
            }
            isApplyingRemote = false
            try? saveMetadataIndex()
        }
        // I-E: one-shot self-heal of legacy finalized reports whose `updatedAt` drifted
        // from their sealed snapshot (runs once; safe — never masks content tampering).
        healLegacyFinalizedHashesIfNeeded()
        return true
    }

    /// One-shot self-healing for legacy (pre-fix-I) finalized reports whose
    /// `current.json.updatedAt` was re-stamped to finalize-time AFTER the integrity
    /// snapshot was sealed over the draft-time value — making `FinalizationService.verify()`
    /// falsely report `.mismatch` (I-E). For each locked report that mismatches, restore
    /// `updatedAt` to the sealed value ONLY IF that makes the model byte-identical to the
    /// originally-sealed one (so genuine content tampering is NEVER masked); the original
    /// seal is preserved. Runs at most once per device — a no-op on a clean install or
    /// after it has run. (For a first public release this only ever touches pre-build-22
    /// dev/TestFlight data; public users never finalized on a pre-fix-I build.)
    private func healLegacyFinalizedHashesIfNeeded() {
        // Per-UID one-shot: each account heals its OWN legacy reports. A device-global
        // key meant only the first account loaded after update got healed — a
        // multi-account / TestFlight gap.
        let key = "ngs.migration.ieReseal.v1.\(SessionScope.currentSegment)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        defer { UserDefaults.standard.set(true, forKey: key) }
        for meta in metadataList where !InspectionStateMachine.allowsEdit(meta.state) {
            guard let full = loadFullVersion(id: meta.id) else { continue }
            let jobId = UUID(uuidString: full.inspection.inspectionId) ?? full.id
            guard FinalizationService.verify(full) == .mismatch,
                  let sealed = FinalizationService.loadSnapshot(jobId: jobId, versionId: full.id),
                  let healed = FinalizationService.legacyHealedVersion(full, against: sealed) else { continue }
            isApplyingRemote = true
            _ = try? writeVersionToFile(healed)
            isApplyingRemote = false
            Diagnostics.logInfo("InspectionStore: healed legacy updatedAt drift for finalized \(meta.id) (I-E)")
        }
    }

    /// Rebuilds the metadata list from `appRoot/Inspections/<id>/current.json`.
    /// Refuses to return a partial list: if any `current.json` exists but can't
    /// be read/decoded the scan is `.incomplete` and the caller must not persist
    /// it (B-0044 review hardening).
    private func rebuildIndexFromVersionFiles() -> RebuildResult {
        let inspectionsRoot = FilePaths.appRoot.appendingPathComponent("Inspections", isDirectory: true)
        return ioQueue.sync {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: inspectionsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return .empty
            }
            var foldersWithCurrentJson = 0
            var recovered: [InspectionVersion] = []
            for folder in entries {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let currentJson = folder.appendingPathComponent("current.json", isDirectory: false)
                guard fm.fileExists(atPath: currentJson.path) else { continue }
                foldersWithCurrentJson += 1
                guard let data = try? Data(contentsOf: currentJson),
                      let version = try? JSONDecoder().decode(InspectionVersion.self, from: data) else {
                    continue
                }
                recovered.append(version)
            }
            if foldersWithCurrentJson == 0 { return .empty }
            if recovered.count < foldersWithCurrentJson { return .incomplete }
            let sorted = recovered.sorted {
                ($0.finalizedAt ?? $0.inspection.inspectionDate) > ($1.finalizedAt ?? $1.inspection.inspectionDate)
            }
            Diagnostics.logInfo("Rebuilt index from \(sorted.count) current.json files (B-0044)")
            return .rebuilt(sorted.map { VersionMetadata(from: $0) })
        }
    }

    /// Reloads the inspection index from disk. Use after resolving load errors
    /// (e.g. restoring backup) and on every account switch (B-0096).
    public func reloadFromDisk() {
        // Cancel any pending debounced save first: it captured the PREVIOUS
        // user's in-memory list, and if it fired after the account switch it
        // would write that list into the new (or signed-out _nobody) namespace.
        // Mirrors beginWipe()'s cancel. (audit hardening)
        saveWorkItem?.cancel()
        saveWorkItem = nil
        load()
    }

    private func save() {
        // No persistence while a wipe is in progress: a save here would
        // re-create appRoot/inspections.json after the wipe (see beginWipe()).
        guard !isWiping else { return }
        saveError = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try saveMetadataIndex()
            lastSavedAt = Date()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func saveMetadataIndex() throws {
        // Refuse to persist while the index is in a failed-load state: writing the
        // in-memory list now would overwrite the good (but unreadable/corrupt)
        // on-disk primary/backup with an empty or partial list (B-0044). Plain
        // return (not throw) so an intentional skip isn't surfaced as a save error.
        guard didLoadSucceed else {
            Diagnostics.logError(
                context: "saveMetadataIndex skipped: index load failed; refusing to overwrite primary/backup with an unverified in-memory list (B-0044)",
                persistToDisk: false
            )
            return
        }
        // Fold any staged finalize updates into the snapshot so the on-disk
        // index reflects the finalized status even though we haven't published
        // it to the in-memory `metadataList` yet (see pendingFinalizedMetadata).
        // This keeps disk authoritative across backgrounding/force-quit while
        // the inspection is still on screen.
        var snapshot = metadataList
        if !pendingFinalizedMetadata.isEmpty {
            for (id, meta) in pendingFinalizedMetadata {
                if let i = snapshot.firstIndex(where: { $0.id == id }) {
                    snapshot[i] = meta
                }
            }
        }
        // Resolve the per-UID paths on the main actor before handing off to the
        // ioQueue, so a single save writes one consistent index path (B-0096).
        let currentIndexURL = indexURL
        let backupIndexURL = FilePaths.inspectionsIndexBackup
        try ioQueue.sync {
            try FileSecurity.ensureProtectedDirectory(currentIndexURL.deletingLastPathComponent())
            // Only copy the existing primary over the backup when it currently
            // DECODES — a corrupt primary must never clobber a still-good backup.
            if let existing = try? Data(contentsOf: currentIndexURL), Self.decodeIndexData(existing) != nil {
                try? FileSecurity.copyProtectedItem(from: currentIndexURL, to: backupIndexURL)
            }
            let index = MetadataIndex(schemaVersion: 1, metadata: snapshot)
            let data = try JSONEncoder().encode(index)
            try FileSecurity.writeProtected(data, to: currentIndexURL)
        }
    }

    /// Writes the version's `current.json` and returns the exact bytes-as-written
    /// version. Callers MUST build their `VersionMetadata` from the returned value
    /// (not the argument) so the published `metadataList` + on-disk index agree with
    /// `current.json` on `updatedAt` (the LWW clock) — otherwise the index would
    /// carry a stale/nil clock while disk carries the fresh stamp (review F1).
    @discardableResult
    private func writeVersionToFile(_ version: InspectionVersion) throws -> InspectionVersion {
        guard !isWiping else { return version }
        var toWrite = version
        // Stamp the last-writer-wins clock on genuine LOCAL DRAFT writes only.
        //  - Applying a synced-in remote version PRESERVES its `updatedAt` (its
        //    origin edit time); re-stamping it with the local pull time would break
        //    draft conflict arbitration (build 22 slice 4c).
        //  - A LOCKED (finalized) version is never re-stamped either (build 22 fix
        //    I): finalize hashes the version's snapshot, so re-stamping `updatedAt`
        //    afterward would make `current.json` diverge from the sealed snapshot on
        //    a hash-covered field. Keeping it fixed also lets a device that pulls the
        //    finalized version recompute a BYTE-IDENTICAL integrity hash (fix E).
        if !isApplyingRemote && !toWrite.locked {
            toWrite.updatedAt = Date()
        }
        let url = FilePaths.currentVersionFile(jobId: toWrite.id)
        try ioQueue.sync {
            try FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
            let data = try JSONEncoder().encode(toWrite)
            try FileSecurity.writeProtected(data, to: url)
        }
        // Suppress the mirror push while applying a remote change — emitting here
        // would push the just-pulled record straight back and loop. The push meta
        // is built from the STAMPED copy so the record carries the fresh edit time.
        if !isApplyingRemote {
            syncCoordinator?.recordLocalChange(.versionUpserted(VersionMetadata(from: toWrite)))
        }
        return toWrite
    }

    private func removeInspectionArtifacts(versionId: UUID, inspectionId: UUID, hasRemainingInspectionReferences: Bool) throws {
        try ioQueue.sync {
            try removeFolderIfPresent(FilePaths.inspectionFolder(jobId: versionId))
            if inspectionId != versionId && !hasRemainingInspectionReferences {
                try removeFolderIfPresent(FilePaths.inspectionFolder(jobId: inspectionId))
            }
        }
    }

    private func removeFolderIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// The CloudKit asset tombstones (jobId + root-relative path) to emit when an
    /// inspection is deleted, so its synced MediaAsset / ReportPDF records don't
    /// outlive it and RESURRECT on a fresh device (D-0203 review) — a
    /// fetchChanges(since:nil) on a new device would otherwise receive the orphaned
    /// records and rewrite the deleted scans/plans/PDFs to disk. Enumerates the same
    /// on-disk assets the push/seed path syncs — thumbnails, LiDAR floor plans and
    /// scan/room JSON, and the report PDF — through the shared `SyncAssetPaths`
    /// allowlist, so photos, videos, USDZ, and the whole-home cache are never
    /// included. Assets are keyed by inspectionId; call BEFORE the folders are wiped.
    private func syncedAssetTombstones(inspectionId: UUID, inspection: Inspection?) -> [(jobId: UUID, relativePath: String)] {
        let fm = FileManager.default
        let jobStr = inspectionId.uuidString
        var out: [(jobId: UUID, relativePath: String)] = []

        func addFiles(inDir dir: URL, relativeDir: String) {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return }   // directory absent → nothing to tombstone
            for url in entries {
                let rel = "\(relativeDir)/\(url.lastPathComponent)"
                if SyncAssetPaths.kind(forRelativePath: rel) != nil { out.append((inspectionId, rel)) }
            }
        }
        addFiles(inDir: FilePaths.thumbnailsFolder(jobId: inspectionId),
                 relativeDir: "Inspections/\(jobStr)/thumbnails")
        addFiles(inDir: FilePaths.lidarFolder(jobId: inspectionId),
                 relativeDir: "Inspections/\(jobStr)/lidar")
        // Sync data completeness pass: signature PNGs, plus the fixed-name cover
        // photo and side-state document at the inspection folder root.
        addFiles(inDir: FilePaths.signaturesFolder(jobId: inspectionId),
                 relativeDir: "Inspections/\(jobStr)/signatures")
        for name in [FilePaths.defaultCoverPhotoFileName, FilePaths.sideStateFileName] {
            let rel = "Inspections/\(jobStr)/\(name)"
            if fm.fileExists(atPath: FilePaths.inspectionFolder(jobId: inspectionId).appendingPathComponent(name).path),
               SyncAssetPaths.kind(forRelativePath: rel) != nil {
                out.append((inspectionId, rel))
            }
        }
        if let pdfRel = FilesAppPublisher.publishedReportRelativePath(forJobId: inspectionId, inspection: inspection),
           SyncAssetPaths.kind(forRelativePath: pdfRel) != nil {
            out.append((inspectionId, pdfRel))
        }
        return out
    }

    /// Loads full version from disk. Returns nil if not found or decode fails.
    /// Synchronous: retained for callers that need the value inline (delete /
    /// revision / purge / finalize). For the inspection-OPEN path use
    /// `loadFullVersionAsync` so the decode of a large inspection doesn't block
    /// the main thread.
    public func loadFullVersion(id: UUID) -> InspectionVersion? {
        let url = FilePaths.currentVersionFile(jobId: id)
        return ioQueue.sync {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let version = try? JSONDecoder().decode(InspectionVersion.self, from: data) else { return nil }
            return version
        }
    }

    /// Off-main async variant of `loadFullVersion` for the inspection-open path.
    /// The disk read + full JSON decode run on the serial `ioQueue` (ordered
    /// with every write, so it never observes a half-written file) while the
    /// main thread stays free — opening a large inspection no longer freezes the
    /// UI. `InspectionVersion` is a `Sendable` value type, so handing it back
    /// across the continuation is race-free.
    nonisolated public func loadFullVersionAsync(id: UUID) async -> InspectionVersion? {
        let url = FilePaths.currentVersionFile(jobId: id)
        return await withCheckedContinuation { (cont: CheckedContinuation<InspectionVersion?, Never>) in
            ioQueue.async {
                guard FileManager.default.fileExists(atPath: url.path),
                      let data = try? Data(contentsOf: url),
                      let version = try? JSONDecoder().decode(InspectionVersion.self, from: data) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: version)
            }
        }
    }

    public func clearSaveError() { saveError = nil }
    public func clearLoadError() { loadError = nil }

    /// Gates all further writes and clears in-memory state. Call on the main
    /// actor BEFORE the async disk wipe so that (a) the UI never renders rows
    /// backed by files we're about to delete, and (b) no save / autosave /
    /// version write can re-persist data into the directory mid-wipe. Also
    /// deletes the mirrored calendar events first (one-time read of each version
    /// before state is cleared). Pair with `performDiskWipe()`. Idempotent.
    public func beginWipe() {
        // Delete the mirrored calendar events BEFORE clearing state / wiping
        // files. Scheduled inspections write client name/phone/email + address
        // into an EKEvent that syncs to the user's iCloud/Google calendar
        // off-device; the disk wipe only removes appRoot, so without this the
        // PII survives Account Deletion (T-01436, 5.1.1(v)). Must run while
        // metadataList + the version files still exist.
        deleteMirroredCalendarEvents()
        // Cancel any pending debounced save and gate every write path.
        saveWorkItem?.cancel()
        saveWorkItem = nil
        isWiping = true
        // Clear in-memory state up front so the Dashboard can't render stale
        // rows for inspections whose files are about to be deleted.
        metadataList = []
        saveError = nil
        loadError = nil
        lastSavedAt = nil
    }

    /// Deletes the mirrored EKEvent for every inspection that has one. Best
    /// effort and idempotent — a missing/already-deleted event identifier just
    /// throws and is ignored (T-01436).
    private func deleteMirroredCalendarEvents() {
        for meta in metadataList {
            guard let full = loadFullVersion(id: meta.id),
                  let eventIdentifier = full.inspection.calendarEventIdentifier else { continue }
            try? CalendarService.shared.deleteEvent(eventIdentifier: eventIdentifier)
        }
    }

    /// Runs the heavy recursive disk wipe OFF the main thread, then re-opens the
    /// write gate. Call AFTER `beginWipe()`. Safe to run detached in the
    /// background while the UI has already moved on (Delete Account dismiss).
    /// Dispatched to the serial `ioQueue`, so it is FIFO-ordered after any
    /// in-flight write and never races a half-written file.
    public func performDiskWipe() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                Self.wipeAppRoot()
                cont.resume()
            }
        }
        isWiping = false
    }

    /// Wipes ALL local inspection data from disk and clears in-memory state.
    /// Satisfies App Store Guideline 5.1.1(v); the next launch starts clean.
    /// Convenience pairing the synchronous `beginWipe()` reset with the off-main
    /// `performDiskWipe()`. Callers that must react before the disk wipe finishes
    /// (immediate dismiss, synchronous-before-Task UI reset) call the two halves
    /// directly instead.
    public func clearAllLocalData() async {
        beginWipe()
        await performDiskWipe()
    }

    /// Recursively removes `FilePaths.appRoot`. Runs on `ioQueue` only and
    /// touches no `@MainActor` state, so it is `nonisolated` and safe off the
    /// main thread. Extracted from `clearAllLocalData()` so the heavy delete can
    /// be awaited off-main (T-01413).
    nonisolated private static func wipeAppRoot() {
        // Clear the per-inspection soft flags (invoice sent/paid, archived).
        // These live in UserDefaults, OUTSIDE appRoot, so the disk wipe below
        // would leave them behind — a 5.1.1(v) "no copies retained" gap. Done
        // first so it runs even when appRoot is already gone (T-01412).
        InspectionFlags.clearAll()

        let fm = FileManager.default
        let root = FilePaths.appRoot
        guard fm.fileExists(atPath: root.path) else { return }

        // First attempt: a single recursive delete. Fast path.
        do {
            try fm.removeItem(at: root)
        } catch {
            Diagnostics.logError(
                context: "clearAllLocalData: recursive removeItem failed for \(root.path); falling back to per-file walk",
                error: error,
                persistToDisk: false
            )
            // Fallback: walk the contents and remove each entry, capturing
            // failures per item rather than aborting the whole wipe. This
            // recovers the case where one file (e.g. an open audit-log
            // FileHandle, an iCloud-coordinating file, or a stuck temp
            // export) prevented the recursive remove from completing.
            let resourceKeys: [URLResourceKey] = [.isDirectoryKey]
            if let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsSubdirectoryDescendants]
            ) {
                for case let url as URL in enumerator {
                    do {
                        try fm.removeItem(at: url)
                    } catch {
                        Diagnostics.logError(
                            context: "clearAllLocalData: failed to remove \(url.lastPathComponent)",
                            error: error,
                            persistToDisk: false
                        )
                    }
                }
            }
            // Try removing the (now hopefully empty) root one more time.
            try? fm.removeItem(at: root)
        }

        // Post-condition check. If the root still exists, the wipe was
        // incomplete and the user's data persists past Delete Account.
        // Logged to Crashlytics ONLY (persistToDisk: false): Diagnostics' own
        // on-disk diagnostics.log lives INSIDE appRoot, so a normal log here
        // would re-create the very directory we just deleted. (Same reason
        // there is no AuditLog success entry — AuditLog writes
        // appRoot/audit_log.txt and would defeat the wipe.)
        if fm.fileExists(atPath: root.path) {
            Diagnostics.logError(
                context: "clearAllLocalData: appRoot still exists after wipe attempts: \(root.path). Data NOT fully deleted.",
                persistToDisk: false
            )
        }

        // Deliverables (exported ZIPs, mirrored report PDFs) now live UNDER appRoot,
        // so the recursive wipe above already removed them. These calls remain as
        // explicit, defensive cleanup. The deletion receipt lives in
        // Application Support/NexGenSpecReceipts (OUTSIDE appRoot) and is
        // deliberately NOT removed — it is the user's permanent record, designed to
        // outlive the wipe.
        InspectionZIPExportService.removeAllExports()
        FilesAppPublisher.removeAllPublished()
        // Belt-and-suspenders for upgrading users: sweep any pre-fix copies still in
        // the OLD file-shared Documents location (NexGenSpecExports / NexGenSpecReports
        // / NexGenSpecReceipts). New installs never write there; the launch sweep
        // normally clears these first, so this is just a guarantee at deletion time.
        FilePaths.cleanupLegacyDocumentsDeliverables()
        // Report/PDF/ZIP staging artifacts written to the temp directory (report-*,
        // pdf-*, zip-staging-*, InspectionReport-*) also live OUTSIDE appRoot and
        // carry full client PII. iOS purges the temp dir only "from time to time",
        // so a freshly-exported report could survive Account Deletion without this
        // sweep — residual PII under Apple 5.1.1(v) (audit finding).
        ReportExportService.removeAllTempExports()
    }

    /// Flushes any pending debounced save and writes to disk immediately. Use for ⌘S.
    public func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save()
    }

    /// Writes just the inspection's version JSON to disk without
    /// mutating `metadataList` or publishing any change. This is the
    /// save path used by InspectionView's per-keystroke auto-save —
    /// publishing `metadataList` on every edit caused a UICollectionView
    /// batch-update race that crashed on iOS 26 (_Bug_Detected_In_Client_
    /// Of_UICollectionView_Invalid_Number_Of_Items_In_Section) when the
    /// Dashboard List behind the nav stack was mid-animation.
    ///
    /// The lightweight file write here is enough to prevent data loss;
    /// the full `update(version:)` path still runs on view disappear,
    /// app backgrounding, and log out, which is when `metadataList` +
    /// the on-disk index need to be refreshed for the Dashboard UI.
    public func writeVersionFileOnlyForAutoSave(_ version: InspectionVersion) {
        guard InspectionStateMachine.allowsEdit(version.state) else { return }
        guard !isWiping else { return }
        // Same staleness rule as update() (B-0122): the on-screen draft may
        // predate a remote finalize applied while the view was open, and this
        // path writes current.json directly. Checked at enqueue time on the
        // main actor; a remote apply landing in the same instant can still
        // race this one queued write (the check can't re-run on the ioQueue —
        // main-actor state), but that write can never publish a row or push:
        // update()'s row-state guard blocks the teardown flush.
        if let row = metadataList.first(where: { $0.id == version.id }) {
            if !InspectionStateMachine.allowsEdit(row.state) { return }
            // Clock backstop (B-0122 round 3): refuse when the authoritative
            // row's LWW clock is strictly NEWER than the passed copy's. The
            // locked-row guard above only catches a remote FINALIZE; a remote
            // DRAFT EDIT applied while a stale copy sat open on-screen leaves
            // the row editable, and this file-only path would then clobber the
            // just-applied newer content in current.json — silently reverting
            // the editor's real edits in the local truth that conflict
            // resolution (DiskVersionReader.localState) and the next open read.
            // A strictly-newer row clock is the fingerprint of exactly that:
            // the row only jumps ahead of an open draft's own stamp via
            // applyRemoteVersion (this path never re-stamps, and update()'s
            // re-stamp is immediately re-synced onto the open draft — see
            // InspectionView.flushDraftOnTeardown). Normal editing therefore
            // passes with equal stamps; legacy nil clocks (either side) are
            // never refused.
            if let rowClock = row.updatedAt, let versionClock = version.updatedAt,
               rowClock > versionClock { return }
        }
        guard pendingFinalizedMetadata[version.id] == nil else { return }
        // Foreground per-edit autosave: encode + write OFF the main thread so
        // typing/editing never blocks on JSON encoding + disk I/O. Dispatched
        // to the same serial `ioQueue` as every other store write, so it stays
        // strictly ordered relative to the authoritative flush (which remains
        // synchronous on disappear / background / logout — see `save()` and the
        // willResignActive observer). `version` is a value type captured by
        // copy; no `@MainActor` state is touched on the queue, so there is no
        // data race. A pending async write here is flushed-after by the next
        // synchronous `ioQueue.sync` (FIFO), so backgrounding never loses it.
        let url = FilePaths.currentVersionFile(jobId: version.id)
        ioQueue.async {
            do {
                try FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
                let data = try JSONEncoder().encode(version)
                try FileSecurity.writeProtected(data, to: url)
            } catch {
                Diagnostics.logError(context: "autosave writeVersionFileOnly failed", error: error)
            }
        }
        // The CloudKit mirror is intentionally NOT notified from this per-keystroke
        // ASYNC autosave path — doing so would race the queued write (the mirror
        // reads the file off-queue) and be needlessly chatty. The authoritative
        // writeVersionToFile path (view disappear / background / save / finalize)
        // fires recordLocalChange after a synchronous, ordered write, so every edit
        // still mirrors on each real save point. (review finding: autosave race)
    }

    /// Schedules a single save after a short delay. Use for draft updates to avoid hammering disk.
    private func scheduleDebouncedSave() {
        saveWorkItem?.cancel()
        isSaving = true
        let item = DispatchWorkItem { [weak self] in
            self?.save()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: item)
    }
}

// MARK: - CRUD

public extension InspectionStore {

    /// Creates a new draft inspection. Returns true only when an inspection was
    /// actually created and persisted; false on any early-out (template load
    /// failure, unconfirmed inspector, directory-creation failure, or existing
    /// inspections temporarily unreadable). Callers gate side effects on the
    /// result — notably the free-trial counter, which must NOT advance when
    /// creation silently fails (audit finding).
    @discardableResult
    func createNewInspection(clientName: String, clientEmail: String, clientPhone: String, propertyAddress: String, inspectorName: String, inspectorConfirmed: Bool, inspectionDate: Date = Date(), customTemplateId: String? = nil) -> Bool {
        let template: HeavyTemplate
        if let customId = customTemplateId,
           let custom = CustomTemplateStore.shared.template(for: customId) {
            template = CustomTemplateStore.shared.toHeavyTemplate(custom)
        } else {
            guard let builtin = heavyTemplate else { return false }
            template = builtin
        }
        guard inspectorConfirmed else { return false }

        let jobId = UUID()
        do {
            try FilePaths.ensureAppStructure(jobId: jobId)
        } catch {
            return false
        }

        // Snapshot the company branding onto the inspection at creation,
        // alongside inspectorName, so it travels IN the synced payload and
        // renders correctly on any device (the source InspectorProfile is
        // device-local). Frozen here keeps the finalized integrity hash
        // deterministic — branding is never re-read live during render of a
        // finalized record.
        let profile = InspectorProfile.shared
        let inspection = Inspection(
            id: jobId,
            clientName: clientName,
            clientEmail: clientEmail,
            clientPhone: clientPhone,
            propertyAddress: propertyAddress,
            inspectionDate: inspectionDate,
            inspectorName: inspectorName,
            companyName: profile.companyName,
            licenseNumber: profile.licenseNumber,
            companyPhone: profile.phone,
            companyEmail: profile.email,
            companyLogoBase64: profile.companyLogoBase64,
            sections: template.sections.map { src in
                InspectionSection(
                    id: StableUUID.from(seed: "\(jobId.uuidString)-section-\(src.sectionId)"),
                    title: src.title,
                    items: src.items.map { itm in
                        InspectionItem(
                            id: StableUUID.from(seed: "\(jobId.uuidString)-item-\(itm.itemId)"),
                            templateItemId: itm.itemId,
                            title: itm.title,
                            includeInReport: false,
                            status: .notInspected,
                            defectSeverity: nil,
                            location: "",
                            observed: itm.commentLibrary.observed,
                            implication: itm.commentLibrary.implication,
                            recommendation: itm.commentLibrary.recommendation,
                            contractorTag: itm.contractorTag,
                            photos: []
                        )
                    }
                )
            },
            inspectorConfirmed: true
        )

        let newVersion = InspectionVersion(
            id: jobId,
            versionNumber: (metadataList.map(\.versionNumber).max() ?? 0) + 1,
            status: .draft,
            finalizedAt: nil,
            locked: false,
            inspection: inspection
        )

        // If the index failed to load earlier, recover the surviving inspections
        // from disk BEFORE adding this one, so clearing the write-gate here can
        // never overwrite the index with a one-entry list that orphans existing
        // inspections (B-0044).
        if !didLoadSucceed {
            switch rebuildIndexFromVersionFiles() {
            case .rebuilt(let recovered):
                metadataList = recovered
                didLoadSucceed = true
            case .empty:
                // Provably no other inspection files exist — safe to start fresh.
                metadataList = []
                didLoadSucceed = true
            case .incomplete:
                // Existing inspections are present but temporarily unreadable
                // (e.g. device locked). Abort rather than risk orphaning them.
                saveError = "Can't create a new inspection while existing inspections are temporarily unavailable. Reopen the app after unlocking the device."
                return false
            }
        }

        let written: InspectionVersion
        do {
            written = try writeVersionToFile(newVersion)
        } catch {
            // A swallowed write here returned true and burned a free-trial slot
            // while leaving a phantom index row that couldn't be opened (audit H2).
            Diagnostics.logError(context: "createNewInspection: version write failed", error: error)
            saveError = "Couldn't save the new inspection — your device may be locked or low on storage. Try again after unlocking."
            return false
        }
        metadataList.insert(VersionMetadata(from: written), at: 0)
        save()
        return true
    }

    /// Finalizes the given version using the strict state machine. Call from UI; do not mutate version in the view.
    func finalize(version: InspectionVersion) {
        guard let idx = metadataList.firstIndex(where: { $0.id == version.id }) else { return }
        let current = version
        let hasRequiredSignatures = current.inspection.signatures.count >= 2
        switch InspectionStateMachine.transitionToFinalized(
            from: current.state,
            hasRequiredSignatures: hasRequiredSignatures,
            versionId: current.id
        ) {
        case .success:
            var updated = current
            updated.status = .final
            updated.finalizedAt = Date()
            updated.locked = true
            // The integrity snapshot/hash is a HARD prerequisite for
            // finalization (T-01448): write AND verify it BEFORE persisting the
            // .final/locked version. If it can't be written/verified (e.g. the
            // device is locked under data protection), do NOT mark the report
            // final — otherwise integrity.txt would advertise the version as
            // "not finalized" while it is in fact locked, breaking the legal
            // tamper-evidence guarantee. Leave it a draft and surface an error.
            do {
                let writtenHash = try FinalizationService.writeSnapshot(updated)
                let jobId = UUID(uuidString: updated.inspection.inspectionId) ?? updated.id
                guard let readBack = FinalizationService.loadReportHash(jobId: jobId, versionId: updated.id),
                      !readBack.isEmpty, readBack == writtenHash else {
                    saveError = "Couldn't finalize: the integrity snapshot could not be verified. The inspection has not been finalized. Reopen the app after unlocking the device and try again."
                    return
                }
            } catch {
                saveError = "Couldn't finalize: the integrity snapshot could not be written (\(error.localizedDescription)). The inspection has not been finalized. Reopen the app after unlocking the device and try again."
                return
            }
            // The current.json write is as load-bearing as the integrity snapshot
            // (A4): on a throw the version on disk is STILL A DRAFT, so proceeding
            // to stage finalized metadata / rewrite the index would advertise a
            // finalization that never persisted — and the sync emit (inside
            // writeVersionToFile, after the write) never fired, so the "finalized"
            // report would silently never reach the other device either. Surface
            // the failure and leave everything a draft; the user retries.
            let written: InspectionVersion
            do {
                written = try writeVersionToFile(updated)
            } catch {
                saveError = "Couldn't finalize: the inspection could not be written to disk (\(error.localizedDescription)). The inspection has not been finalized. Reopen the app after unlocking the device and try again."
                return
            }
            // Persist the finalize WITHOUT any @Published mutation, because the
            // Dashboard/Calendar/Archived screens observe the WHOLE store via
            // @EnvironmentObject — so ANY published change (not just metadataList:
            // also `isSaving` / `lastSavedAt` toggled by `save()`) re-renders their
            // ForEach and tears the pushed eager NavigationLink off the nav stack,
            // popping the user back to the list before the finalize→Invoice
            // redirect can run (the reported bug). This mirrors the autosave path,
            // which deliberately writes file-only with no publish and therefore
            // never pops:
            //   1. Stage the finalized metadata in the non-published
            //      `pendingFinalizedMetadata` (assigning `metadataList[idx]` here
            //      would publish → pop). `idx` is kept only for the guard above.
            //   2. Write the on-disk index directly via `saveMetadataIndex()`
            //      (which folds the staged entry in) instead of `save()` — same
            //      disk result, but WITHOUT save()'s `isSaving`/`lastSavedAt`
            //      @Published churn.
            // The published `metadataList` is reconciled by `flushPendingMetadata()`
            // when the user next lands on a list screen — never while the
            // inspection is on screen.
            _ = idx
            pendingFinalizedMetadata[written.id] = VersionMetadata(from: written)
            try? saveMetadataIndex()
            // Item 4 (sync data completeness): the finalize SUCCEEDED and fully
            // persisted — kick off the non-blocking report-PDF auto-publish so a
            // ReportPDF sync record is created without a manual Export/Send.
            // Deliberately the LAST statement of the success path: it can never
            // block or fail the finalize, and the finalize→Invoice redirect (which
            // runs after this method returns) is unaffected. Every failed/aborted
            // finalize above returns before reaching here.
            scheduleFinalizeAutoPublish(for: written)
        case .failure:
            break
        }
    }

    /// Fires the finalize auto-publish exactly once per successful finalize (Item
    /// 4). Test seam first; otherwise the default fire-and-forget export+publish.
    /// Skipped when the product toggle is off, and in DEBUG screenshot runs (the
    /// demo fixture finalizes seed data — a WKWebView PDF render mid-capture would
    /// only add churn).
    private func scheduleFinalizeAutoPublish(for version: InspectionVersion) {
        guard Self.autoPublishReportPDFOnFinalize else { return }
        if let hook = finalizeAutoPublishHook {
            hook(version)
            return
        }
        #if DEBUG
        if ScreenshotMode.isActive { return }
        #endif
        let watermark = autoPublishWatermarkProvider?() ?? true
        Task { @MainActor in
            // A fresh, view-independent exporter: the same HTML→PDF pipeline the
            // manual Export/Send flow drives, ending in the same
            // FilesAppPublisher.publish — which emits the ReportPDF sync record.
            let exporter = ReportExportService()
            await exporter.export(version: version, watermark: watermark)
            if case .success(_, let pdf?) = exporter.result {
                FilesAppPublisher.publish(version: version, pdfURL: pdf)
                Diagnostics.logInfo("Finalize auto-publish: report PDF published for \(version.id)")
            } else {
                // Failure-tolerant by contract: log only — the finalize already
                // succeeded, and the manual Export/Send flow remains available.
                Diagnostics.logError(context: "Finalize auto-publish: PDF export failed for \(version.id) (non-blocking; manual Export/Send still available)")
            }
        }
    }

    /// Reconciles finalize metadata staged by `finalize(version:)` into the
    /// published `metadataList`. Call from a list screen's `.onAppear`
    /// (Dashboard / Calendar / Archived) so the row badge flips to Finalized
    /// AFTER the user has left the pushed inspection — publishing it earlier
    /// would pop the inspection off the nav stack (the finalize→Invoice bug
    /// this whole mechanism exists to avoid). Idempotent; a no-op when nothing
    /// is staged.
    func flushPendingMetadata() {
        guard !pendingFinalizedMetadata.isEmpty else { return }
        let pending = pendingFinalizedMetadata
        pendingFinalizedMetadata.removeAll()
        for (id, meta) in pending {
            if let idx = metadataList.firstIndex(where: { $0.id == id }) {
                metadataList[idx] = meta
            }
        }
    }

    /// Creates a new draft version that is a revision of the given finalized version. Returns new version ID or nil if not allowed.
    func createRevision(from versionID: UUID) -> UUID? {
        guard let current = loadFullVersion(id: versionID) else { return nil }
        switch InspectionStateMachine.canCreateRevision(from: current.state) {
        case .success:
            var copy = current.inspection
            copy.signatures = []
            // Detach calendar linkage from the parent finalized version: a
            // revision is a new draft and if the inspector wants a calendar
            // entry for it they'll opt in again via SchedulingCard. Without
            // this, deleting the revision's draft would cascade-delete the
            // EK event that still belongs to the finalized parent.
            copy.calendarEventIdentifier = nil
            copy.calendarIdentifier = nil
            let revision = InspectionVersion(
                id: UUID(),
                versionNumber: (metadataList.map(\.versionNumber).max() ?? 0) + 1,
                status: .draft,
                finalizedAt: nil,
                locked: false,
                inspection: copy
            )
            let written = (try? writeVersionToFile(revision)) ?? revision
            metadataList.insert(VersionMetadata(from: written), at: 0)
            save()
            return written.id
        case .failure:
            return nil
        }
    }

    /// Updates draft version. No-op if version is finalized (state machine). Uses debounced save to reduce disk I/O.
    func update(version: InspectionVersion) {
        guard let idx = metadataList.firstIndex(where: { $0.id == version.id }) else { return }
        guard InspectionStateMachine.allowsEdit(version.state) else { return }
        // The caller's copy can be STALE: a remote finalize may have been applied
        // (applyRemoteVersion) — or a local one staged in pendingFinalizedMetadata —
        // while that copy sat open on screen. Judging editability on `version.state`
        // alone let the stale draft overwrite the finalized current.json, flip the
        // row back to Draft, re-stamp the LWW clock, and echo-push the reversion to
        // every other device (B-0122). Editability is the store's call, not the
        // caller's.
        guard InspectionStateMachine.allowsEdit(metadataList[idx].state),
              pendingFinalizedMetadata[version.id] == nil else { return }
        // Publish the row only for a write that actually reached disk; the old
        // `?? version` fallback advertised a save that never happened.
        guard let written = try? writeVersionToFile(version) else { return }
        metadataList[idx] = VersionMetadata(from: written)
        scheduleDebouncedSave()
    }

    func insert(version: InspectionVersion) {
        let written = (try? writeVersionToFile(version)) ?? version
        metadataList.insert(VersionMetadata(from: written), at: 0)
        save()
    }

    /// Applies a synced-in remote version to the local-first store (build 22 slice
    /// 4c). Upsert by id: REPLACES an existing entry — including a local draft that
    /// a remote FINALIZATION supersedes (a case `update(version:)` would refuse via
    /// its `allowsEdit` guard) — or inserts a brand-new one. Routed through the
    /// normal `writeVersionToFile` path so disk + the published `metadataList` stay
    /// consistent, but with `isApplyingRemote` set so (a) the remote's `updatedAt`
    /// is preserved rather than re-stamped, and (b) no push is emitted back (which
    /// would loop apply→push→apply).
    ///
    /// Quota-safe: like `insert`, it never calls `recordInspectionCreated()`, so a
    /// report created on another device and synced in here never burns this device's
    /// free-trial slot — the quota is on creation and was already counted at the
    /// origin. The apply-vs-keep-local decision is made upstream by the port via
    /// `SyncConflictResolver`; this method only applies an already-approved version.
    ///
    /// Returns true on success. On a disk-write failure it is FAIL-CLOSED: it leaves
    /// `metadataList`/the index untouched (no "phantom" row pointing at a missing
    /// current.json) and returns false so the port skips advancing the change token
    /// and the next pull retries (review F5).
    @discardableResult
    func applyRemoteVersion(_ version: InspectionVersion, expectedUID: String? = nil) -> Bool {
        guard !isWiping else { return false }
        // Cross-account guard (build 22 fix B / landmine 1). The pulled record was
        // bound to `expectedUID`; this store writes to the LIVE appRoot
        // (SessionScope.currentSegment). After an A→B account switch the segment is B
        // before a stale A-port's in-flight pull resumes, so applying here would write
        // A's record into B's store. Checked on the MainActor, ATOMICALLY with the
        // synchronous write below — no `await` between this guard and writeVersionToFile,
        // and account switches also run on the MainActor, so none can interleave. (The
        // writer's earlier off-actor check had a real TOCTOU gap; this is the fix.)
        if let expectedUID, SessionScope.currentSegment != expectedUID {
            Diagnostics.logError(
                context: "applyRemoteVersion: refused cross-account apply (bound=\(expectedUID), active=\(SessionScope.currentSegment))",
                persistToDisk: false
            )
            // Return FALSE, not true (round-2 finding): a `true` would let pull() keep
            // `allApplied` and ADVANCE the bound account's change token past this
            // un-applied record (Firebase flips to B before the port rebinds, so a
            // stale A-port pull sees segment==B != A). Incremental pulls never
            // re-fetch a record once the token passes it, so the bound account's own
            // edit would be permanently, silently lost. `false` holds the token so the
            // next pull (under the correct binding) re-delivers it — same contract as
            // the disk-write-failure path below.
            return false
        }
        // Belt-and-suspenders immutability (build 22 fix D): the port's resolver
        // already approved this apply from the on-disk `localState`, but if THAT read
        // failed to decode `current.json` it now fails closed and the resolver keeps
        // local — still, defend the in-memory truth here too. If we locally hold a
        // FINALIZED (locked) version for this id, never let a non-finalized remote
        // overwrite the immutable legal record. A legitimate same-id finalized remote
        // (byte-identical by construction) is allowed through. Return true: this is a
        // deliberate keep-local, not a transient failure worth retrying.
        if let existing = metadataList.first(where: { $0.id == version.id }),
           !InspectionStateMachine.allowsEdit(existing.state),
           !version.locked {
            Diagnostics.logError(
                context: "applyRemoteVersion: refused to overwrite locked local \(version.id) with a non-finalized remote (immutability)",
                persistToDisk: false
            )
            return true
        }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        let written: InspectionVersion
        do {
            written = try writeVersionToFile(version)
        } catch {
            Diagnostics.logError(context: "applyRemoteVersion: disk write failed; index left untouched, will retry", error: error)
            return false
        }
        // Build 22 fix E: only `current.json` syncs — the integrity snapshot lives in
        // an unsynced `versions/<id>.json` written by `FinalizationService`. Without
        // it, a finalized report pulled onto this device has no `loadReportHash`, so
        // the renderer treats it as a DRAFT and exporters emit an empty hash (the Mac
        // review-station's primary path). Recompute the snapshot locally for a
        // finalized apply: the hash is over the canonical sorted-keys encoding of the
        // SAME model bytes, so it is byte-identical to the origin device's. Best
        // effort — a derived artifact; on failure the apply still stands and the next
        // pull retries (so do NOT fail the apply / wedge the token over it).
        if written.locked {
            do {
                _ = try FinalizationService.writeSnapshot(written)
            } catch {
                Diagnostics.logError(context: "applyRemoteVersion: failed to recompute integrity snapshot for finalized \(written.id)", error: error)
            }
        }
        if let idx = metadataList.firstIndex(where: { $0.id == written.id }) {
            metadataList[idx] = VersionMetadata(from: written)
        } else {
            metadataList.insert(VersionMetadata(from: written), at: 0)
        }
        save()
        return true
    }

    /// Applies a remote tombstone: removes a local DRAFT version that was deleted on
    /// another device (build 22 slice 4c). Delegates to `deleteVersion`, which
    /// already refuses to remove a finalized/locked report (the immutable legal
    /// record) — matching `SyncConflictResolver.resolveDelete`. `isApplyingRemote`
    /// suppresses both the echo-push AND the external-mirror cleanup (calendar /
    /// Files-app export) that only a user-initiated delete should perform (review F4).
    /// Returns true when the version is gone (removed now or already absent); false
    /// on a real removal failure, so the port retries on the next pull.
    @discardableResult
    func applyRemoteDelete(id: UUID, expectedUID: String? = nil) -> Bool {
        guard !isWiping else { return false }
        // Cross-account guard (build 22 fix B), atomic with the synchronous delete
        // below — see applyRemoteVersion. Refuse to delete in the wrong account's
        // store after an account switch raced this pull.
        if let expectedUID, SessionScope.currentSegment != expectedUID {
            Diagnostics.logError(
                context: "applyRemoteDelete: refused cross-account delete (bound=\(expectedUID), active=\(SessionScope.currentSegment))",
                persistToDisk: false
            )
            // FALSE, not true (round-2 finding) — hold the change token for retry
            // under the correct binding; see applyRemoteVersion.
            return false
        }
        // Already absent ⇒ the tombstone is satisfied (idempotent success).
        guard metadataList.contains(where: { $0.id == id }) else { return true }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        return deleteVersion(id: id)
    }

    /// Removes a version if it is still a draft (not signed by both parties / not finalized). Returns true if deleted.
    func deleteVersion(id: UUID) -> Bool {
        guard let idx = metadataList.firstIndex(where: { $0.id == id }) else { return false }
        let metadata = metadataList[idx]
        guard InspectionStateMachine.allowsEdit(metadata.state) else { return false }

        let hasRemainingInspectionReferences = metadataList.enumerated().contains { offset, other in
            offset != idx && other.inspectionId == metadata.inspectionId
        }

        // External-mirror cleanup — deleting the user's iCloud/Google calendar event
        // and their exported Files-app report folder — is a USER-INITIATED-delete
        // concern only. A synced-in remote tombstone (isApplyingRemote) must NOT
        // reach outside the local version store: CloudKit is an observer/mirror of
        // that store, and nothing in the contract authorizes a pulled change to
        // mutate the user's calendar or Files-app exports (design §3; review F4).
        // We therefore load the full version (needed for both side effects) and run
        // them ONLY on a genuine local delete. The local version record + index are
        // removed below in BOTH cases.
        let full = isApplyingRemote ? nil : loadFullVersion(id: id)
        if !isApplyingRemote, let eventIdentifier = full?.inspection.calendarEventIdentifier {
            try? CalendarService.shared.deleteEvent(eventIdentifier: eventIdentifier)
        }

        // Enumerate the inspection's synced assets BEFORE the folders are wiped, so we
        // can tombstone their CloudKit records (D-0203 review). Same gate as the
        // Files-app removal below: ONLY on a genuine local delete (a remote-tombstone
        // apply must not echo a push — F4) of the LAST version referencing the
        // inspection (a surviving revision still owns the shared inspectionId assets).
        let assetTombstones: [(jobId: UUID, relativePath: String)] =
            (!isApplyingRemote && !hasRemainingInspectionReferences)
            ? syncedAssetTombstones(inspectionId: metadata.inspectionId, inspection: full?.inspection)
            : []

        do {
            try removeInspectionArtifacts(
                versionId: metadata.id,
                inspectionId: metadata.inspectionId,
                hasRemainingInspectionReferences: hasRemainingInspectionReferences
            )
        } catch {
            saveError = "Could not remove inspection files: \(error.localizedDescription)"
            return false
        }

        // Remove the published Files-app mirror (NexGenSpec/[Address]/) if one was
        // exported, so the report + _data don't outlive the inspection. No-op when
        // nothing was published — and skipped entirely for a remote tombstone (F4).
        if !isApplyingRemote, let inspection = full?.inspection, !hasRemainingInspectionReferences {
            let jobId = UUID(uuidString: inspection.inspectionId) ?? metadata.id
            FilesAppPublisher.removePublished(for: inspection, jobId: jobId)
        }

        metadataList.remove(at: idx)
        save()
        // Suppress the mirror push when this delete is itself the application of a
        // remote tombstone (build 22 slice 4c) — otherwise we'd echo the delete
        // back to CloudKit. Genuine local deletes still propagate.
        if !isApplyingRemote {
            syncCoordinator?.recordLocalChange(.versionDeleted(versionId: id))
            // Tombstone the inspection's synced assets so their CK records are deleted
            // and never resurrect on a fresh device (D-0203 review). Mirrors how the
            // version delete above tombstones its own record.
            for (jobId, relativePath) in assetTombstones {
                syncCoordinator?.recordLocalChange(.mediaDeleted(jobId: jobId, relativePath: relativePath))
            }
        }
        return true
    }

    /// Admin-only purge of finalized inspections older than retention policy.
    @discardableResult
    func purgeExpiredInspections(isAdmin: Bool, actorId: String?) -> RetentionPolicyService.PurgeResult {
        // RetentionPolicyService removes the inspection folders but has
        // no knowledge of EventKit. Before we lose access to the version
        // JSON, walk the candidates and delete any mirrored calendar
        // events so we don't orphan them.
        if isAdmin {
            let candidateIds = RetentionPolicyService.expiredVersionIDs(metadata: metadataList)
            for versionId in candidateIds {
                guard let full = loadFullVersion(id: versionId),
                      let eventIdentifier = full.inspection.calendarEventIdentifier else { continue }
                try? CalendarService.shared.deleteEvent(eventIdentifier: eventIdentifier)
            }
        }
        let result = RetentionPolicyService.purgeExpiredInspections(
            metadata: metadataList,
            isAdmin: isAdmin,
            actorId: actorId
        )
        guard !result.deletedInspectionIDs.isEmpty else { return result }
        metadataList.removeAll { result.deletedInspectionIDs.contains($0.id) }
        saveNow()
        return result
    }
}

extension InspectionStore {
    enum DecodedIndexData {
        case metadata([VersionMetadata])
        case legacyVersions([InspectionVersion])
    }

    static func decodeIndexData(_ data: Data) -> DecodedIndexData? {
        if let metaIndex = try? JSONDecoder().decode(MetadataIndex.self, from: data) {
            return .metadata(metaIndex.metadata)
        }
        if let legacy = try? JSONDecoder().decode([InspectionVersion].self, from: data) {
            return .legacyVersions(legacy)
        }
        if let legacy = try? JSONDecoder().decode(InspectionIndex.self, from: data) {
            return .legacyVersions(legacy.versions)
        }
        return nil
    }
}

// MARK: - Index

private struct MetadataIndex: Codable {
    var schemaVersion: Int
    var metadata: [VersionMetadata]

    init(schemaVersion: Int = 1, metadata: [VersionMetadata]) {
        self.schemaVersion = schemaVersion
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case metadata
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        metadata = try c.decode([VersionMetadata].self, forKey: .metadata)
    }
}

private struct InspectionIndex: Codable {
    var versions: [InspectionVersion]
}

// MARK: - Fallback Template

private extension InspectionStore {
    static var fallbackTemplate: HeavyTemplate {
        HeavyTemplate(
            templateId: "fallback",
            name: "Sample Template",
            version: 1,
            severityScale: ["Safety", "Major", "Marginal", "Minor"],
            statusOptions: ["OK", "Not Inspected", "Not Present"],
            sections: [
                HeavySection(
                    sectionId: "section-1",
                    title: "Sample Section",
                    defaultContractorTag: "",
                    items: [
                        HeavyItem(
                            itemId: "item-1",
                            title: "Sample Item",
                            defaultSeverity: "Minor",
                            contractorTag: "",
                            fields: HeavyFields(location: true, observed: true, implication: true, recommendation: true),
                            commentLibrary: HeavyCommentLibrary(observed: "", implication: "", recommendation: "")
                        )
                    ]
                )
            ]
        )
    }
}
