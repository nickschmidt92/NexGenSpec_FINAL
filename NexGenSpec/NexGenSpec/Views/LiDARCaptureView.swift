//
//  LiDARCaptureView.swift
//  NexGenSpec
//
//  RoomPlan LiDAR capture: real capture on iOS 16+ with RoomPlan; lists saved scans; fallback on older or non-LiDAR.
//

import SwiftUI

struct LiDARCaptureView: View {
    var jobId: UUID
    var onScanSaved: ((LiDARScan) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var savedScans: [LiDARScan] = []
    @State private var showRoomPlanCapture = false
    @State private var lastSavedScan: LiDARScan?

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
            .fullScreenCover(isPresented: $showRoomPlanCapture) {
                roomPlanCaptureSheet
            }
        }
    }

    @ViewBuilder
    private var roomPlanCaptureSheet: some View {
        if #available(iOS 16.0, *) {
            #if canImport(RoomPlan)
            RoomPlanCaptureViewControllerRepresentable(jobId: jobId) { scan, shouldDismiss in
                if let scan = scan {
                    lastSavedScan = scan
                    onScanSaved?(scan)
                }
                showRoomPlanCapture = false
            }
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Button("Cancel") {
                    showRoomPlanCapture = false
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding()
            }
            #else
            Text("RoomPlan is not linked. Add RoomPlan.framework in Xcode.")
                .padding()
            Button("Close") { showRoomPlanCapture = false }
            #endif
        } else {
            Text("Room capture requires iOS 16 or later.")
            Button("Close") { showRoomPlanCapture = false }
        }
    }

    private var lidarSupportedContent: some View {
        List {
            Section {
                Button {
                    showRoomPlanCapture = true
                } label: {
                    Label("Capture room with LiDAR", systemImage: "square.viewfinder")
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
                                Text(scan.usdzFileName)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(scan.capturedAt, style: .date)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var unsupportedContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "square.viewfinder")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("LiDAR not available")
                .font(.title2)
            Text("Room capture requires a device with LiDAR (e.g. iPhone 12 Pro, iPad Pro).")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
