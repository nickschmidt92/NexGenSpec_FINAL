//
//  MyReportsView.swift
//  NexGenSpec
//
//  Browse and re-share saved report deliverables. Replaces the passive
//  "Files → NexGenSpec → NexGenSpecReports" browse folder that was removed when
//  deliverables moved out of the file-shared Documents directory into the
//  private per-UID store (the cross-account PII-leak fix). Because reports and
//  ZIP backups now live under `appRoot`, this list is per-account and persists
//  across logout — only Delete Account (or an explicit swipe-delete here) removes
//  them. Read-only browse + on-demand share ("Save to Files" / iCloud / email /
//  AirDrop) via the same share sheet used elsewhere in the app.
//

import SwiftUI
import Foundation

struct MyReportsView: View {

    private struct Deliverable: Identifiable {
        let id: String          // file path — stable + unique
        let shareURL: URL       // the file handed to the share sheet
        let deleteURL: URL      // what a delete removes (address folder for PDFs)
        let title: String
        let subtitle: String
        let systemImage: String
        let date: Date
    }

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// Only used to resolve a report folder back to its inspection jobId so a
    /// swipe-delete can emit the matching CloudKit asset tombstone (D-0203).
    /// MyReportsView is only ever presented under the store's environment.
    @EnvironmentObject private var store: InspectionStore

    @State private var reports: [Deliverable] = []
    @State private var backups: [Deliverable] = []
    @State private var shareItem: ShareItem?
    @State private var pendingDelete: Deliverable?
    @State private var didLoad = false

    var body: some View {
        List {
            if reports.isEmpty && backups.isEmpty {
                if didLoad { emptyState }
            } else {
                if !reports.isEmpty {
                    Section {
                        ForEach(reports) { deliverableRow($0) }
                    } header: {
                        Text("Reports (PDF)")
                    } footer: {
                        Text("Finalized report PDFs, by property address. Tap to share or save to Files.")
                    }
                }
                if !backups.isEmpty {
                    Section {
                        ForEach(backups) { deliverableRow($0) }
                    } header: {
                        Text("Backups (ZIP)")
                    } footer: {
                        Text("Full export bundles — report, photos, and videos. Tap to share or save to Files.")
                    }
                }
            }
        }
        .navigationTitle("My Reports")
        .navigationBarTitleDisplayMode(.inline)
        .tint(AppColor.accent)
        .task { load() }
        .refreshable { load() }
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.url])
        }
        .confirmationDialog(
            "Delete this file?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) { delete(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("This permanently removes “\(item.title)”. With iCloud Sync on, deleting a synced report removes it from your other Apple devices too. If you haven’t shared or exported it elsewhere, it can’t be recovered.")
        }
    }

    private func deliverableRow(_ d: Deliverable) -> some View {
        Button {
            shareItem = ShareItem(url: d.shareURL)
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: d.systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(AppColor.accent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.title)
                        .font(AppFont.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(d.subtitle)
                        .font(AppFont.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.sm)
                Image(systemName: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppColor.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share \(d.title)")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDelete = d
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No saved reports yet")
                .font(AppFont.headline)
            Text("Finalize an inspection and tap Export to save a report here. Reports are saved to your account and, with iCloud Sync on, sync across your own Apple devices through your private iCloud. Share any report to Files, iCloud, or email anytime.")
                .font(AppFont.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .listRowBackground(Color.clear)
    }

    // MARK: - Actions

    private func delete(_ d: Deliverable) {
        try? FileManager.default.removeItem(at: d.deleteURL)
        // Propagate a report-PDF deletion to CloudKit (D-0203). Only report folders
        // (under reportsFolder) sync — ZIP backups are not emitted. The folder name is
        // a property address, so recover the inspection jobId by matching the same
        // folder-naming the publisher used; if no inspection matches (already deleted),
        // skip — the record is cleaned up by the eventual zone teardown.
        let reportsPath = FilePaths.reportsFolder.standardizedFileURL.path
        if d.deleteURL.standardizedFileURL.path.hasPrefix(reportsPath + "/") {
            let folderName = d.deleteURL.lastPathComponent
            if let meta = store.metadataList.first(where: {
                FilesAppPublisher.folderName(propertyAddress: $0.propertyAddress, clientName: $0.clientName, jobId: $0.inspectionId) == folderName
            }) {
                SyncCoordinator.noteMediaDeleted(
                    jobId: meta.inspectionId,
                    relativePath: "Reports/\(folderName)/Inspection_Report.pdf")
            }
        }
        load()
    }

    private func load() {
        reports = Self.scanReports()
        backups = Self.scanBackups()
        didLoad = true
    }

    // MARK: - Scanning

    /// Published report PDFs: one per property-address folder under `reportsFolder`.
    private static func scanReports() -> [Deliverable] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: FilePaths.reportsFolder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [Deliverable] = []
        for folder in folders {
            let pdf = folder.appendingPathComponent("Inspection_Report.pdf")
            guard fm.fileExists(atPath: pdf.path) else { continue }
            let date = (try? pdf.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            out.append(Deliverable(
                id: pdf.path,
                shareURL: pdf,
                deleteURL: folder,
                title: folder.lastPathComponent,
                subtitle: DateFormatters.mediumDate.string(from: date),
                systemImage: "doc.richtext",
                date: date
            ))
        }
        return out.sorted { $0.date > $1.date }
    }

    /// Exported ZIP backups under `exportsFolder`.
    private static func scanBackups() -> [Deliverable] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: FilePaths.exportsFolder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [Deliverable] = []
        for zip in files where zip.pathExtension.lowercased() == "zip" {
            let vals = try? zip.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = vals?.contentModificationDate ?? .distantPast
            var label = zip.deletingPathExtension().lastPathComponent
            if label.hasPrefix("NexGenSpec_") {
                label = String(label.dropFirst("NexGenSpec_".count))
            }
            var subtitle = DateFormatters.mediumDate.string(from: date)
            if let size = vals?.fileSize {
                subtitle += " · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            }
            out.append(Deliverable(
                id: zip.path,
                shareURL: zip,
                deleteURL: zip,
                title: label,
                subtitle: subtitle,
                systemImage: "doc.zipper",
                date: date
            ))
        }
        return out.sorted { $0.date > $1.date }
    }
}
