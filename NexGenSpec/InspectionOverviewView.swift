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
import AVKit

/// Shows the cover page for an inspection. Displays metadata and summary counts. Editable client/property/inspector when draft.
@available(iOS 16.0, *)
struct InspectionOverviewView: View {
    @Binding var version: InspectionVersion
    /// Tapping one of the Safety / Major / Marginal / Minor summary
    /// badges routes back to the parent InspectionView so it can
    /// switch to the Summary pane pre-filtered by that severity.
    /// Nil-safe so the Preview provider still compiles without a
    /// pane router.
    var onShowSummary: ((Severity) -> Void)? = nil
    @State private var shareContent: ShareContent?
    @State private var showLiDARCapture = false
    /// Saved LiDAR scans for this inspection, loaded from disk. Refreshed on
    /// appear and after the capture sheet closes so scans show up on the
    /// overview alongside photos and videos (previously they were only
    /// visible inside the capture sheet and the final report).
    @State private var lidarScans: [LiDARScan] = []
    @State private var selectedVideoItems: [PhotosPickerItem] = []
    /// Drives the video-library picker. A `PhotosPicker` placed directly
    /// inside a `Menu` never presents on iOS — the menu dismisses before the
    /// picker can open, so the row appeared to "do nothing". Instead the menu
    /// row is a plain Button that sets this flag, and a `.photosPicker(isPresented:)`
    /// modifier on the section presents the picker outside the menu lifecycle.
    @State private var showVideoLibraryPicker = false
    /// Drives the cover-photo picker. When non-nil, a fullScreenCover
    /// presents the appropriate UIImagePickerController. Set to nil
    /// from inside the onFinish callback to dismiss.
    ///
    /// Fresh-start rewrite (branch: feature/cover-photo-rebuild).
    /// The previous cover-photo stack went through four failed
    /// attempts — Menu+PhotosPicker, ActionSheet+photosPicker,
    /// fullScreenCover+async, sheet(item:)+photosPicker — none of
    /// which survived the "change after first capture" test on iOS 26.
    /// This single-enum-driven approach uses UIImagePickerController
    /// directly (pre-SwiftUI, zero iOS 26 lifecycle bugs).
    @State private var coverPhotoSource: CoverPhotoSource?
    /// Currently-playing video, drives the AVPlayer sheet. Replaces
    /// the old tap-does-nothing behavior where an uploaded video row
    /// was inert — a top complaint from the first TestFlight cohort.
    @State private var videoToPlay: InspectionVideo?
    /// Drives the rename alert for a video. When non-nil, an alert with a
    /// text field lets the inspector give the recording a friendly name
    /// (stored as the video's caption). TestFlight finding 2026-05-25:
    /// videos couldn't be renamed after capture.
    @State private var videoToRename: InspectionVideo?
    /// Drives the rename alert for a LiDAR room scan. When non-nil, an alert
    /// with a text field lets the inspector give the scan a friendly name
    /// (stored as the scan's `name`). Mirrors the video rename flow.
    @State private var scanToRename: LiDARScan?
    @State private var scanToPreview: LiDARScan?
    @State private var renameText: String = ""
    /// A clip that was just recorded and is waiting for the naming prompt.
    /// We don't present the prompt directly from the recorder's onRecorded
    /// callback because the recorder sheet is still dismissing — presenting
    /// then races the dismissal (the same class of bug that broke the cover
    /// photo flow). Instead we stash the video here and present the rename
    /// prompt from the sheet's onDismiss, mirroring the LiDAR naming flow.
    @State private var justRecordedVideo: InspectionVideo?
    /// Unified sheet router. Cover photo is NOT in this enum — it's
    /// driven separately by coverPhotoSource (see above) because the
    /// cover-photo path was rewritten to use UIImagePickerController
    /// directly, bypassing PhotosPicker entirely.
    @State private var activeSheet: OverviewSheet?

    enum OverviewSheet: Identifiable {
        case videoRecorder
        case inspectionDate
        var id: Int { hashValue }
    }
    @State private var showExportError = false
    @State private var showTextExportError = false
    @State private var showPaywall = false
    @State private var showAgentsSection: Bool = false
    @State private var coverPhotoTick: Int = 0   // bumps to invalidate cached preview after change
    // Serializes camera cover-photo writes: retakes target the same file
    // name, so a slow first write must not land after a faster second one.
    @State private var coverPhotoWriteTask: Task<Void, Never>?
    @StateObject private var exportService = ReportExportService()
    @EnvironmentObject private var subscriptions: SubscriptionManager

    private var isEditable: Bool { version.state.isEditable }
    private var jobId: UUID { UUID(uuidString: version.inspection.inspectionId) ?? version.id }

    /// Short, human-friendly job identifier displayed on the Overview.
    /// Matches the `NGS-YYYYMMDD-XXXX` format used on the PDF cover page
    /// so the inspector can reference either surface interchangeably.
    // Cached once — `shortJobId` is read from `body`, so building a new
    // DateFormatter on every render is pure waste.
    private static let shortJobIdDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private var shortJobId: String {
        let datePart = Self.shortJobIdDateFormatter.string(from: version.inspection.inspectionDate)
        let shortHash = String(version.inspection.inspectionId.replacingOccurrences(of: "-", with: "").prefix(4)).uppercased()
        return "NGS-\(datePart)-\(shortHash)"
    }

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
                    // Summary counts — each badge is tappable and jumps
                    // to the Summary pane pre-filtered by severity.
                    // Requested 2026-04-21: testers wanted a fast path
                    // from "Overview says 3 Safety items" straight to
                    // the filtered list without going through the
                    // sidebar. Same destination as Summary sidebar link,
                    // just with the filter set on arrival.
                    let counts = version.inspection.summaryCounts()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary")
                            .font(.headline)
                        HStack {
                            Button { onShowSummary?(.safety) } label: {
                                SummaryBadge(color: AppColor.safetyAccessible, label: "Safety", count: counts.safety)
                            }
                            .buttonStyle(.plain).hoverEffect(.lift)
                            .accessibilityHint("Shows all safety findings")
                            Button { onShowSummary?(.major) } label: {
                                SummaryBadge(color: AppColor.majorAccessible, label: "Major", count: counts.major)
                            }
                            .buttonStyle(.plain).hoverEffect(.lift)
                            .accessibilityHint("Shows all major findings")
                            Button { onShowSummary?(.marginal) } label: {
                                SummaryBadge(color: AppColor.marginalAccessible, label: "Marginal", count: counts.marginal)
                            }
                            .buttonStyle(.plain).hoverEffect(.lift)
                            .accessibilityHint("Shows all marginal findings")
                            Button { onShowSummary?(.minor) } label: {
                                SummaryBadge(color: AppColor.minorAccessible, label: "Minor", count: counts.minor)
                            }
                            .buttonStyle(.plain).hoverEffect(.lift)
                            .accessibilityHint("Shows all minor findings")
                        }
                    }
                    
                    // Weather info — gated behind AppCapabilities.weatherLoggingEnabled
                    // (currently enabled). Only renders once an Open-Meteo fetch has
                    // populated `weather`; on-device fetch failures are logged via
                    // os_log (category "Weather") for diagnosis.
                    if AppCapabilities.weatherLoggingEnabled, let weather = version.inspection.weather {
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

                    // Room Scans (LiDAR) — loaded from disk
                    roomScansSection

                    // Reminders + To-Do (per-inspection scratchpads)
                    remindersSection
                    todosSection

                    Spacer()
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { loadLiDARScans() }
            .onChange(of: selectedVideoItems) { _, newItems in
                guard let item = newItems.first else { return }
                Task {
                    await addVideoFromPickerItem(item)
                }
            }
            .navigationTitle("Overview")
            .toolbar {
                if LiDARCapability.isSupported && isEditable {
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
                            // Gate the plain-text summary behind Pro, mirroring the
                            // PDF export below. Without this a free user could export
                            // the full report content as clean, un-watermarked text
                            // and bypass the paywall entirely (B-0076).
                            guard subscriptions.hasFeatureAccess else {
                                showPaywall = true
                                return
                            }
                            let snapshot = version
                            Task {
                                // Build the summary and write the temp file off
                                // the main actor: LiDARScanStore does a JSON read
                                // per scan and FileSecurity a protected atomic
                                // write, both scaling with inspection size.
                                // `version` is a value type, so the detached task
                                // gets an immutable snapshot.
                                let url = await Task.detached(priority: .userInitiated) {
                                    ReportExporter.exportPlainText(for: snapshot)
                                }.value
                                await MainActor.run {
                                    if let url {
                                        shareContent = ShareContent(items: [url])
                                    } else {
                                        showTextExportError = true
                                    }
                                }
                            }
                        } label: { Label(subscriptions.hasFeatureAccess ? "Quick summary (text)" : "Quick summary (text) – Pro", systemImage: "doc.text") }
                            .accessibilityLabel("Quick summary text")
                            .accessibilityHint(subscriptions.hasFeatureAccess ? "Share plain text summary" : "Upgrade to Pro to export the text summary")
                            .disabled(isEditable)
                        Button {
                            Task {
                                await exportService.export(version: version, watermark: !subscriptions.hasFeatureAccess)
                                if case .success(_, let pdf) = exportService.result, let url = pdf {
                                    // Mirror into the Files-app folder organized
                                    // by address for one-tap access outside the app.
                                    FilesAppPublisher.publish(version: version, pdfURL: url)
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
            .sheet(isPresented: $showLiDARCapture, onDismiss: { loadLiDARScans() }) {
                LiDARCaptureView(
                    jobId: UUID(uuidString: version.inspection.inspectionId) ?? version.id,
                    // The save is async now: a scan that commits after this
                    // sheet's onDismiss fired would stay invisible until the
                    // next onAppear without this refresh.
                    onScanSaved: { _ in loadLiDARScans() }
                )
            }
            .sheet(item: $videoToPlay) { video in
                VideoPlayerSheet(
                    url: FilePaths.videosFolder(jobId: jobId).appendingPathComponent(video.fileName),
                    caption: video.caption.isEmpty ? video.fileName : video.caption
                )
            }
            .sheet(item: $scanToPreview) { scan in
                NavigationStack {
                    QuickLookPreview(
                        url: FilePaths.lidarFolder(jobId: jobId).appendingPathComponent(scan.usdzFileName)
                    )
                    .ignoresSafeArea()
                    .navigationTitle(scan.displayName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { scanToPreview = nil }
                        }
                    }
                }
            }
            .alert(
                "Rename Video",
                isPresented: Binding(
                    get: { videoToRename != nil },
                    set: { if !$0 { videoToRename = nil } }
                )
            ) {
                TextField("Video name", text: $renameText)
                Button("Save") { commitVideoRename() }
                Button("Cancel", role: .cancel) { videoToRename = nil }
            } message: {
                Text("Give this recording a name so it's easy to identify in the report.")
            }
            .alert(
                "Rename Room Scan",
                isPresented: Binding(
                    get: { scanToRename != nil },
                    set: { if !$0 { scanToRename = nil } }
                )
            ) {
                TextField("Room name", text: $renameText)
                Button("Save") { commitScanRename() }
                Button("Cancel", role: .cancel) { scanToRename = nil }
            } message: {
                Text("Give this scan a name (e.g. \"Living Room\") so it's easy to identify in the report.")
            }
            // fullScreenCover (not sheet) because UIImagePickerController
            // with sourceType = .camera wants the entire screen — using
            // .sheet was causing the sheet-dismissal state machine to
            // get stuck after the first capture, so subsequent Take
            // Cover photo picker — single UIImagePickerController
            // path for both camera and library. Completely separate
            // from the activeSheet router because the previous
            // "unified sheet" approach still broke on iOS 26 after
            // a cover photo was set. Decoupling gives the picker
            // its own presentation lifecycle.
            .fullScreenCover(item: $coverPhotoSource) { source in
                CoverPhotoPicker(source: source) { image in
                    if let image {
                        setCoverPhotoFromCapturedImage(image)
                    }
                    coverPhotoSource = nil
                }
                .ignoresSafeArea()
            }
            // Remaining sheet router: video recorder + inspection date.
            // onDismiss presents the naming prompt for a freshly-recorded clip
            // after the recorder sheet has fully dismissed (mirrors the LiDAR
            // naming flow, which presents in its capture cover's onDismiss to
            // avoid a present-during-dismiss race).
            .sheet(item: $activeSheet, onDismiss: {
                if let recorded = justRecordedVideo {
                    justRecordedVideo = nil
                    renameText = recorded.caption
                    videoToRename = recorded
                }
            }) { sheet in
                switch sheet {
                case .videoRecorder:
                    VideoRecorderView(
                        onRecorded: { tempURL in
                            // Save first, stash the result, then dismiss — the
                            // naming prompt fires from onDismiss above.
                            justRecordedVideo = addVideoFromRecordedURL(tempURL)
                            activeSheet = nil
                        },
                        onCancel: { activeSheet = nil }
                    )
                    .ignoresSafeArea()
                case .inspectionDate:
                    NavigationStack {
                        Form {
                            DatePicker(
                                "Inspection Date & Time",
                                selection: binding(\.inspectionDate),
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            .datePickerStyle(.graphical)
                        }
                        .navigationTitle("Inspection Date & Time")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { activeSheet = nil }
                            }
                        }
                    }
                    .presentationDetents([.medium, .large])
                }
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
            // Beta-requested (2026-04-22): surface a short Job ID so the
            // inspector can cross-reference this inspection with invoices,
            // emails, and client calls without having to open Finalize.
            // Format: NGS-YYYYMMDD-XXXX (first 4 hex of inspectionId uppercased).
            Text("Job ID: \(shortJobId)")
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
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
            // Inline DatePicker had two failed fixes (crash, then
            // unresponsive-after-set). Switched to a plain Button
            // that displays the current value and opens a dedicated
            // sheet with a full DatePicker inside. Rock-solid on
            // iOS 26 because SwiftUI doesn't have to animate the
            // picker in and out of the parent form.
            HStack {
                Label("Inspection Date & Time", systemImage: "calendar")
                Spacer()
                Button {
                    activeSheet = .inspectionDate
                } label: {
                    Text(version.inspection.inspectionDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain).hoverEffect(.lift)
            }
            TextField("Inspector Name", text: binding(\.inspectorName))
            // Job ID also visible in draft mode, not just read-only.
            // Beta feedback 2026-04-24: clarification that Job ID needs
            // to be on every inspection regardless of status.
            HStack {
                Text("Job ID:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(shortJobId)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    // MARK: - Reminders

    /// Simple per-inspection reminder list. Each row is one free-text
    /// note with an optional due date and a checkbox. Added in
    /// response to TestFlight feedback: testers wanted a scratchpad
    /// for things like "bring extension ladder" or "call client about
    /// gate code" without shoehorning them into an inspection item.
    @ViewBuilder
    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reminders")
                    .font(.headline)
                Spacer()
                if isEditable {
                    Button {
                        var insp = version.inspection
                        insp.reminders.append(InspectionReminder())
                        var v = version
                        v.inspection = insp
                        version = v
                    } label: {
                        Label("Add", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            if version.inspection.reminders.isEmpty {
                Text("No reminders. Tap Add to jot one down.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(version.inspection.reminders) { reminder in
                    ReminderRow(
                        reminder: reminderBinding(reminder.id),
                        isEditable: isEditable,
                        onDelete: { deleteReminder(id: reminder.id) }
                    )
                }
            }
        }
        // No card wrapper: keeps the "Reminders" header flush-left with the
        // other top-level sections (Drone / Video, Room Scans) so it reads as
        // a peer, not a sub-item nested under them.
    }

    // MARK: - To-Do

    /// Lightweight checklist bound to the inspection. Separate from
    /// Reminders so the two don't compete — todos are pure checkable
    /// action items; reminders can have times and lean more toward
    /// "don't forget" notes.
    @ViewBuilder
    private var todosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("To Do")
                    .font(.headline)
                Spacer()
                if isEditable {
                    Button {
                        var insp = version.inspection
                        insp.todos.append(InspectionTodo())
                        var v = version
                        v.inspection = insp
                        version = v
                    } label: {
                        Label("Add", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            if version.inspection.todos.isEmpty {
                Text("No tasks yet. Tap Add to create one.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(version.inspection.todos) { todo in
                    TodoRow(
                        todo: todoBinding(todo.id),
                        isEditable: isEditable,
                        onDelete: { deleteTodo(id: todo.id) }
                    )
                }
            }
        }
        // No card wrapper — see remindersSection: keeps "To Do" flush-left as a
        // top-level peer of Drone / Video and Room Scans rather than a sub-item.
    }

    private func reminderBinding(_ id: UUID) -> Binding<InspectionReminder> {
        Binding(
            get: {
                version.inspection.reminders.first(where: { $0.id == id }) ?? InspectionReminder(id: id)
            },
            set: { newValue in
                var insp = version.inspection
                if let idx = insp.reminders.firstIndex(where: { $0.id == id }) {
                    insp.reminders[idx] = newValue
                }
                var v = version
                v.inspection = insp
                version = v
            }
        )
    }

    private func todoBinding(_ id: UUID) -> Binding<InspectionTodo> {
        Binding(
            get: {
                version.inspection.todos.first(where: { $0.id == id }) ?? InspectionTodo(id: id)
            },
            set: { newValue in
                var insp = version.inspection
                if let idx = insp.todos.firstIndex(where: { $0.id == id }) {
                    insp.todos[idx] = newValue
                }
                var v = version
                v.inspection = insp
                version = v
            }
        )
    }

    private func deleteReminder(id: UUID) {
        var insp = version.inspection
        insp.reminders.removeAll { $0.id == id }
        var v = version
        v.inspection = insp
        version = v
    }

    private func deleteTodo(id: UUID) {
        var insp = version.inspection
        insp.todos.removeAll { $0.id == id }
        var v = version
        v.inspection = insp
        version = v
    }

    // MARK: - Drone / Video
    private var droneVideoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Drone / Video")
                    .font(.headline)
                Spacer()
                if isEditable {
                    // Menu: record new OR pick from library. Parallels
                    // the cover-photo Menu; testers asked for direct
                    // video capture rather than only upload.
                    Menu {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button {
                                activeSheet = .videoRecorder
                            } label: {
                                Label("Record Video", systemImage: "video.fill")
                            }
                        }
                        // Plain Button, NOT a PhotosPicker — a PhotosPicker
                        // inside a Menu never presents (the menu dismisses
                        // first). The picker is presented via the
                        // .photosPicker(isPresented:) modifier below.
                        Button {
                            showVideoLibraryPicker = true
                        } label: {
                            Label("Choose from Library", systemImage: "photo.on.rectangle")
                        }
                    } label: {
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
                        Button {
                            videoToPlay = video
                        } label: {
                            HStack(spacing: 12) {
                                // Play-badged video icon so the row's
                                // interactive affordance is obvious.
                                ZStack {
                                    Image(systemName: "video.fill")
                                        .foregroundColor(.secondary)
                                    Image(systemName: "play.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.white, Color.accentColor)
                                        .offset(x: 8, y: 8)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(video.caption.isEmpty ? video.fileName : video.caption)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    HStack(spacing: 6) {
                                        Text("Tap to play")
                                            .font(.caption)
                                            .foregroundColor(.accentColor)
                                        if let src = video.source, !src.isEmpty {
                                            Text("•")
                                                .foregroundStyle(.tertiary)
                                            Text(src)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain).hoverEffect(.lift)
                        if isEditable {
                            Button {
                                renameText = video.caption
                                videoToRename = video
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain).hoverEffect(.lift)
                            .accessibilityLabel("Rename video")
                            Button(role: .destructive) {
                                removeVideo(video)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain).hoverEffect(.lift)
                            .accessibilityLabel("Delete video")
                        }
                    }
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drone and video footage")
        // Presented outside the Menu so it actually opens. Result is handled
        // by the existing .onChange(of: selectedVideoItems) on the body.
        .photosPicker(
            isPresented: $showVideoLibraryPicker,
            selection: $selectedVideoItems,
            maxSelectionCount: 1,
            matching: .videos
        )
    }

    /// Handles a freshly-recorded video. UIImagePickerController hands
    /// us a URL to a temp file in the app sandbox; we copy it into
    /// this inspection's videos folder with a stable filename and
    /// append an InspectionVideo row to the model. Mirrors the
    /// library-upload path so both sources land the same way.
    /// Returns the created `InspectionVideo` so the caller can hand it to the
    /// post-recording naming prompt (nil if the copy failed).
    @discardableResult
    private func addVideoFromRecordedURL(_ tempURL: URL) -> InspectionVideo? {
        let fileName = "\(UUID().uuidString).mov"
        let videosDir = FilePaths.videosFolder(jobId: jobId)
        let destURL = videosDir.appendingPathComponent(fileName)
        do {
            try FileSecurity.ensureProtectedDirectory(videosDir)
            // Use copy then remove so a failure mid-write can't corrupt
            // anything — temp file is iOS's problem, not ours.
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: tempURL, to: destURL)
            let video = InspectionVideo(
                fileName: fileName,
                caption: "",
                sortOrder: version.inspection.videos.count,
                source: "walkthrough"
            )
            var insp = version.inspection
            insp.videos.append(video)
            var v = version
            v.inspection = insp
            version = v
            return video
        } catch {
            Diagnostics.logError(context: "addVideoFromRecordedURL failed", error: error)
            return nil
        }
    }

    /// Applies the pending rename to the video's caption. Empty input clears
    /// the caption (the row then falls back to showing the file name).
    private func commitVideoRename() {
        guard let target = videoToRename else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        var insp = version.inspection
        if let idx = insp.videos.firstIndex(where: { $0.id == target.id }) {
            insp.videos[idx].caption = trimmed
            var v = version
            v.inspection = insp
            version = v
        }
        videoToRename = nil
    }

    /// Removes a video from both the inspection model and the file
    /// system. Mirrors the existing photo-delete behavior.
    private func removeVideo(_ video: InspectionVideo) {
        let fileURL = FilePaths.videosFolder(jobId: jobId).appendingPathComponent(video.fileName)
        try? FileManager.default.removeItem(at: fileURL)
        var insp = version.inspection
        insp.videos.removeAll { $0.id == video.id }
        var v = version
        v.inspection = insp
        version = v
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
            // Write the (potentially tens-of-MB) imported video off the main
            // actor so large drone/walkthrough clips don't freeze the UI. `data`
            // and the URLs are Sendable, and FileSecurity's helpers are static
            // (already used off-main by the backup/ZIP export paths).
            try await Task.detached(priority: .userInitiated) {
                try FileSecurity.ensureProtectedDirectory(videosDir)
                try FileSecurity.writeProtected(data, to: fileURL)
            }.value
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

    // MARK: - Room Scans (LiDAR)

    /// Lists LiDAR scans saved for this inspection. Scans are persisted to
    /// disk by the capture flow (not stored in the Inspection JSON), so this
    /// section reads them from `LiDARScanStore` and shows each scan's name,
    /// capture date, and floor-plan thumbnail when one was rendered. This is
    /// what makes captured scans visible on the project page — they used to
    /// only surface inside the capture sheet and the final PDF.
    @ViewBuilder
    private var roomScansSection: some View {
        // Hide the whole section on devices that can't scan AND have no saved
        // scans — nothing to show or do there. On Mac (review station) we still
        // render it when empty so the "capture on iPhone/iPad" affordance shows;
        // the Capture button stays hidden there because it requires LiDAR support
        // (false on Mac), so no dead control appears (build 22 slice 5).
        if LiDARCapability.isSupported || !lidarScans.isEmpty || Platform.isMac {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Room Scans (LiDAR)")
                        .font(.headline)
                    Spacer()
                    if isEditable && LiDARCapability.isSupported {
                        Button {
                            showLiDARCapture = true
                        } label: {
                            Label("Capture", systemImage: "dot.viewfinder")
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityLabel("Capture room with LiDAR")
                    }
                }
                if lidarScans.isEmpty {
                    Text(LiDARCapability.isSupported
                         ? "No room scans yet. Tap Capture to scan a room with LiDAR."
                         : (Platform.isMac
                            ? "Capture room scans on your iPhone or iPad — they'll appear here for review."
                            : "No room scans attached."))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(lidarScans) { scan in
                        roomScanRow(scan)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Room scans captured with LiDAR")
        }
    }

    @ViewBuilder
    private func roomScanRow(_ scan: LiDARScan) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Tapping the thumbnail/name opens the captured USDZ in the system
            // QuickLook viewer (interactive 3D + AR). Previously the row showed
            // the scan but had no way to view it — an orphaned affordance.
            Button {
                scanToPreview = scan
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    if let thumb = loadFloorplanThumbnail(scan) {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color(.separator), lineWidth: 0.5)
                            )
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(.systemBackground))
                                .frame(width: 64, height: 64)
                            Image(systemName: "cube.transparent")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scan.displayName)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Text(scan.capturedAt, style: .date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let summary = scan.measurementsSummary {
                            Text(summary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Label("Tap to view 3D scan", systemImage: "cube.transparent")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View room scan \(scan.displayName)")
            .accessibilityHint("Opens the 3D scan in a viewer")
            Spacer(minLength: 0)
            // Share the raw USDZ so clients can open it in AR QuickLook on their
            // own device. ShareLink = system share sheet (iPad popover-safe).
            let usdzURL = FilePaths.lidarFolder(jobId: jobId).appendingPathComponent(scan.usdzFileName)
            if FileManager.default.fileExists(atPath: usdzURL.path) {
                ShareLink(item: usdzURL) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain).hoverEffect(.lift)
                .accessibilityLabel("Share 3D scan")
            }
            if isEditable {
                Button {
                    renameText = scan.name ?? ""
                    scanToRename = scan
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain).hoverEffect(.lift)
                .accessibilityLabel("Rename room scan")
                Button(role: .destructive) {
                    deleteLiDARScan(scan)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain).hoverEffect(.lift)
                .accessibilityLabel("Delete room scan")
            }
        }
        .padding(8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    private func loadLiDARScans() {
        lidarScans = LiDARScanStore.loadScans(jobId: jobId)
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    private func loadFloorplanThumbnail(_ scan: LiDARScan) -> UIImage? {
        guard let pngName = scan.floorplanPNGFileName else { return nil }
        let url = FilePaths.lidarFolder(jobId: jobId).appendingPathComponent(pngName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Applies the pending rename to the scan's `name` and persists it via
    /// `LiDARScanStore` (overwrites the scan's JSON record, the same store
    /// `deleteLiDARScan` works against). Empty input clears the name (the row
    /// then falls back to the USDZ filename via `displayName`). Mirrors the
    /// video rename flow.
    private func commitScanRename() {
        guard let target = scanToRename else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = target
        updated.name = trimmed.isEmpty ? nil : trimmed
        LiDARScanStore.save(updated, jobId: jobId)
        scanToRename = nil
        loadLiDARScans()
    }

    /// Removes a scan's record plus its USDZ, floor-plan, and room-JSON files from disk.
    private func deleteLiDARScan(_ scan: LiDARScan) {
        let dir = FilePaths.lidarFolder(jobId: jobId)
        let fm = FileManager.default
        try? fm.removeItem(at: dir.appendingPathComponent("\(scan.id.uuidString).json"))
        try? fm.removeItem(at: dir.appendingPathComponent(scan.usdzFileName))
        if let png = scan.floorplanPNGFileName {
            try? fm.removeItem(at: dir.appendingPathComponent(png))
        }
        if let roomJSON = scan.roomJSONFileName {
            try? fm.removeItem(at: dir.appendingPathComponent(roomJSON))
        }
        loadLiDARScans()
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
                    // Attempt 6 — root cause identified.
                    //
                    // Attempts 1-5 all chased a SwiftUI presentation-state
                    // ghost (Menu+PhotosPicker, ActionSheet, fullScreenCover
                    // with async reset, unified .sheet(item:) router,
                    // UIImagePickerController wrapper). None of them fixed
                    // the real problem because the real problem was NOT in
                    // how we presented the picker.
                    //
                    // The decisive clue was that Trash ALSO stopped
                    // responding after the first capture — and Trash
                    // calls removeCoverPhoto() directly with no sheet
                    // involved. So the buttons themselves weren't
                    // receiving taps.
                    //
                    // Root cause: the Image below used
                    //   .aspectRatio(contentMode: .fill)
                    //   .frame(height: 180)
                    //   .clipShape(RoundedRectangle(...))
                    // without a .clipped() modifier. .aspectRatio(.fill)
                    // makes the rendered Image overflow the 180pt frame.
                    // .clipShape only clips the painted pixels — it does
                    // NOT clip hit testing. The overflow extends upward
                    // into the HStack of Take/Library/Trash buttons, and
                    // because the Image is drawn AFTER the buttons in the
                    // VStack, it sits on top of them in z-order and eats
                    // every tap on those buttons. This only breaks after
                    // the first capture because the placeholder ZStack
                    // (shown when no photo is set) uses a fixed .frame(height: 120)
                    // with no .aspectRatio and therefore doesn't overflow.
                    //
                    // Fixes applied below:
                    //   1. .clipped() on the Image so hit testing is
                    //      constrained to the 180pt frame.
                    //   2. .contentShape(Rectangle()) on the Image to
                    //      belt-and-suspenders the hit-test boundary.
                    //   3. .zIndex(1) on this button HStack so even if
                    //      overflow were to still escape, buttons win.
                    //   4. .contentShape(Rectangle()) + explicit tap
                    //      area on each button so hit targets are always
                    //      the full button bounds.
                    HStack(spacing: 8) {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button {
                                Diagnostics.logInfo("CoverPhoto: Take tapped")
                                coverPhotoSource = .camera
                            } label: {
                                Label("Take", systemImage: "camera")
                                    .labelStyle(.titleAndIcon)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.bordered).hoverEffect(.lift)
                            .controlSize(.small)
                        }
                        Button {
                            Diagnostics.logInfo("CoverPhoto: Library tapped")
                            coverPhotoSource = .library
                        } label: {
                            Label("Library", systemImage: "photo.on.rectangle")
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered).hoverEffect(.lift)
                        .controlSize(.small)
                        if version.inspection.coverPhotoFileName != nil {
                            Button(role: .destructive) {
                                Diagnostics.logInfo("CoverPhoto: Trash tapped")
                                removeCoverPhoto()
                            } label: {
                                Image(systemName: "trash")
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.bordered).hoverEffect(.lift)
                            .controlSize(.small)
                            .tint(.red)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)   // keep the whole button row at natural width so nothing wraps
                    .zIndex(1)   // ensure buttons always above the image
                }
            }
            // Cover photo decodes OFF the main thread (was a synchronous
            // Data(contentsOf:)+UIImage decode in `body` on every render, which
            // hitched the overview while editing). `coverPhotoTick` invalidates
            // the load after a change; the placeholder reserves the image height
            // while decoding so the layout doesn't jump when it arrives.
            OverviewCoverPhoto(jobId: jobId,
                               fileName: version.inspection.coverPhotoFileName,
                               tick: coverPhotoTick)
        }
    }

    /// Handles camera-captured images for the cover photo. Mirrors
    /// `setCoverPhotoFromPickerItem` but skips the async Transferable
    /// loading since UIImagePickerController hands us a UIImage
    /// directly. Same downscale + JPEG compression as the library
    /// path so the file size on disk is consistent regardless of
    /// source.
    private func setCoverPhotoFromCapturedImage(_ image: UIImage) {
        let fileName = FilePaths.defaultCoverPhotoFileName
        let url = FilePaths.coverPhotoFile(jobId: jobId, fileName: fileName)
        let folder = FilePaths.inspectionFolder(jobId: jobId)
        coverPhotoWriteTask = Task { [previous = coverPhotoWriteTask] in
            await previous?.value
            do {
                // Downscale + JPEG-encode + write the ~12MP camera frame off
                // the main actor so the fullScreenCover dismissal doesn't
                // hitch. UIImage is immutable and UIGraphicsImageRenderer /
                // jpegData are safe off-main; FileSecurity helpers are static.
                let wrote = try await Task.detached(priority: .userInitiated) { () -> Bool in
                    let resized = image.resizedKeepingAspect(maxSide: 1600)
                    guard let jpegData = resized.jpegData(compressionQuality: 0.82) else { return false }
                    try FileSecurity.ensureProtectedDirectory(folder)
                    try FileSecurity.writeProtected(jpegData, to: url)
                    return true
                }.value
                guard wrote else { return }
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
                Diagnostics.logError(context: "setCoverPhotoFromCapturedImage failed", error: error)
            }
        }
    }

    private func removeCoverPhoto() {
        // Serialized through the same chain as the writes: a delete tapped
        // while a retake's write is still in flight must not be undone by
        // that write's publish landing afterwards.
        coverPhotoWriteTask = Task { [previous = coverPhotoWriteTask] in
            await previous?.value
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
                        .buttonStyle(.borderedProminent).hoverEffect(.lift)
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
    /// Debounced auto-sync handle. When the inspector changes date,
    /// duration, client name, or address on an inspection that already
    /// has a linked calendar event, we push the update to EventKit
    /// automatically — no manual "Update Calendar Event" tap. This
    /// Task is the pending debounce so rapid edits (e.g. scrubbing a
    /// date picker) collapse into a single EventKit write.
    @State private var autoSyncTask: Task<Void, Never>?

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
        // Auto-sync triggers. We watch the four fields that map into
        // an EKEvent (start time, duration, event title = client name,
        // location = property address). Any edit kicks the debounce.
        .onChange(of: version.inspection.inspectionDate) { _, _ in
            scheduleAutoSync()
        }
        .onChange(of: version.inspection.scheduledDurationMinutes) { _, _ in
            scheduleAutoSync()
        }
        .onChange(of: version.inspection.clientName) { _, _ in
            scheduleAutoSync()
        }
        .onChange(of: version.inspection.propertyAddress) { _, _ in
            scheduleAutoSync()
        }
        .onDisappear {
            autoSyncTask?.cancel()
        }
    }

    /// Debounced push to EventKit. Runs only when an existing event is
    /// linked — we never create an event automatically (that still
    /// requires the explicit "Add to Calendar" tap so the user opts in
    /// to calendar integration per-inspection). 600ms debounce swallows
    /// date-scrubbing and rapid typing. Errors go to the banner so the
    /// manual "Update Calendar Event" button can be used as a retry.
    private func scheduleAutoSync() {
        autoSyncTask?.cancel()
        guard isEditable,
              version.inspection.calendarEventIdentifier != nil,
              version.inspection.hasScheduledStartTime,
              calendarService.authorizationState.canCreateEvents else { return }
        autoSyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            await updateEvent()
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
            VStack(alignment: .leading, spacing: 6) {
                // Status line replaces the old primary-action wording.
                // Changes to date / duration / client / address now
                // auto-sync after a short debounce, so the user rarely
                // needs to tap the manual sync button below.
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.icloud")
                        .foregroundStyle(.green)
                    Text("Calendar event linked — auto-syncs on edit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if showSuccessCheck {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await updateEvent() }
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered).hoverEffect(.lift)
                    .controlSize(.small)
                    .disabled(!isEditable)

                    Button(role: .destructive) {
                        Task { await removeEvent() }
                    } label: {
                        Label("Remove", systemImage: "calendar.badge.minus")
                    }
                    .buttonStyle(.bordered).hoverEffect(.lift)
                    .controlSize(.small)
                    .disabled(!isEditable)
                }
            }
        } else {
            HStack {
                Button {
                    Task { await addEvent() }
                } label: {
                    Label("Add to Calendar", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.borderedProminent).hoverEffect(.lift)
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


// MARK: - VideoPlayerSheet

/// Lightweight full-screen video player used by the Drone / Video
/// section on the inspection overview. Uses AVKit's VideoPlayer so
/// the inspector gets the standard scrubber + AirPlay controls for
/// free. Pauses automatically on dismiss.
private struct VideoPlayerSheet: View {
    let url: URL
    let caption: String
    @State private var player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    init(url: URL, caption: String) {
        self.url = url
        self.caption = caption
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(caption)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .onAppear { player.play() }
                .onDisappear { player.pause() }
        }
    }
}

// MARK: - ReminderRow

private struct ReminderRow: View {
    @Binding var reminder: InspectionReminder
    let isEditable: Bool
    var onDelete: () -> Void
    @State private var showDatePicker = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                reminder.isCompleted.toggle()
            } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(reminder.isCompleted ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain).hoverEffect(.lift)
            .disabled(!isEditable)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Reminder", text: $reminder.text, axis: .vertical)
                    .font(.subheadline)
                    .strikethrough(reminder.isCompleted)
                    .foregroundStyle(reminder.isCompleted ? .secondary : .primary)
                    .disabled(!isEditable)
                HStack(spacing: 8) {
                    Button {
                        if reminder.dueAt == nil {
                            reminder.dueAt = Calendar.current.date(byAdding: .day, value: 1, to: Date())
                        }
                        showDatePicker = true
                    } label: {
                        if let due = reminder.dueAt {
                            Label(due.formatted(date: .abbreviated, time: .shortened),
                                  systemImage: "bell.fill")
                                .font(.caption)
                                .foregroundStyle(Color.orange)
                        } else {
                            Label("Add due date", systemImage: "bell")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain).hoverEffect(.lift)
                    .disabled(!isEditable)
                    if reminder.dueAt != nil {
                        Button {
                            reminder.dueAt = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain).hoverEffect(.lift)
                        .disabled(!isEditable)
                        .accessibilityLabel("Clear due date")
                    }
                }
            }

            Spacer(minLength: 0)

            if isEditable {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain).hoverEffect(.lift)
                .accessibilityLabel("Delete reminder")
            }
        }
        .padding(8)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .sheet(isPresented: $showDatePicker) {
            NavigationStack {
                Form {
                    DatePicker("Due",
                               selection: Binding(
                                    get: { reminder.dueAt ?? Date() },
                                    set: { reminder.dueAt = $0 }),
                               displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                }
                .navigationTitle("Due Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showDatePicker = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

// MARK: - TodoRow

private struct TodoRow: View {
    @Binding var todo: InspectionTodo
    let isEditable: Bool
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                todo.isCompleted.toggle()
            } label: {
                Image(systemName: todo.isCompleted ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(todo.isCompleted ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain).hoverEffect(.lift)
            .disabled(!isEditable)

            TextField("Task", text: $todo.text, axis: .vertical)
                .font(.subheadline)
                .strikethrough(todo.isCompleted)
                .foregroundStyle(todo.isCompleted ? .secondary : .primary)
                .disabled(!isEditable)

            Spacer(minLength: 0)

            if isEditable {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain).hoverEffect(.lift)
                .accessibilityLabel("Delete task")
            }
        }
        .padding(8)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Cover Photo (async)

/// Loads the inspection cover photo off the main thread and shows a
/// height-reserving placeholder while it decodes, so the Overview no longer
/// does a synchronous disk read + image decode in `body` on every render.
/// `tick` is the parent's `coverPhotoTick` — bumping it re-runs the load after
/// the cover photo is changed or removed.
private struct OverviewCoverPhoto: View {
    let jobId: UUID
    let fileName: String?
    let tick: Int
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipped()   // CRITICAL: clips hit testing, not just paint
                    .contentShape(Rectangle())   // belt-and-suspenders hit-test boundary
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .allowsHitTesting(false)   // the image itself is not interactive
                    .accessibilityLabel("Cover photo of the property")
            } else if fileName != nil {
                // A cover exists and is decoding off-main — reserve its final
                // height so the layout doesn't jump when the image lands.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.systemGray6))
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .overlay { ProgressView() }
                    .allowsHitTesting(false)
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
                .allowsHitTesting(false)   // placeholder is not interactive
            }
        }
        .task(id: "\(fileName ?? "∅")#\(tick)") {
            await load()
        }
    }

    private func load() async {
        guard let fileName else { image = nil; return }
        let url = FilePaths.coverPhotoFile(jobId: jobId, fileName: fileName)
        let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        image = loaded
    }
}
