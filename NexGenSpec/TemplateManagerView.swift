//
//  TemplateManagerView.swift
//  NexGenSpec
//
//  Lets users view, duplicate, customize, and delete inspection templates.
//

import SwiftUI

struct TemplateManagerView: View {
    @ObservedObject private var templateStore = CustomTemplateStore.shared
    @State private var showDuplicateSheet = false
    @State private var newTemplateName = ""
    @State private var editingTemplate: CustomTemplate?

    var body: some View {
        List {
            Section("Built-in Templates") {
                HStack {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("DIA Inspect - Heavy Template")
                            .font(AppFont.headline)
                        Text("Default template with all standard sections")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Duplicate") {
                        showDuplicateSheet = true
                    }
                    .font(AppFont.subheadline.weight(.semibold))
                    .foregroundStyle(AppColor.accent)
                }
                .padding(.vertical, Spacing.xs)
            }

            Section("Custom Templates") {
                if templateStore.templates.isEmpty {
                    Text("No custom templates yet. Duplicate the built-in template to get started.")
                        .font(AppFont.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, Spacing.sm)
                } else {
                    ForEach(templateStore.templates) { template in
                        Button {
                            editingTemplate = template
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                    Text(template.name)
                                        .font(AppFont.headline)
                                        .foregroundStyle(.primary)
                                    Text("\(template.sections.count) sections")
                                        .font(AppFont.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, Spacing.xs)
                        }
                    }
                    .onDelete { offsets in
                        templateStore.delete(at: offsets)
                    }
                }
            }
        }
        .navigationTitle("Templates")
        .sheet(isPresented: $showDuplicateSheet) {
            DuplicateTemplateSheet(templateName: $newTemplateName) {
                duplicateBuiltIn()
            }
        }
        .sheet(item: $editingTemplate) { template in
            NavigationStack {
                TemplateEditorView(template: template)
            }
        }
    }

    private func duplicateBuiltIn() {
        let name = newTemplateName.isEmpty ? "Custom Template" : newTemplateName
        // Load the built-in heavy template
        if let url = Bundle.main.url(forResource: "InspectionTemplate", withExtension: "json"),
           let heavy = HeavyTemplateImporter.load(from: url) {
            let custom = CustomTemplate(from: heavy, name: name)
            templateStore.add(custom)
        }
        newTemplateName = ""
        showDuplicateSheet = false
    }
}

// MARK: - Duplicate Sheet

private struct DuplicateTemplateSheet: View {
    @Binding var templateName: String
    let onDuplicate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("New Template Name") {
                    TextField("Template name", text: $templateName)
                }
            }
            .navigationTitle("Duplicate Template")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Duplicate") { onDuplicate() }
                        .disabled(templateName.isEmpty)
                }
            }
        }
    }
}

// MARK: - Template Editor

private struct TemplateEditorView: View {
    @State var template: CustomTemplate
    @ObservedObject private var templateStore = CustomTemplateStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newSectionTitle = ""
    @State private var showAddSection = false

    var body: some View {
        List {
            Section("Template Name") {
                TextField("Name", text: $template.name)
                    .font(AppFont.headline)
            }

            Section("Sections") {
                ForEach(Array(template.sections.enumerated()), id: \.element.id) { index, section in
                    NavigationLink {
                        SectionEditorView(section: Binding(
                            get: { template.sections[index] },
                            set: { template.sections[index] = $0 }
                        ))
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(section.title)
                                .font(AppFont.headline)
                            Text("\(section.items.count) items")
                                .font(AppFont.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    template.sections.remove(atOffsets: offsets)
                }
                .onMove { from, to in
                    template.sections.move(fromOffsets: from, toOffset: to)
                }

                Button {
                    showAddSection = true
                } label: {
                    Label("Add Section", systemImage: "plus.circle.fill")
                        .foregroundStyle(AppColor.accent)
                }
            }
        }
        .navigationTitle("Edit Template")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    templateStore.update(template)
                    dismiss()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
        }
        .alert("New Section", isPresented: $showAddSection) {
            TextField("Section title", text: $newSectionTitle)
            Button("Cancel", role: .cancel) { newSectionTitle = "" }
            Button("Add") {
                if !newSectionTitle.isEmpty {
                    template.sections.append(
                        CustomTemplateSection(title: newSectionTitle)
                    )
                    newSectionTitle = ""
                }
            }
        }
    }
}

// MARK: - Section Editor

private struct SectionEditorView: View {
    @Binding var section: CustomTemplateSection
    @State private var newItemTitle = ""
    @State private var showAddItem = false

    var body: some View {
        List {
            Section("Section Title") {
                TextField("Title", text: $section.title)
                    .font(AppFont.headline)
            }

            Section("Items") {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, _ in
                    TextField("Item title", text: Binding(
                        get: { section.items[index].title },
                        set: { section.items[index].title = $0 }
                    ))
                }
                .onDelete { offsets in
                    section.items.remove(atOffsets: offsets)
                }
                .onMove { from, to in
                    section.items.move(fromOffsets: from, toOffset: to)
                }

                Button {
                    showAddItem = true
                } label: {
                    Label("Add Item", systemImage: "plus.circle.fill")
                        .foregroundStyle(AppColor.accent)
                }
            }
        }
        .navigationTitle(section.title)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
        }
        .alert("New Item", isPresented: $showAddItem) {
            TextField("Item title", text: $newItemTitle)
            Button("Cancel", role: .cancel) { newItemTitle = "" }
            Button("Add") {
                if !newItemTitle.isEmpty {
                    section.items.append(
                        CustomTemplateItem(title: newItemTitle)
                    )
                    newItemTitle = ""
                }
            }
        }
    }
}
