//
//  DashboardView.swift
//  InspectIQ
//
//  Re-written 2026-02-17
//

import SwiftUI

/// Landing screen – lists all inspection versions and lets the user create a new one.
struct DashboardView: View {

    // MARK: - Dependencies
    @EnvironmentObject private var store: InspectionStore
    @EnvironmentObject private var authManager: AuthManager

    // MARK: - Local state
    @State private var showNewInspectionSheet = false
    @State private var newClientName       = ""
    @State private var newClientEmail     = ""
    @State private var newClientPhone     = ""
    @State private var newPropertyAddress = ""
    @State private var newInspectorName   = ""
    @State private var versionToDeleteID: UUID?
    @State private var showTemplateError = false
    @State private var showSettings = false

    // MARK: - View
    var body: some View {
        NavigationStack {
            List {
                Section("Inspections") {
                    if store.metadataList.isEmpty {
                        Group {
                            if #available(iOS 17.0, *) {
                                ContentUnavailableView(
                                    "No inspections yet",
                                    systemImage: "doc.text.magnifyingglass",
                                    description: Text("Create your first inspection to get started.")
                                )
                            } else {
                                VStack(spacing: 12) {
                                    Image(systemName: "doc.text.magnifyingglass")
                                        .font(.largeTitle)
                                        .foregroundStyle(.secondary)
                                    Text("No inspections yet")
                                        .font(.headline)
                                    Text("Create your first inspection to get started.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    ForEach(store.metadataList) { meta in
                        NavigationLink {
                            InspectionRootView(versionID: meta.id)
                                .environmentObject(store)
                        } label: {
                            VersionRow(metadata: meta)
                        }
                        .contextMenu {
                            if meta.isEditable {
                                Button("Delete inspection", role: .destructive) {
                                    versionToDeleteID = meta.id
                                }
                            }
                        }
                    }
                    .onDelete { indexSet in
                        let idsToDelete = indexSet
                            .filter { store.metadataList[$0].isEditable }
                            .map { store.metadataList[$0].id }
                        for id in idsToDelete { _ = store.deleteVersion(id: id) }
                    }
                }
            }
            .navigationTitle("NexGenSpec")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Settings") {
                        showSettings = true
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        newClientName      = ""
                        newClientEmail     = ""
                        newClientPhone     = ""
                        newPropertyAddress = ""
                        newInspectorName   = ""
                        inspectorConfirmed = false
                        showNewInspectionSheet = true
                    } label: {
                        Label("New Inspection", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityLabel("New Inspection")
                    .accessibilityHint("Opens a form to create a new inspection")
                }
            }
            .sheet(isPresented: $showNewInspectionSheet) { newInspectionSheet }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    AppSettingsView()
                        .environmentObject(store)
                        .environmentObject(authManager)
                }
            }
            .listStyle(.insetGrouped)
            .alert("Save failed", isPresented: Binding(
                get: { store.saveError != nil },
                set: { if !$0 { store.clearSaveError() } }
            )) {
                Button("Retry") { store.clearSaveError(); store.saveNow() }
                Button("OK") { store.clearSaveError() }
            } message: {
                if let err = store.saveError {
                    Text(err)
                }
            }
            .alert("Load failed", isPresented: Binding(
                get: { store.loadError != nil },
                set: { if !$0 { store.clearLoadError() } }
            )) {
                Button("Retry") { store.clearLoadError(); store.reloadFromDisk() }
                Button("OK") { store.clearLoadError() }
            } message: {
                if let err = store.loadError {
                    Text(err)
                }
            }
            .confirmationDialog("Delete inspection?", isPresented: Binding(
                get: { versionToDeleteID != nil },
                set: { if !$0 { versionToDeleteID = nil } }
            ), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let id = versionToDeleteID {
                        _ = store.deleteVersion(id: id)
                        versionToDeleteID = nil
                    }
                }
                Button("Cancel", role: .cancel) { versionToDeleteID = nil }
            } message: {
                if let id = versionToDeleteID, let meta = store.metadataList.first(where: { $0.id == id }) {
                    Text("“\(meta.clientName)” will be permanently removed. This cannot be undone.")
                }
            }
            .alert("Cannot create inspection", isPresented: $showTemplateError) {
                Button("OK") { showTemplateError = false }
            } message: {
                Text("The inspection template could not be loaded. Please restart the app or reinstall.")
            }
        }
    }

    // MARK: - Sheet
    @State private var inspectorConfirmed = false

    @ViewBuilder private var newInspectionSheet: some View {
        NavigationStack {
            Form {
                Section("Client") {
                    TextField("Client Name",        text: $newClientName)
                    TextField("Email",              text: $newClientEmail)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                    TextField("Phone",              text: $newClientPhone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                }
                Section("Property & Inspector") {
                    TextField("Property Address",   text: $newPropertyAddress)
                    TextField("Inspector Name",     text: $newInspectorName)
                }
                Section {
                    Toggle(isOn: $inspectorConfirmed) {
                        Text("I confirm I am a licensed or authorized inspector and responsible for this report.")
                            .font(.subheadline)
                    }
                } footer: {
                    Text("NexGenSpec is reporting software only. You are responsible for licensing, insurance, compliance, and report content.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New Inspection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showNewInspectionSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        if store.templateLoadFailed {
                            showNewInspectionSheet = false
                            showTemplateError = true
                        } else {
                            store.createNewInspection(
                                clientName:      newClientName,
                                clientEmail:    newClientEmail,
                                clientPhone:    newClientPhone,
                                propertyAddress: newPropertyAddress,
                                inspectorName:   newInspectorName,
                                inspectorConfirmed: inspectorConfirmed
                            )
                            showNewInspectionSheet = false
                        }
                    }
                    .disabled(newClientName.isEmpty ||
                              newPropertyAddress.isEmpty ||
                              newInspectorName.isEmpty ||
                              !inspectorConfirmed)
                }
            }
        }
    }
}

// MARK: - Single row helper (uses metadata for list; full version loaded on open)
private struct VersionRow: View {
    let metadata: VersionMetadata

    var body: some View {
        VStack(alignment: .leading) {
            Text(metadata.clientName)
                .font(.headline)
            Text(metadata.propertyAddress)
                .font(.subheadline)
                .foregroundColor(.secondary)
            HStack {
                Text(dateFormatter.string(from: metadata.inspectionDate))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(metadata.status.rawValue)
                    .font(.caption)
                    .padding(4)
                    .background(metadata.status.badgeColor.opacity(0.2))
                    .foregroundColor(metadata.status.badgeColor)
                    .clipShape(Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metadata.clientName), \(metadata.propertyAddress), \(metadata.status.rawValue)")
        .accessibilityHint("Opens this inspection")
    }
}

// Shared date formatter
private let dateFormatter = DateFormatters.mediumDateTime

// MARK: - Preview
#if DEBUG
struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        let store = InspectionStore()
        let auth = AuthManager()
        DashboardView()
            .environmentObject(store)
            .environmentObject(auth)
    }
}
#endif
