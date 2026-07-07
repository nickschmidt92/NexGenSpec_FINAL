//
//  ArchivedInspectionsView.swift
//  NexGenSpec
//
//  Top-level tab listing inspections the user has archived from the
//  Workspace dashboard. Archived state is a soft flag stored in
//  UserDefaults (see InspectionFlags) so existing JSON drafts don't
//  need migration. Restoring an inspection puts it back into the
//  Workspace list at the top of its date sort.
//

import SwiftUI

struct ArchivedInspectionsView: View {
    @EnvironmentObject private var store: InspectionStore
    @State private var versionToDeleteID: UUID?

    /// Live filtered list. We re-read on every render so newly archived
    /// rows show up immediately without needing a separate cache.
    private var archivedList: [VersionMetadata] {
        store.metadataList.filter { $0.isArchived }
    }

    var body: some View {
        Group {
            if archivedList.isEmpty {
                EmptyArchivedState()
            } else {
                List {
                    Section {
                        ForEach(archivedList) { meta in
                            NavigationLink {
                                InspectionRootView(versionID: meta.id)
                                    .environmentObject(store)
                            } label: {
                                ArchivedRow(metadata: meta)
                            }
                            .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.md, bottom: Spacing.xs, trailing: Spacing.md))
                            // Swipe-trailing actions mirror Workspace:
                            // • Restore — always available.
                            // • Delete — drafts only. Finalized records
                            //   stay on disk per the 5-year retention rule
                            //   surfaced in Terms §8.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    InspectionFlags.setArchived(false, inspectionId: meta.inspectionId.uuidString)
                                    store.objectWillChange.send()
                                } label: {
                                    Label("Restore", systemImage: "tray.and.arrow.up")
                                }
                                .tint(AppColor.success)

                                if meta.isEditable {
                                    Button(role: .destructive) {
                                        versionToDeleteID = meta.id
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            .contextMenu {
                                Button {
                                    InspectionFlags.setArchived(false, inspectionId: meta.inspectionId.uuidString)
                                    store.objectWillChange.send()
                                } label: {
                                    Label("Restore", systemImage: "tray.and.arrow.up")
                                }
                                if meta.isEditable {
                                    Button("Delete inspection", role: .destructive) {
                                        versionToDeleteID = meta.id
                                    }
                                } else {
                                    Button {} label: {
                                        Label("Finalized — kept for 5-year retention", systemImage: "lock.fill")
                                    }
                                    .disabled(true)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Archived")
                            Spacer()
                            Text("\(archivedList.count) total")
                                .font(AppFont.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .listSectionSpacing(Spacing.sm)
                .scrollContentBackground(.hidden)
                .confirmationDialog(
                    "Delete archived inspection?",
                    isPresented: Binding<Bool>(
                        get: { versionToDeleteID != nil },
                        set: { if !$0 { versionToDeleteID = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        if let id = versionToDeleteID {
                            _ = store.deleteVersion(id: id)
                            versionToDeleteID = nil
                        }
                    }
                    Button("Cancel", role: .cancel) { versionToDeleteID = nil }
                } message: {
                    if let id = versionToDeleteID,
                       let meta = store.metadataList.first(where: { $0.id == id }) {
                        Text("“\(meta.clientName)” will be permanently removed from this device. This cannot be undone.")
                    }
                }
            }
        }
        .navigationTitle("Archived")
        // Reconcile a finalize that occurred while an inspection was pushed
        // (publish is deferred to avoid popping the pushed view). Harmless
        // no-op when nothing is staged. See InspectionStore.flushPendingMetadata.
        .onAppear {
            store.flushPendingMetadata()
        }
    }
}

// MARK: - Row

private struct ArchivedRow: View {
    let metadata: VersionMetadata

    // Cached once, not rebuilt per row per render — DateFormatter init is
    // expensive (~1ms) and this row lives in a lazy List that re-renders on scroll.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "archivebox.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(AppColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(metadata.clientName)
                    .font(AppFont.headline)
                    .foregroundStyle(.primary)
                Text(metadata.propertyAddress)
                    .font(AppFont.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: Spacing.sm) {
                    InspectionInfoPill(
                        title: Self.dateFormatter.string(from: metadata.inspectionDate),
                        systemImage: "calendar"
                    )
                    let badge = metadata.badge
                    InspectionInfoPill(
                        title: badge.label,
                        systemImage: badge.systemImage,
                        foregroundStyle: badge.color,
                        background: badge.color.opacity(0.14)
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - Empty state

private struct EmptyArchivedState: View {
    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "archivebox")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No Archived Inspections")
                .font(.title3.weight(.semibold))
            Text("Swipe an inspection on the Workspace tab to archive it. Archiving is tracked per device — archiving here doesn’t archive the inspection on your other Apple devices. Swipe again to restore, or to permanently delete drafts. Finalized inspections cannot be deleted (5-year retention).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        ArchivedInspectionsView()
            .environmentObject(InspectionStore())
    }
}
#endif
