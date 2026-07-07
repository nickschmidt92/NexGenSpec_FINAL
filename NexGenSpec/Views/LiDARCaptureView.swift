//
//  LiDARCaptureView.swift
//  NexGenSpec
//
//  RoomPlan LiDAR capture: real capture on iOS 16+ with RoomPlan; lists saved
//  scans; fallback on older or non-LiDAR. After a scan completes, prompts the
//  user for a name before writing to disk.
//

import SwiftUI
import Combine

struct LiDARCaptureView: View {
    var jobId: UUID
    /// Section this capture is pre-linked to (per-section entry point). nil from
    /// the Overview entry points — scan stays unlinked.
    var sectionId: UUID? = nil
    /// Prefill for the naming sheet (e.g. the section title). User can edit.
    var defaultName: String? = nil
    var onScanSaved: ((LiDARScan) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var savedScans: [LiDARScan] = []
    @State private var showRoomPlanCapture = false
    @State private var lastSavedScan: LiDARScan?

    #if canImport(RoomPlan)
    @StateObject private var pending = pendingHolder()

    // Wrapped factory so the @available class isn't referenced at type-resolution time.
    private static func pendingHolder() -> LiDARCapturePendingBox {
        LiDARCapturePendingBox()
    }
    #endif

    @State private var pendingName: String = ""
    @State private var showNamingSheet = false
    @State private var showSaveError = false

    var body: some View {
        NavigationStack {
            Group {
                if LiDARCapability.isSupported {
                    lidarSupportedContent
                } else {
                    unsupportedContent
                }
            }
            .navigationTitle("Room Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                savedScans = LiDARScanStore.loadScans(jobId: jobId)
            }
            .onChange(of: lastSavedScan) { _, _ in
                savedScans = LiDARScanStore.loadScans(jobId: jobId)
            }
            .fullScreenCover(isPresented: $showRoomPlanCapture, onDismiss: {
                // After the capture cover fully finishes its dismissal animation,
                // present the naming sheet if the user saved a scan. Cancel
                // resets `isReady` to false, so cancelled flows skip this.
                // Read the authoritative source (inner) so this works even if
                // the box's Combine mirror failed to propagate.
                #if canImport(RoomPlan)
                if #available(iOS 16.0, *), pending.inner.isReady {
                    pendingName = defaultName ?? ""
                    showNamingSheet = true
                }
                #endif
            }) {
                roomPlanCaptureSheet
            }
            .sheet(isPresented: $showNamingSheet) {
                namingSheet
            }
        }
    }

    // MARK: - RoomPlan capture sheet

    @ViewBuilder
    private var roomPlanCaptureSheet: some View {
        if #available(iOS 16.0, *) {
            #if canImport(RoomPlan)
            RoomPlanCaptureViewControllerRepresentable(
                pending: pending.inner,
                onCancel: {
                    pending.inner.reset()
                    showRoomPlanCapture = false
                },
                onSaveRequested: {
                    // User tapped "Save Scan" after processing. Dismiss the cover;
                    // onDismiss will then present the naming sheet.
                    showRoomPlanCapture = false
                }
            )
            .ignoresSafeArea()
            #else
            VStack(spacing: 16) {
                Text("RoomPlan is not linked. Add RoomPlan.framework in Xcode.")
                    .multilineTextAlignment(.center)
                    .padding()
                Button("Close") { showRoomPlanCapture = false }
            }
            #endif
        } else {
            VStack(spacing: 16) {
                Text("Room capture requires iOS 16 or later.")
                Button("Close") { showRoomPlanCapture = false }
            }
        }
    }

    // MARK: - Naming sheet

    @ViewBuilder
    private var namingSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Living Room", text: $pendingName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(false)
                        .submitLabel(.done)
                } header: {
                    Text("Name this scan")
                } footer: {
                    Text("Optional. A label helps you identify rooms later in reports.")
                }
            }
            .navigationTitle("Save Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) {
                        #if canImport(RoomPlan)
                        pending.inner.reset()
                        #endif
                        showNamingSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        persistPendingScan()
                    }
                }
            }
            // Attached to the naming sheet's OWN NavigationStack (not the parent) so a
            // save-failure alert presents FROM the sheet's controller and appears over
            // it — keeping the sheet open for retry. Anchored on the parent it would be
            // covered by this sheet and never show (SwiftUI defers a second modal on one
            // host controller), leaving the sheet looking frozen. Mirrors SignatureView.
            .alert("Couldn't Save Scan", isPresented: $showSaveError) {
                Button("OK") { showSaveError = false }
            } message: {
                Text("The room scan couldn't be saved to this device. Please try again.")
            }
        }
        .presentationDetents([.medium])
    }

    private func persistPendingScan() {
        #if canImport(RoomPlan)
        if #available(iOS 16.0, *) {
            let name = pendingName.trimmingCharacters(in: .whitespacesAndNewlines)
            // Peek (non-consuming): the captured room MUST survive a failed save so
            // the user can retry. It is cleared via `reset()` only on save SUCCESS
            // (below), Discard, or Cancel — never merely by starting a save attempt.
            // Using takeRoom() here would clear it before the async save resolves, so
            // a retry after a transient failure would find nothing and silently lose
            // the (iPad-only) capture.
            if let room = pending.inner.peekRoom() {
                Task { @MainActor in
                    // Hold a background-task assertion across the save: the
                    // sheet dismisses immediately, so the user may background
                    // or lock the iPad while the 0.5-5s USDZ export is still
                    // writing — without this, a suspension can kill the
                    // process before the record commits and silently lose
                    // the named scan.
                    var bgTask: UIBackgroundTaskIdentifier = .invalid
                    bgTask = UIApplication.shared.beginBackgroundTask(withName: "LiDARScanSave") {
                        if bgTask != .invalid {
                            UIApplication.shared.endBackgroundTask(bgTask)
                            bgTask = .invalid
                        }
                    }
                    // USDZ export + floor-plan render + record commit run off
                    // the main actor; the scan publishes via onScanSaved once
                    // the record is on disk.
                    let scan = await LiDARScanPersistence.save(room: room, jobId: jobId, name: name.isEmpty ? nil : name, sectionId: sectionId)
                    if let scan {
                        lastSavedScan = scan
                        onScanSaved?(scan)
                        // Advance the pending generation only now that the room is
                        // committed, so a Done-then-Cancel fallback can't resurface it.
                        pending.inner.reset()
                        showNamingSheet = false          // dismiss ONLY on success
                    } else {
                        // Save failed: keep the naming sheet open and surface an
                        // error so the user can retry rather than silently lose an
                        // iPad-only LiDAR capture. Do NOT reset pending state or
                        // dismiss on this path.
                        showSaveError = true
                    }
                    if bgTask != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTask)
                        bgTask = .invalid
                    }
                }
            } else {
                // No captured room to persist (nothing taken) — dismiss the sheet.
                pending.inner.reset()
                showNamingSheet = false
            }
        }
        #endif
    }

    // MARK: - Content

    private var lidarSupportedContent: some View {
        List {
            Section {
                Button {
                    #if canImport(RoomPlan)
                    if #available(iOS 16.0, *) {
                        pending.inner.reset()
                    }
                    #endif
                    showRoomPlanCapture = true
                } label: {
                    Label("Capture room with LiDAR", systemImage: "dot.viewfinder")
                        .font(.headline)
                }
                .accessibilityLabel("Capture room with LiDAR")
                .accessibilityHint("Opens RoomPlan to scan the room and save a 3D model")
            } header: {
                Text("New scan")
            } footer: {
                Text("Uses RoomPlan to create a 3D model (USDZ) of the room. Requires iOS 16+ and RoomPlan.framework linked in Xcode.")
            }

            if !savedScans.isEmpty {
                Section("Saved scans") {
                    ForEach(savedScans) { scan in
                        HStack {
                            Image(systemName: "cube.transparent")
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(scan.displayName)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(scan.capturedAt, style: .date)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let summary = scan.measurementsSummary {
                                    Text(summary)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var unsupportedContent: some View {
        // Show this message only on platforms where iPhone LiDAR availability matters.
        // Update this comment and conditions if new iPhone models gain LiDAR support.
        VStack(spacing: 24) {
            Image(systemName: "dot.viewfinder")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("LiDAR room capture is not available on iPhone. This feature is only supported on iPad Pro and iPhone Pro models with LiDAR sensors.")
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .foregroundColor(.primary)
            Text("You can still enter measurements and attach photos manually.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#if canImport(RoomPlan)
/// Non-generic box so SwiftUI's @StateObject can reference it from a view that
/// doesn't carry @available(iOS 16.0, *). The inner pending holder is created
/// on-demand at iOS 16+ and exposed via `inner`.
@MainActor
final class LiDARCapturePendingBox: ObservableObject {
    @Published private(set) var isReady: Bool = false
    private var _inner: AnyObject?
    private var cancellable: Any?

    @available(iOS 16.0, *)
    var inner: LiDARCapturePending {
        if let existing = _inner as? LiDARCapturePending { return existing }
        let holder = LiDARCapturePending()
        _inner = holder
        // Mirror `holder.isReady` onto our @Published so the parent view can observe it.
        let sub = holder.$isReady.sink { [weak self] value in
            self?.isReady = value
        }
        cancellable = sub
        return holder
    }
}

#endif
