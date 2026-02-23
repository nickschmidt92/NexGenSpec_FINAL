//
//  InspectionStore.swift
//  NexGenSpec
//

import Foundation
import Combine
import UIKit

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

    public init() {
        load()
        loadHeavyTemplate()
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.saveWorkItem?.cancel()
            self?.saveWorkItem = nil
            self?.save()
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
        var data: Data?
        if FileManager.default.fileExists(atPath: indexURL.path) {
            data = try? Data(contentsOf: indexURL)
        }
        if data == nil, FileManager.default.fileExists(atPath: FilePaths.inspectionsIndexBackup.path) {
            data = try? Data(contentsOf: FilePaths.inspectionsIndexBackup)
        }
        guard let data = data else { return }
        if let metaIndex = try? JSONDecoder().decode(MetadataIndex.self, from: data) {
            metadataList = metaIndex.metadata
        } else if let legacy = try? JSONDecoder().decode([InspectionVersion].self, from: data) {
            metadataList = legacy.map { VersionMetadata(from: $0) }
            for v in legacy {
                try? writeVersionToFile(v)
            }
            try? saveMetadataIndex()
        } else if let legacy = try? JSONDecoder().decode(InspectionIndex.self, from: data) {
            metadataList = legacy.versions.map { VersionMetadata(from: $0) }
            for v in legacy.versions {
                try? writeVersionToFile(v)
            }
            try? saveMetadataIndex()
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
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: indexURL.path) {
            try? FileManager.default.copyItem(at: indexURL, to: FilePaths.inspectionsIndexBackup)
        }
        let index = MetadataIndex(metadata: metadataList)
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    private func writeVersionToFile(_ version: InspectionVersion) throws {
        let url = FilePaths.currentVersionFile(jobId: version.id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(version)
        try data.write(to: url, options: .atomic)
    }

    /// Loads full version from disk. Returns nil if not found or decode fails.
    public func loadFullVersion(id: UUID) -> InspectionVersion? {
        let url = FilePaths.currentVersionFile(jobId: id)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let version = try? JSONDecoder().decode(InspectionVersion.self, from: data) else { return nil }
        return version
    }

    public func clearSaveError() { saveError = nil }
    public func clearLoadError() { loadError = nil }

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

    func createNewInspection(clientName: String, clientEmail: String, clientPhone: String, propertyAddress: String, inspectorName: String, inspectorConfirmed: Bool) {
        guard let template = heavyTemplate, inspectorConfirmed else { return }

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
            inspectionDate: Date(),
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
        guard InspectionStateMachine.allowsEdit(metadataList[idx].state) else { return false }
        metadataList.remove(at: idx)
        try? FileManager.default.removeItem(at: FilePaths.currentVersionFile(jobId: id))
        save()
        return true
    }
}

// MARK: - Index

private struct MetadataIndex: Codable {
    var metadata: [VersionMetadata]
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
