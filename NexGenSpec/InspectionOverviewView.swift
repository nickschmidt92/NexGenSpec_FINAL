//
//  InspectionOverviewView.swift
//  NexGenSpec
//
//  Created by ChatGPT on 2/5/26.
//

import SwiftUI
import Foundation
import PhotosUI
import UniformTypeIdentifiers

/// Shows the cover page for an inspection. Displays metadata and summary counts. Editable client/property/inspector when draft.
@available(iOS 16.0, *)
struct InspectionOverviewView: View {
    @Binding var version: InspectionVersion
    @State private var shareContent: ShareContent?
    // Legacy — kept so other code paths still compile; drive presentation via shareContent.
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var showLiDARCapture = false
    @State private var selectedVideoItems: [PhotosPickerItem] = []
    @State private var showExportError = false
    @State private var showTextExportError = false
    @State private var showPaywall = false
    @StateObject private var exportService = ReportExportService()
    @EnvironmentObject private var subscriptions: SubscriptionManager

    private var isEditable: Bool { version.state.isEditable }
    private var jobId: UUID { UUID(uuidString: version.inspection.inspectionId) ?? version.id }

    var body: some View {
        if #available(iOS 17.0, *) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Metadata (editable when draft)
                    if isEditable {
                        overviewEditSection
                    } else {
                        overviewReadOnlySection
                    }
                    
                    // Status badge (from strict state)
                    HStack {
                        Text(version.state.displayName)
                            .font(.headline)
                            .padding(8)
                            .background(version.state.isEditable ? Color.orange.opacity(0.2) : Color.green.opacity(0.2))
                            .foregroundColor(version.state.isEditable ? .orange : .green)
                            .clipShape(Capsule())
                        Spacer()
                    }
                    // Summary counts
                    let counts = version.inspection.summaryCounts()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary")
                            .font(.headline)
                        HStack {
                            SummaryBadge(color: AppColor.safetyAccessible, label: "Safety", count: counts.safety)
                            SummaryBadge(color: AppColor.majorAccessible, label: "Major", count: counts.major)
                            SummaryBadge(color: AppColor.marginalAccessible, label: "Marginal", count: counts.marginal)
                            SummaryBadge(color: AppColor.minorAccessible, label: "Minor", count: counts.minor)
                        }
                    }
                    
                    // Drone / Video
                    droneVideoSection
                    
                    Spacer()
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: selectedVideoItems) { _, newItems in
                guard let item = newItems.first else { return }
                Task {
                    await addVideoFromPickerItem(item)
                }
            }
            .navigationTitle("Overview")
            .toolbar {
                if LiDARCapability.isSupported {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Capture Room") { showLiDARCapture = true }
                            .accessibilityLabel("Capture room with LiDAR")
                            .accessibilityHint("Opens RoomPlan capture")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        if isEditable {
                            Text("Finalize and sign the inspection before exporting.")
                        }
                        Button {
                            if let url = ReportExporter.exportPlainText(for: version) {
                                shareContent = ShareContent(items: [url])
                            } else {
                                showTextExportError = true
                            }
                        } label: { Label("Quick summary (text)", systemImage: "doc.text") }
                            .accessibilityLabel("Quick summary text")
                            .accessibilityHint("Share plain text summary")
                            .disabled(isEditable)
                        Button {
                            Task {
                                await exportService.export(version: version, watermark: !subscriptions.isPro)
                                if case .success(_, let pdf) = exportService.result, let url = pdf {
                                    shareContent = ShareContent(items: [url])
                                } else if case .failure = exportService.result {
                                    showExportError = true
                                }
                            }
                        } label: { Label(subscriptions.isPro ? "Full report (PDF)" : "Full report (PDF) – Free", systemImage: "doc.richtext") }
                            .disabled(exportService.isExporting || isEditable)
                            .accessibilityLabel("Full report PDF")
                            .accessibilityHint(subscriptions.isPro ? "Generate and share full PDF report" : "Generate watermarked PDF report")
                    } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        .accessibilityLabel("Export report")
                        .accessibilityHint("Share as text summary or full PDF report")
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
                    .environmentObject(subscriptions)
            }
            .sheet(item: $shareContent) { content in
                ShareSheet(activityItems: content.items)
            }
            .alert("Text export failed", isPresented: $showTextExportError) {
                Button("OK") { showTextExportError = false }
            } message: {
                Text("Could not create the text report. Try again.")
            }
            .alert("PDF export failed", isPresented: $showExportError) {
                Button("OK") { showExportError = false; exportService.reset() }
            } message: {
                Text(exportService.errorMessage ?? "The report could not be exported as PDF. It may be too large.")
            }
            .sheet(isPresented: $showLiDARCapture) {
                LiDARCaptureView(jobId: UUID(uuidString: version.inspection.inspectionId) ?? version.id)
            }
            .overlay(exportOverlay)
        } else {
            // Fallback for iOS 16: minimal placeholder so body is always available
            Text("Overview")
                .navigationTitle("Overview")
        }
    }

    // MARK: - Overview sections
    private var overviewReadOnlySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(version.inspection.clientName)
                .font(.largeTitle)
                .fontWeight(.bold)
            Text(version.inspection.propertyAddress)
                .font(.title3)
            if !version.inspection.clientEmail.isEmpty {
                Text(version.inspection.clientEmail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if !version.inspection.clientPhone.isEmpty {
                Text(version.inspection.clientPhone)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Text("Inspection Date: \(version.inspection.inspectionDate, formatter: DateFormatters.mediumDate)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Inspector: \(version.inspection.inspectorName)")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Client and property details")
    }

    @ViewBuilder
    private var overviewEditSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Client Name", text: binding(\.clientName))
                .font(.largeTitle)
                .fontWeight(.bold)
            TextField("Property Address", text: binding(\.propertyAddress))
                .font(.title3)
            TextField("Client Email", text: binding(\.clientEmail))
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
            TextField("Client Phone", text: binding(\.clientPhone))
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
            DatePicker("Inspection Date", selection: binding(\.inspectionDate), displayedComponents: .date)
            TextField("Inspector Name", text: binding(\.inspectorName))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    // MARK: - Drone / Video
    private var droneVideoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Drone / Video")
                    .font(.headline)
                Spacer()
                if isEditable {
                    PhotosPicker(
                        selection: $selectedVideoItems,
                        maxSelectionCount: 1, matching: .videos
                    ) {
                        Label("Add video", systemImage: "video.badge.plus")
                    }
                }
            }
            if version.inspection.videos.isEmpty {
                Text("No videos attached. Add drone or walkthrough footage.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(version.inspection.videos) { video in
                    HStack {
                        Image(systemName: "video.fill")
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(video.caption.isEmpty ? video.fileName : video.caption)
                                .lineLimit(1)
                            if let src = video.source, !src.isEmpty {
                                Text(src)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drone and video footage")
    }

    private func addVideoFromPickerItem(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            selectedVideoItems = []
            return
        }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "mp4"
        let fileName = "\(UUID().uuidString).\(ext)"
        let videosDir = FilePaths.videosFolder(jobId: jobId)
        let fileURL = videosDir.appendingPathComponent(fileName)
        do {
            try FileSecurity.ensureProtectedDirectory(videosDir)
            try FileSecurity.writeProtected(data, to: fileURL)
            let video = InspectionVideo(fileName: fileName, caption: "", sortOrder: version.inspection.videos.count, source: "drone")
            var insp = version.inspection
            insp.videos.append(video)
            var v = version
            v.inspection = insp
            version = v
        } catch {
            Diagnostics.logError(context: "addVideoFromPickerItem failed", error: error)
        }
        await MainActor.run { selectedVideoItems = [] }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Inspection, T>) -> Binding<T> {
        Binding(
            get: { version.inspection[keyPath: keyPath] },
            set: { newValue in
                var insp = version.inspection
                insp[keyPath: keyPath] = newValue
                var v = version
                v.inspection = insp
                version = v
            }
        )
    }

    @ViewBuilder
    private var exportOverlay: some View {
        if exportService.isExporting || exportService.errorMessage != nil {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    if let err = exportService.errorMessage {
                        Text("Export failed: \(err)")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        Button("Dismiss") { exportService.reset() }
                        .buttonStyle(.borderedProminent)
                    } else {
                        ProgressView(value: exportService.progress)
                            .progressViewStyle(.linear)
                            .frame(width: 200)
                        Text("Generating report…")
                            .font(.subheadline)
                            .foregroundColor(.white)
                    }
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
            }
        }
    }


/// A small coloured badge used in the overview summary counts.
private struct SummaryBadge: View {
    let color: Color
    let label: String
    let count: Int
    var body: some View {
        VStack {
            Text("\(count)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

/// Wrapper around UIActivityViewController for sharing files
struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Helper struct to export a plain text summary of an inspection for sharing.
struct ShareContent: Identifiable {
    let id = UUID()
    let items: [Any]
}

enum ReportExporter {
    static func exportPlainText(for version: InspectionVersion) -> URL? {
        let inspection = version.inspection
        var report = "Inspection Report\n"
        report += "Client: \(inspection.clientName)\n"
        if !inspection.clientEmail.isEmpty { report += "Email: \(inspection.clientEmail)\n" }
        if !inspection.clientPhone.isEmpty { report += "Phone: \(inspection.clientPhone)\n" }
        report += "Property: \(inspection.propertyAddress)\n"
        report += "Date: \(DateFormatters.mediumDate.string(from: inspection.inspectionDate))\n"
        report += "Inspector: \(inspection.inspectorName)\n\n"
        let jobId = UUID(uuidString: inspection.inspectionId) ?? version.id
        let lidarScans = LiDARScanStore.loadScans(jobId: jobId)
        if !lidarScans.isEmpty {
            report += "Room scans (LiDAR): \(lidarScans.map(\.usdzFileName).joined(separator: ", "))\n\n"
        }
        if !inspection.videos.isEmpty {
            report += "Videos: \(inspection.videos.map { $0.caption.isEmpty ? $0.fileName : $0.caption }.joined(separator: ", "))\n\n"
        }
        let counts = inspection.summaryCounts()
        report += "Safety: \(counts.safety), Major: \(counts.major), Marginal: \(counts.marginal), Minor: \(counts.minor)\n\n"
        for section in inspection.sections {
            let reportItems = section.items.filter { $0.isDefect && $0.includeInReport }
            guard !reportItems.isEmpty else { continue }
            report += "Section: \(section.title)\n"
            for item in reportItems {
                guard let sev = item.defectSeverity else { continue }
                report += " - \(item.title) [\(sev.rawValue)]\n"
                if !item.location.isEmpty { report += "   Location: \(item.location)\n" }
                report += "   Observed: \(item.observed)\n"
                report += "   Implication: \(item.implication)\n"
                report += "   Recommendation: \(item.recommendation)\n"
                if !item.inspectorComments.isEmpty { report += "   Inspector Comments: \(item.inspectorComments)\n" }
                if !item.contractorTag.isEmpty { report += "   Contractor: \(item.contractorTag)\n" }
            }
            report += "\n"
        }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("InspectionReport-\(UUID().uuidString).txt")
            if let data = report.data(using: .utf8) {
                try FileSecurity.writeProtected(data, to: url)
            }
            return url
        } catch {
            Diagnostics.logError(context: "exportPlainText failed", error: error)
            return nil
        }
    }
}

struct InspectionOverviewView_Previews: PreviewProvider {
    static var previews: some View {
        let inspection = Inspection(
            clientName: "Jane Doe",
            propertyAddress: "456 Maple Avenue",
            inspectionDate: Date(),
            inspectorName: "Inspector",
            sections: [],
            signatures: [],
            inspectorConfirmed: false
        )
        let version = InspectionVersion(
            versionNumber: 1,
            status: .draft,
            finalizedAt: nil,
            locked: false,
            inspection: inspection
        )
        return InspectionOverviewView(version: .constant(version))
    }
}
