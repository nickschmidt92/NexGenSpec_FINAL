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
import EventKit

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
    @State private var selectedCoverItems: [PhotosPickerItem] = []
    @State private var showExportError = false
    @State private var showTextExportError = false
    @State private var showPaywall = false
    @State private var showAgentsSection: Bool = false
    @State private var coverPhotoTick: Int = 0   // bumps to invalidate cached preview after change
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

                    // Cover photo: only meaningful once basic property
                    // metadata exists. Picker stays hidden until then so
                    // the workflow feels sequential (fill in client +
                    // address first, then attach a photo).
                    if hasCoreMetadata {
                        coverPhotoSection
                    }

                    // Real estate agents (buyer's + listing). Both optional.
                    realEstateAgentSection

                    // Scheduling (duration + add-to-calendar)
                    schedulingSection

                    // Status badge (from strict state)
                    HStack {
                        Text(version.state.displayName)
                            .font(.headline)
                            .padding(8)
                            .background(version.state.isEditable ? AppColor.warning.opacity(0.2) : AppColor.success.opacity(0.2))
                            .foregroundColor(version.state.isEditable ? AppColor.warning : AppColor.success)
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
                    
                    // Weather info
                    if let weather = version.inspection.weather {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Weather at Inspection")
                                .font(.headline)
                            HStack(spacing: 16) {
                                Label(weather.temperatureString, systemImage: "thermometer")
                                Label(weather.conditions, systemImage: "cloud.sun")
                                Label(weather.humidityString, systemImage: "humidity")
                                Label(weather.windSpeedString, systemImage: "wind")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            .onChange(of: selectedCoverItems) { _, newItems in
                guard let item = newItems.first else { return }
                Task {
                    await setCoverPhotoFromPickerItem(item)
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
                                await exportService.export(version: version, watermark: !subscriptions.hasFeatureAccess)
                                if case .success(_, let pdf) = exportService.result, let url = pdf {
                                    shareContent = ShareContent(items: [url])
                                } else if case .failure = exportService.result {
                                    showExportError = true
                                }
                            }
                        } label: { Label(subscriptions.hasFeatureAccess ? "Full report (PDF)" : "Full report (PDF) – Free", systemImage: "doc.richtext") }
                            .disabled(exportService.isExporting || isEditable)
                            .accessibilityLabel("Full report PDF")
                            .accessibilityHint(subscriptions.hasFeatureAccess ? "Generate and share full PDF report" : "Generate watermarked PDF report")
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
                .phoneFormatted(binding(\.clientPhone))
            DatePicker("Inspection Date & Time",
                       selection: binding(\.inspectionDate),
                       displayedComponents: [.date, .hourAndMinute])
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

    // MARK: - Cover photo

    /// Gate for showing the cover-photo picker. We require a client name and
    /// property address first so the inspector fills out identifying info
    /// before attaching a photo (and so the dashboard row shows something
    /// meaningful next to the thumbnail).
    private var hasCoreMetadata: Bool {
        !version.inspection.clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !version.inspection.propertyAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var coverPhotoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cover Photo")
                    .font(.headline)
                Spacer()
                if isEditable {
                    PhotosPicker(
                        selection: $selectedCoverItems,
                        maxSelectionCount: 1, matching: .images
                    ) {
                        Label(version.inspection.coverPhotoFileName == nil ? "Add" : "Change",
                              systemImage: "photo.badge.plus")
                    }
                    if version.inspection.coverPhotoFileName != nil {
                        Button(role: .destructive) {
                            removeCoverPhoto()
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
            if let img = loadCoverPhotoPreview() {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("Cover photo of the property")
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.systemGray6))
                        .frame(height: 120)
                    VStack(spacing: 4) {
                        Image(systemName: "house.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No cover photo")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Re-reads the cover photo from disk on each render; cheap because the
    /// JPEG is downscaled at write time. `coverPhotoTick` is used to
    /// invalidate any UI cache after a change so SwiftUI re-renders.
    private func loadCoverPhotoPreview() -> UIImage? {
        guard let name = version.inspection.coverPhotoFileName else { return nil }
        _ = coverPhotoTick   // dependency for re-render
        let url = FilePaths.coverPhotoFile(jobId: jobId, fileName: name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func setCoverPhotoFromPickerItem(_ item: PhotosPickerItem) async {
        defer { Task { @MainActor in selectedCoverItems = [] } }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let originalImage = UIImage(data: data) else {
            return
        }
        // Downscale to a sane upper bound so we don't write a 12 MP HEIC
        // straight to disk. 1600px max side keeps it crisp on the report
        // header but tiny on disk.
        let resized = originalImage.resizedKeepingAspect(maxSide: 1600)
        guard let jpegData = resized.jpegData(compressionQuality: 0.82) else { return }

        let fileName = FilePaths.defaultCoverPhotoFileName
        let url = FilePaths.coverPhotoFile(jobId: jobId, fileName: fileName)
        do {
            try FileSecurity.ensureProtectedDirectory(FilePaths.inspectionFolder(jobId: jobId))
            try FileSecurity.writeProtected(jpegData, to: url)
            await MainActor.run {
                var insp = version.inspection
                insp.coverPhotoFileName = fileName
                var v = version
                v.inspection = insp
                version = v
                coverPhotoTick &+= 1
                NotificationCenter.default.post(
                    name: .coverPhotoDidUpdate,
                    object: nil,
                    userInfo: ["jobId": jobId]
                )
            }
        } catch {
            Diagnostics.logError(context: "setCoverPhotoFromPickerItem failed", error: error)
        }
    }

    private func removeCoverPhoto() {
        if let name = version.inspection.coverPhotoFileName {
            let url = FilePaths.coverPhotoFile(jobId: jobId, fileName: name)
            try? FileManager.default.removeItem(at: url)
        }
        var insp = version.inspection
        insp.coverPhotoFileName = nil
        var v = version
        v.inspection = insp
        version = v
        coverPhotoTick &+= 1
        NotificationCenter.default.post(
            name: .coverPhotoDidUpdate,
            object: nil,
            userInfo: ["jobId": jobId]
        )
    }

    // MARK: - Real estate agents

    @ViewBuilder
    private var realEstateAgentSection: some View {
        let buyerHas = version.inspection.buyersAgent?.hasContent ?? false
        let listingHas = version.inspection.listingAgent?.hasContent ?? false
        let anyExpanded = showAgentsSection || buyerHas || listingHas

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Real Estate Agents")
                    .font(.headline)
                Spacer()
                if isEditable {
                    Button {
                        withAnimation { showAgentsSection.toggle() }
                    } label: {
                        Image(systemName: anyExpanded ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(anyExpanded ? "Collapse agents section" : "Expand agents section")
                }
            }
            if !isEditable {
                // Read-only: show only agents that have content.
                if let b = version.inspection.buyersAgent, b.hasContent {
                    agentReadOnlyCard(title: "Buyer's Agent", agent: b)
                }
                if let l = version.inspection.listingAgent, l.hasContent {
                    agentReadOnlyCard(title: "Listing Agent", agent: l)
                }
                if !buyerHas && !listingHas {
                    Text("No agents recorded for this inspection.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if anyExpanded {
                agentEditCard(title: "Buyer's Agent", keyPath: \.buyersAgent)
                agentEditCard(title: "Listing Agent", keyPath: \.listingAgent)
            } else {
                Text("Tap to add buyer's or listing agent details.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func agentReadOnlyCard(title: String, agent: RealEstateAgent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            if !agent.name.isEmpty { Text(agent.name) }
            if !agent.brokerage.isEmpty {
                Text(agent.brokerage).font(.caption).foregroundStyle(.secondary)
            }
            if !agent.phone.isEmpty {
                Text(agent.phone).font(.caption).foregroundStyle(.secondary)
            }
            if !agent.email.isEmpty {
                Text(agent.email).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func agentEditCard(title: String, keyPath: WritableKeyPath<Inspection, RealEstateAgent?>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            TextField("Name", text: agentBinding(keyPath, field: \.name))
                .textContentType(.name)
            TextField("Brokerage", text: agentBinding(keyPath, field: \.brokerage))
                .textContentType(.organizationName)
            TextField("Phone", text: agentBinding(keyPath, field: \.phone))
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                .phoneFormatted(agentBinding(keyPath, field: \.phone))
            TextField("Email", text: agentBinding(keyPath, field: \.email))
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
        }
        .padding(10)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    /// Bridges an optional `RealEstateAgent` field through to a `String`
    /// TextField binding. Auto-instantiates the agent on first edit so the
    /// inspector doesn't have to "create" it explicitly.
    private func agentBinding(
        _ agentKeyPath: WritableKeyPath<Inspection, RealEstateAgent?>,
        field: WritableKeyPath<RealEstateAgent, String>
    ) -> Binding<String> {
        Binding(
            get: { version.inspection[keyPath: agentKeyPath]?[keyPath: field] ?? "" },
            set: { newValue in
                var insp = version.inspection
                var agent = insp[keyPath: agentKeyPath] ?? RealEstateAgent()
                agent[keyPath: field] = newValue
                // Keep the agent if it has any content; otherwise drop back
                // to nil so we don't litter empty agents in the JSON.
                insp[keyPath: agentKeyPath] = agent.hasContent ? agent : nil
                var v = version
                v.inspection = insp
                version = v
            }
        )
    }

    // MARK: - Scheduling + Calendar

    @ViewBuilder
    private var schedulingSection: some View {
        SchedulingCard(
            version: $version,
            isEditable: isEditable
        )
    }

    @ViewBuilder
    private var exportOverlay: some View {
        if exportService.isExporting || exportService.errorMessage != nil {
                AppColor.brandNavy.opacity(0.4)
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
            report += "Room scans (LiDAR): \(lidarScans.map(\.displayName).joined(separator: ", "))\n\n"
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

// MARK: - SchedulingCard

/// Scheduling UI for an individual inspection:
///   - duration picker (default 4h, override allowed)
///   - Add / Update / Remove-from-Calendar actions
///   - Permission banner when EventKit access is insufficient
///
/// Lives next to the inspector's client/property/date edits so the whole
/// scheduling workflow is in one place. The month-grid view is for
/// visualizing; this card is for acting.
private struct SchedulingCard: View {
    @Binding var version: InspectionVersion
    let isEditable: Bool

    @ObservedObject private var calendarService = CalendarService.shared
    @EnvironmentObject private var authManager: AuthManager

    @State private var errorBanner: String?
    @State private var showSuccessCheck: Bool = false

    /// Picker values: 1, 2, 3, 4, 6, 8 hours. `nil` row = "Use default (4h)".
    private let durationOptions: [Int?] = [nil, 60, 120, 180, 240, 360, 480]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scheduling")
                .font(.headline)

            if isEditable {
                durationPicker
            } else {
                durationReadonly
            }

            calendarActionBar

            if let msg = errorBanner {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            permissionFootnote
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(8)
        .onAppear {
            calendarService.refreshAuthorizationState()
        }
    }

    // MARK: Duration

    private var durationPicker: some View {
        Picker("Duration", selection: durationBinding) {
            ForEach(durationOptions, id: \.self) { opt in
                Text(label(for: opt)).tag(opt)
            }
        }
    }

    private var durationReadonly: some View {
        HStack {
            Text("Duration")
            Spacer()
            Text(label(for: version.inspection.scheduledDurationMinutes))
                .foregroundStyle(.secondary)
        }
    }

    private var durationBinding: Binding<Int?> {
        Binding(
            get: { version.inspection.scheduledDurationMinutes },
            set: { newValue in
                var insp = version.inspection
                insp.scheduledDurationMinutes = newValue
                var v = version
                v.inspection = insp
                version = v
            }
        )
    }

    private func label(for option: Int?) -> String {
        guard let option else { return "Default (4 h)" }
        let hours = Double(option) / 60.0
        if hours == floor(hours) {
            return "\(Int(hours)) h"
        }
        return String(format: "%.1f h", hours)
    }

    // MARK: Action bar

    @ViewBuilder
    private var calendarActionBar: some View {
        if version.inspection.calendarEventIdentifier != nil {
            HStack(spacing: 10) {
                Button {
                    Task { await updateEvent() }
                } label: {
                    Label("Update Calendar Event", systemImage: "calendar.badge.clock")
                }
                .buttonStyle(.bordered)
                .disabled(!isEditable)

                Button(role: .destructive) {
                    Task { await removeEvent() }
                } label: {
                    Label("Remove", systemImage: "calendar.badge.minus")
                }
                .buttonStyle(.bordered)
                .disabled(!isEditable)

                if showSuccessCheck {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        } else {
            HStack {
                Button {
                    Task { await addEvent() }
                } label: {
                    Label("Add to Calendar", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isEditable || !calendarService.authorizationState.canCreateEvents)

                if showSuccessCheck {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
    }

    // MARK: Permission footnote

    @ViewBuilder
    private var permissionFootnote: some View {
        switch calendarService.authorizationState {
        case .notDetermined:
            Button("Allow Calendar Access") {
                Task { await calendarService.requestAccess() }
            }
            .font(.caption)
        case .denied, .restricted:
            Text("Calendar access is disabled. Enable it in Settings → NexGenSpec → Calendar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .writeOnly:
            Text("Write-Only access is on; full access recommended for conflict views.")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: Actions

    private func addEvent() async {
        errorBanner = nil
        // Prompt for access if necessary.
        if calendarService.authorizationState == .notDetermined {
            _ = await calendarService.requestAccess()
        }
        guard calendarService.authorizationState.canCreateEvents else {
            errorBanner = "Calendar access is required. Enable it in Settings."
            return
        }
        guard version.inspection.hasScheduledStartTime else {
            errorBanner = "Pick a start time (not midnight) before adding to Calendar."
            return
        }
        guard let cal = resolveCalendar() else {
            errorBanner = "No writable calendar is available on this device."
            return
        }
        do {
            let identifier = try calendarService.createEvent(
                for: version.inspection,
                in: cal
            )
            var insp = version.inspection
            insp.calendarEventIdentifier = identifier
            insp.calendarIdentifier = cal.calendarIdentifier
            var v = version
            v.inspection = insp
            version = v
            flashSuccess()
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    private func updateEvent() async {
        errorBanner = nil
        guard let id = version.inspection.calendarEventIdentifier else { return }
        guard calendarService.authorizationState.canCreateEvents else {
            errorBanner = "Calendar access is required."
            return
        }
        guard version.inspection.hasScheduledStartTime else {
            errorBanner = "Pick a start time (not midnight) before updating."
            return
        }
        do {
            try calendarService.updateEvent(eventIdentifier: id, for: version.inspection)
            flashSuccess()
        } catch CalendarServiceError.eventNotFound {
            // External deletion: forget the stored identifier, re-prompt.
            var insp = version.inspection
            insp.calendarEventIdentifier = nil
            insp.calendarIdentifier = nil
            var v = version
            v.inspection = insp
            version = v
            errorBanner = "This calendar event was removed outside NexGenSpec. Tap Add to Calendar to recreate it."
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    private func removeEvent() async {
        errorBanner = nil
        guard let id = version.inspection.calendarEventIdentifier else { return }
        do {
            try calendarService.deleteEvent(eventIdentifier: id)
            var insp = version.inspection
            insp.calendarEventIdentifier = nil
            insp.calendarIdentifier = nil
            var v = version
            v.inspection = insp
            version = v
            flashSuccess()
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    private func resolveCalendar() -> EKCalendar? {
        let email = authManager.currentUsername
        if let id = CalendarPreferences.defaultCalendarIdentifier(for: email),
           let cal = calendarService.calendar(withIdentifier: id),
           cal.allowsContentModifications {
            return cal
        }
        return calendarService.fallbackDefaultCalendar()
    }

    private func flashSuccess() {
        withAnimation { showSuccessCheck = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { showSuccessCheck = false }
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
