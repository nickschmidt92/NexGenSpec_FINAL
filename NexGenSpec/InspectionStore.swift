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
    private var saveWorkItem: DispatchWorkItem?
    private let saveDebounceInterval: DispatchTimeInterval = .milliseconds(400)
    private let ioQueue = DispatchQueue(label: "com.nexgenspec.inspectionstore.io")

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

    private func load() {
        loadError = nil
        let data: Data? = ioQueue.sync {
            var payload: Data?
            if FileManager.default.fileExists(atPath: indexURL.path) {
                payload = try? Data(contentsOf: indexURL)
            }
            if payload == nil, FileManager.default.fileExists(atPath: FilePaths.inspectionsIndexBackup.path) {
                payload = try? Data(contentsOf: FilePaths.inspectionsIndexBackup)
            }
            return payload
        }
        guard let data = data else { return }
        if let decoded = Self.decodeIndexData(data) {
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
        } else {
            metadataList = []
            loadError = "Inspection index could not be read. The file may be corrupted."
        }
    }

    /// Reloads the inspection index from disk. Use after resolving load errors (e.g. restoring backup).
    public func reloadFromDisk() {
        load()
    }

    private func save() {
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
        try ioQueue.sync {
            try FileSecurity.ensureProtectedDirectory(indexURL.deletingLastPathComponent())
            if FileManager.default.fileExists(atPath: indexURL.path) {
                try? FileSecurity.copyProtectedItem(from: indexURL, to: FilePaths.inspectionsIndexBackup)
            }
            let index = MetadataIndex(schemaVersion: 1, metadata: metadataList)
            let data = try JSONEncoder().encode(index)
            try FileSecurity.writeProtected(data, to: indexURL)
        }
    }

    private func writeVersionToFile(_ version: InspectionVersion) throws {
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

    /// Wipes ALL local inspection data from disk and clears in-memory state.
    /// Called as part of Delete Account to satisfy App Store Guideline 5.1.1(v).
    /// After this runs, the next launch starts with a clean slate.
    ///
    /// `async` (T-01413): the recursive wipe of every photo / video / LiDAR file
    /// can take a long time on a large account. Running it via `ioQueue.sync` on
    /// the `@MainActor` (as before) blocked the main thread and risked a
    /// 0x8badf00d watchdog kill during Delete Account, so the wipe now runs off
    /// the main thread and is awaited.
    public func clearAllLocalData() async {
        // Cancel any pending save so it doesn't race the delete.
        saveWorkItem?.cancel()
        saveWorkItem = nil

        // Heavy recursive delete runs OFF the main thread. Dispatched to the
        // same serial `ioQueue` as every other store write, so it is FIFO-
        // ordered after any in-flight async autosave write and never races a
        // half-written file.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                Self.wipeAppRoot()
                cont.resume()
            }
        }

        // Back on the main actor: clear in-memory state.
        metadataList = []
        saveError = nil
        loadError = nil
        lastSavedAt = nil
    }

    /// Recursively removes `FilePaths.appRoot`. Runs on `ioQueue` only and
    /// touches no `@MainActor` state, so it is `nonisolated` and safe off the
    /// main thread. Extracted from `clearAllLocalData()` so the heavy delete can
    /// be awaited off-main (T-01413).
    nonisolated private static func wipeAppRoot() {
        let fm = FileManager.default
        let root = FilePaths.appRoot
        guard fm.fileExists(atPath: root.path) else { return }

        // First attempt: a single recursive delete. Fast path.
        do {
            try fm.removeItem(at: root)
        } catch {
            Diagnostics.logError(
                context: "clearAllLocalData: recursive removeItem failed for \(root.path); falling back to per-file walk",
                error: error
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
                            error: error
                        )
                    }
                }
            }
            // Try removing the (now hopefully empty) root one more time.
            try? fm.removeItem(at: root)
        }

        // Post-condition check. If the root still exists, the wipe was
        // incomplete and the user's data persists past Delete Account.
        // Goes through Firebase Crashlytics — does NOT write to disk, so
        // it can't accidentally re-create the directory we just removed.
        // (For the same reason there is no AuditLog success entry here:
        // AuditLog writes to appRoot/audit_log.txt and would defeat the
        // wipe by recreating the directory.)
        if fm.fileExists(atPath: root.path) {
            Diagnostics.logError(
                context: "clearAllLocalData: appRoot still exists after wipe attempts: \(root.path). Data NOT fully deleted."
            )
        }
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
            _ = try? FinalizationService.writeSnapshot(updated)
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
