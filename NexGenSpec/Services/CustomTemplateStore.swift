//
//  CustomTemplateStore.swift
//  NexGenSpec
//
//  Manages custom inspection templates saved to the documents directory.
//  Users can duplicate built-in templates and customize them.
//

import Foundation

/// A custom template that users can create by duplicating and editing a built-in template.
struct CustomTemplate: Identifiable, Codable, Equatable {
    var templateId: String
    var name: String
    var sections: [CustomTemplateSection]
    var createdAt: Date

    var id: String { templateId }

    init(templateId: String = UUID().uuidString, name: String, sections: [CustomTemplateSection], createdAt: Date = Date()) {
        self.templateId = templateId
        self.name = name
        self.sections = sections
        self.createdAt = createdAt
    }

    /// Convert from a HeavyTemplate for duplication.
    init(from heavy: HeavyTemplate, name: String) {
        self.templateId = UUID().uuidString
        self.name = name
        self.sections = heavy.sections.map { CustomTemplateSection(from: $0) }
        self.createdAt = Date()
    }
}

struct CustomTemplateSection: Identifiable, Codable, Equatable {
    var sectionId: String
    var title: String
    var items: [CustomTemplateItem]

    var id: String { sectionId }

    init(sectionId: String = UUID().uuidString, title: String, items: [CustomTemplateItem] = []) {
        self.sectionId = sectionId
        self.title = title
        self.items = items
    }

    init(from heavy: HeavySection) {
        self.sectionId = heavy.sectionId
        self.title = heavy.title
        self.items = heavy.items.map { CustomTemplateItem(from: $0) }
    }
}

struct CustomTemplateItem: Identifiable, Codable, Equatable {
    var itemId: String
    var title: String
    var contractorTag: String

    var id: String { itemId }

    init(itemId: String = UUID().uuidString, title: String, contractorTag: String = "") {
        self.itemId = itemId
        self.title = title
        self.contractorTag = contractorTag
    }

    init(from heavy: HeavyItem) {
        self.itemId = heavy.itemId
        self.title = heavy.title
        self.contractorTag = heavy.contractorTag
    }
}

/// Singleton store for custom templates. Persists to the app documents directory.
@MainActor
final class CustomTemplateStore: ObservableObject {

    static let shared = CustomTemplateStore()

    @Published private(set) var templates: [CustomTemplate] = []

    private let fileURL: URL = {
        FilePaths.appRoot.appendingPathComponent("custom_templates.json", isDirectory: false)
    }()

    private init() {
        load()
    }

    // MARK: - CRUD

    func add(_ template: CustomTemplate) {
        templates.append(template)
        save()
    }

    func update(_ template: CustomTemplate) {
        if let idx = templates.firstIndex(where: { $0.templateId == template.templateId }) {
            templates[idx] = template
            save()
        }
    }

    func delete(at offsets: IndexSet) {
        templates.remove(atOffsets: offsets)
        save()
    }

    func delete(templateId: String) {
        templates.removeAll { $0.templateId == templateId }
        save()
    }

    func template(for id: String) -> CustomTemplate? {
        templates.first { $0.templateId == id }
    }

    // MARK: - Conversion to HeavyTemplate for InspectionStore

    func toHeavyTemplate(_ custom: CustomTemplate) -> HeavyTemplate {
        HeavyTemplate(
            templateId: custom.templateId,
            name: custom.name,
            version: 1,
            severityScale: ["Safety", "Major", "Marginal", "Minor"],
            statusOptions: ["OK", "Not Inspected", "Not Present"],
            sections: custom.sections.map { sec in
                HeavySection(
                    sectionId: sec.sectionId,
                    title: sec.title,
                    defaultContractorTag: "",
                    items: sec.items.map { itm in
                        HeavyItem(
                            itemId: itm.itemId,
                            title: itm.title,
                            defaultSeverity: "Minor",
                            contractorTag: itm.contractorTag,
                            fields: HeavyFields(location: true, observed: true, implication: true, recommendation: true),
                            commentLibrary: HeavyCommentLibrary(observed: "", implication: "", recommendation: "")
                        )
                    }
                )
            }
        )
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([CustomTemplate].self, from: data) else {
            return
        }
        templates = decoded
    }

    private func save() {
        try? FileSecurity.ensureProtectedDirectory(fileURL.deletingLastPathComponent())
        guard let data = try? JSONEncoder().encode(templates) else { return }
        try? FileSecurity.writeProtected(data, to: fileURL)
    }
}
