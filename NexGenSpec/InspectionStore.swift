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
    private let indexURL = FilePaths.inspectionsIndex
    /// Gates index writes after a failed load so a bad load can never overwrite a
    /// good primary/backup with an empty in-memory list. See `load()` (B-0044).
    private var didLoadSucceed = true
    private var saveWorkItem: DispatchWorkItem?
    private let saveDebounceInterval: DispatchTimeInterval = .milliseconds(400)
    private let ioQueue = DispatchQueue(label: "com.nexgenspec.inspectionstore.io")

    /// True from the moment a Delete-Account wipe begins (`beginWipe()`) until
    /// the off-main disk wipe finishes (`performDiskWipe()`). While set, every
    /// disk-write path (`save`, `writeVersionToFile`, `writeVersionFileOnlyForAutoSave`)
    /// no-ops so nothing can re-create the directory being deleted mid-wipe.
    public private(set) var isWiping = false

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
        loadError = nil
        // Reset the gate every load so a later healthy launch — or a restored
        // backup via reloadFromDisk() — re-enables index writes automatically.
        didLoadSucceed = true

        let (primaryRead, backupRead): (IndexFileRead, IndexFileRead) = ioQueue.sync {
            (Self.readIndexFile(indexURL), Self.readIndexFile(FilePaths.inspectionsIndexBackup))
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
            for v in legacy {
                try? writeVersionToFile(v)
            }
            try? saveMetadataIndex()
        }
        return true
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

    /// Reloads the inspection index from disk. Use after resolving load errors (e.g. restoring backup).
    public func reloadFromDisk() {
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
        let snapshot = metadataList
        try ioQueue.sync {
            try FileSecurity.ensureProtectedDirectory(indexURL.deletingLastPathComponent())
            // Only copy the existing primary over the backup when it currently
            // DECODES — a corrupt primary must never clobber a still-good backup.
            if let existing = try? Data(contentsOf: indexURL), Self.decodeIndexData(existing) != nil {
                try? FileSecurity.copyProtectedItem(from: indexURL, to: FilePaths.inspectionsIndexBackup)
            }
            let index = MetadataIndex(schemaVersion: 1, metadata: snapshot)
            let data = try JSONEncoder().encode(index)
            try FileSecurity.writeProtected(data, to: indexURL)
        }
    }

    private func writeVersionToFile(_ version: InspectionVersion) throws {
        guard !isWiping else { return }
        let url = FilePaths.currentVersionFile(jobId: version.id)
        try ioQueue.sync {
            try FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
            let data = try JSONEncoder().encode(version)
            try FileSecurity.writeProtected(data, to: url)
        }
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

        // Remove the Documents deliverable folders too — they live OUTSIDE appRoot
        // and hold full client PII (exported ZIPs: report + photos + videos;
        // mirrored report PDFs by address). The appRoot wipe doesn't reach them, so
        // without this they survive Account Deletion (5.1.1(v) gap, T-01447).
        // NexGenSpecReceipts/ is deliberately NOT removed — it is the user's
        // permanent deletion receipt, designed to outlive the wipe.
        InspectionZIPExportService.removeAllExports()
        FilesAppPublisher.removeAllPublished()
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

    func createNewInspection(clientName: String, clientEmail: String, clientPhone: String, propertyAddress: String, inspectorName: String, inspectorConfirmed: Bool, inspectionDate: Date = Date(), customTemplateId: String? = nil) {
        let template: HeavyTemplate
        if let customId = customTemplateId,
           let custom = CustomTemplateStore.shared.template(for: customId) {
            template = CustomTemplateStore.shared.toHeavyTemplate(custom)
        } else {
            guard let builtin = heavyTemplate else { return }
            template = builtin
        }
        guard inspectorConfirmed else { return }

        let jobId = UUID()
        do {
            try FilePaths.ensureAppStructure(jobId: jobId)
        } catch {
            return
        }

        let inspection = Inspection(
            id: jobId,
            clientName: clientName,
            clientEmail: clientEmail,
            clientPhone: clientPhone,
            propertyAddress: propertyAddress,
            inspectionDate: inspectionDate,
            inspectorName: inspectorName,
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
                return
            }
        }

        try? writeVersionToFile(newVersion)
        metadataList.insert(VersionMetadata(from: newVersion), at: 0)
        save()
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
            try? writeVersionToFile(updated)
            metadataList[idx] = VersionMetadata(from: updated)
            save()
        case .failure:
            break
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
            try? writeVersionToFile(revision)
            metadataList.insert(VersionMetadata(from: revision), at: 0)
            save()
            return revision.id
        case .failure:
            return nil
        }
    }

    /// Updates draft version. No-op if version is finalized (state machine). Uses debounced save to reduce disk I/O.
    func update(version: InspectionVersion) {
        guard let idx = metadataList.firstIndex(where: { $0.id == version.id }) else { return }
        guard InspectionStateMachine.allowsEdit(version.state) else { return }
        try? writeVersionToFile(version)
        metadataList[idx] = VersionMetadata(from: version)
        scheduleDebouncedSave()
    }

    func insert(version: InspectionVersion) {
        try? writeVersionToFile(version)
        metadataList.insert(VersionMetadata(from: version), at: 0)
        save()
    }

    /// Removes a version if it is still a draft (not signed by both parties / not finalized). Returns true if deleted.
    func deleteVersion(id: UUID) -> Bool {
        guard let idx = metadataList.firstIndex(where: { $0.id == id }) else { return false }
        let metadata = metadataList[idx]
        guard InspectionStateMachine.allowsEdit(metadata.state) else { return false }

        let hasRemainingInspectionReferences = metadataList.enumerated().contains { offset, other in
            offset != idx && other.inspectionId == metadata.inspectionId
        }

        // Load the full version once: we need it both to cascade-delete a
        // mirrored calendar event (before we lose the identifier) and to
        // resolve the property address for the published Files-app folder.
        // The metadata list only carries the lightweight fields.
        let full = loadFullVersion(id: id)
        if let eventIdentifier = full?.inspection.calendarEventIdentifier {
            try? CalendarService.shared.deleteEvent(eventIdentifier: eventIdentifier)
        }

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

        // Also remove the published Files-app mirror (NexGenSpec/[Address]/)
        // if one was exported, so the report + _data don't outlive the
        // inspection. No-op when nothing was published.
        if let inspection = full?.inspection, !hasRemainingInspectionReferences {
            let jobId = UUID(uuidString: inspection.inspectionId) ?? metadata.id
            FilesAppPublisher.removePublished(for: inspection, jobId: jobId)
        }

        metadataList.remove(at: idx)
        save()
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
