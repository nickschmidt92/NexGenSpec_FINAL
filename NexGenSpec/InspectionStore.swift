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
    public var templateLoadFailed: Bool { heavyTemplate == nil }
    private var heavyTemplate: HeavyTemplate?
    private let indexURL = FilePaths.inspectionsIndex
    private var saveWorkItem: DispatchWorkItem?
    private let saveDebounceInterval: DispatchTimeInterval = .milliseconds(400)
    private let ioQueue = DispatchQueue(label: "com.nexgenspec.inspectionstore.io")

    public init() {
        load()
        loadHeavyTemplate()
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveWorkItem?.cancel()
                self?.saveWorkItem = nil
                self?.save()
            }
        }
    }

    private func loadHeavyTemplate() {
        let name = "InspectionTemplate"
        if let url = Bundle.main.url(forResource: name, withExtension: "json")
            ?? Bundle(for: Self.self).url(forResource: name, withExtension: "json") {
            heavyTemplate = HeavyTemplateImporter.load(from: url)
        } else {
            heavyTemplate = InspectionStore.fallbackTemplate
        }
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
    public func loadFullVersion(id: UUID) -> InspectionVersion? {
        let url = FilePaths.currentVersionFile(jobId: id)
        return ioQueue.sync {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let version = try? JSONDecoder().decode(InspectionVersion.self, from: data) else { return nil }
            return version
        }
    }

    public func clearSaveError() { saveError = nil }
    public func clearLoadError() { loadError = nil }

    /// Wipes ALL local inspection data from disk and clears in-memory state.
    /// Called as part of Delete Account to satisfy App Store Guideline 5.1.1(v).
    /// After this runs, the next launch starts with a clean slate.
    public func clearAllLocalData() {
        // Cancel any pending save so it doesn't race the delete.
        saveWorkItem?.cancel()
        saveWorkItem = nil

        ioQueue.sync {
            let root = FilePaths.appRoot
            if FileManager.default.fileExists(atPath: root.path) {
                try? FileManager.default.removeItem(at: root)
            }
        }

        metadataList = []
        saveError = nil
        loadError = nil
        lastSavedAt = nil
    }

    /// Flushes any pending debounced save and writes to disk immediately. Use for ⌘S.
    public func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save()
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

    /// Inserts one sample draft inspection when the list is empty (e.g. first launch). Uses fallback template if needed.
    func insertSampleInspectionIfNeeded() {
        guard metadataList.isEmpty else { return }
        let template = heavyTemplate ?? InspectionStore.fallbackTemplate
        let jobId = UUID()
        try? FilePaths.ensureAppStructure(jobId: jobId)
        let inspection = Inspection(
            id: jobId,
            clientName: "Sample Client",
            clientEmail: "",
            clientPhone: "",
            propertyAddress: "123 Main St",
            inspectionDate: Date(),
            inspectorName: "Inspector",
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
        let version = InspectionVersion(
            id: jobId,
            versionNumber: 1,
            status: .draft,
            finalizedAt: nil,
            locked: false,
            inspection: inspection
        )
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

        // Cascade: if this inspection has a mirrored calendar event, try to
        // delete it before we lose the identifier. We load the full version
        // to read the `calendarEventIdentifier` — the metadata list only
        // carries the lightweight fields.
        if let full = loadFullVersion(id: id),
           let eventIdentifier = full.inspection.calendarEventIdentifier {
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

        metadataList.remove(at: idx)
        save()
        return true
    }

    /// Admin-only purge of finalized inspections older than retention policy.
    @discardableResult
    func purgeExpiredInspections(isAdmin: Bool, actorId: String?) -> RetentionPolicyService.PurgeResult {
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
