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
            AppScreenBackground {
                List {
                    Section {
                        DashboardHero(
                            username: authManager.currentUsername,
                            totalCount: store.metadataList.count,
                            draftCount: draftCount,
                            finalCount: finalCount
                        )
                    }
                    .listRowInsets(EdgeInsets(top: Spacing.md, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    Section {
                        DashboardActionDeck(
                            newInspectionAction: prepareForNewInspection,
                            settingsAction: { showSettings = true }
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    Section {
                        if store.metadataList.isEmpty {
                            EmptyDashboardState {
                                prepareForNewInspection()
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: Spacing.md, trailing: Spacing.md))
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
                            .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.md, bottom: Spacing.xs, trailing: Spacing.md))
                            .listRowBackground(Color.clear)
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
                    } header: {
                        HStack {
                            Text("Inspections")
                            Spacer()
                            Text("\(store.metadataList.count) total")
                                .font(AppFont.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .listSectionSpacing(Spacing.sm)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .refreshable {
                    store.reloadFromDisk()
                }
                .navigationTitle("Workspace")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Settings") {
                            showSettings = true
                        }
                        .accessibilityLabel("Settings")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            prepareForNewInspection()
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
    }

    private var draftCount: Int {
        store.metadataList.filter { $0.status == .draft }.count
    }

    private var finalCount: Int {
        store.metadataList.filter { $0.status == .final }.count
    }

    private func prepareForNewInspection() {
        newClientName = ""
        newClientEmail = ""
        newClientPhone = ""
        newPropertyAddress = ""
        newInspectorName = ""
        inspectorConfirmed = false
        showNewInspectionSheet = true
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
        HStack(alignment: .top, spacing: Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(metadata.status.badgeColor.opacity(0.14))
                    .frame(width: 50, height: 50)

                Image(systemName: metadata.status == .draft ? "square.and.pencil" : "checkmark.seal.fill")
                    .foregroundStyle(metadata.status.badgeColor)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(metadata.clientName)
                            .font(AppFont.headline)
                            .foregroundStyle(.primary)

                        Text(metadata.propertyAddress)
                            .font(AppFont.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }

                HStack(spacing: Spacing.sm) {
                    InspectionInfoPill(
                        title: dateFormatter.string(from: metadata.inspectionDate),
                        systemImage: "calendar"
                    )

                    InspectionInfoPill(
                        title: metadata.status.rawValue,
                        systemImage: metadata.status == .draft ? "square.and.pencil" : "lock.fill",
                        foregroundStyle: metadata.status.badgeColor,
                        background: metadata.status.badgeColor.opacity(0.14)
                    )
                }
            }
        }
        .padding(Spacing.md)
        .background(AppColor.softPanelGradient)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metadata.clientName), \(metadata.propertyAddress), \(metadata.status.rawValue)")
        .accessibilityHint("Opens this inspection")
    }
}

private struct InspectionInfoPill: View {
    let title: String
    let systemImage: String
    var foregroundStyle: Color = .secondary
    var background: Color = AppColor.elevatedSurface.opacity(0.72)

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(AppFont.caption.weight(.semibold))
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            .background(background)
            .foregroundStyle(foregroundStyle)
            .clipShape(Capsule())
    }
}

private struct DashboardHero: View {
    let username: String?
    let totalCount: Int
    let draftCount: Int
    let finalCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            BrandLockup(
                subtitle: "Track active inspections, secure your media, and keep reports moving.",
                markSize: 68
            )

            Text("Signed in as \(username ?? "Inspector")")
                .font(AppFont.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: Spacing.sm) {
                DashboardMetric(title: "Total", value: "\(totalCount)", systemImage: "tray.full.fill")
                DashboardMetric(title: "Drafts", value: "\(draftCount)", systemImage: "square.and.pencil")
                DashboardMetric(title: "Final", value: "\(finalCount)", systemImage: "checkmark.seal.fill")
            }
        }
        .inspectionCard()
    }
}

private struct DashboardActionDeck: View {
    let newInspectionAction: () -> Void
    let settingsAction: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            DashboardActionButton(
                title: "Start New",
                subtitle: "Open a fresh inspection shell",
                systemImage: "plus.circle.fill",
                action: newInspectionAction
            )

            DashboardActionButton(
                title: "Open Settings",
                subtitle: "Legal text, backup, and account controls",
                systemImage: "slider.horizontal.3",
                action: settingsAction
            )
        }
    }
}

private struct DashboardActionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(AppColor.accentDeep)

                Text(title)
                    .font(AppFont.headline)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
            .padding(Spacing.md)
            .background(AppColor.softPanelGradient)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct DashboardMetric: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Label(title, systemImage: systemImage)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(AppFont.title2)
                .foregroundStyle(AppColor.accentDeep)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.md)
        .background(AppColor.elevatedSurface.opacity(0.90))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct EmptyDashboardState: View {
    let createAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                ZStack {
                    Circle()
                        .fill(AppColor.accentSoft.opacity(0.50))
                        .frame(width: 52, height: 52)

                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AppColor.accentDeep)
                }

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("No inspections yet")
                        .font(AppFont.title3)
                    Text("Create your first inspection to start capturing photos, notes, and finalized reports.")
                        .font(AppFont.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Create First Inspection", action: createAction)
                .buttonStyle(AppPrimaryButtonStyle())

            HStack(spacing: Spacing.sm) {
                EmptyStatePromise(title: "Capture", systemImage: "camera.aperture")
                EmptyStatePromise(title: "Annotate", systemImage: "highlighter")
                EmptyStatePromise(title: "Export", systemImage: "square.and.arrow.up")
            }
        }
        .inspectionCard()
    }
}

private struct EmptyStatePromise: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(AppFont.caption.weight(.semibold))
            .foregroundStyle(AppColor.accentDeep)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(AppColor.elevatedSurface.opacity(0.88))
            .clipShape(Capsule())
            .frame(maxWidth: .infinity)
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
