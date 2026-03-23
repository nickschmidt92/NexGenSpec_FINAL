//
//  RoomPlanCaptureBridge.swift
//  NexGenSpec
//
//  Wraps RoomPlan's RoomCaptureViewController for LiDAR room capture. Requires iOS 16+ and RoomPlan.framework linked in Xcode.
//

import Foundation
import SwiftUI
import UIKit

#if canImport(RoomPlan)
import RoomPlan
#endif

/// Callback when capture finishes: optional scan (nil if cancelled or error), and whether to dismiss.
typealias RoomPlanCaptureCompletion = (LiDARScan?, Bool) -> Void

#if canImport(RoomPlan)
@available(iOS 16.0, *)
final class RoomPlanCaptureCoordinator: NSObject, RoomCaptureViewDelegate, NSCoding {
    var onComplete: RoomPlanCaptureCompletion?
    var jobId: UUID?

    func encode(with coder: NSCoder) {}

    required init?(coder: NSCoder) { nil }

    override init() {
        super.init()
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    func captureView(didPresent processedResult: CapturedRoom?, error: Error?) {
        guard let completed = processedResult, let jobId = jobId else {
            DispatchQueue.main.async { [weak self] in self?.onComplete?(nil, true) }
            return
        }
        let scanId = UUID()
        let usdzFileName = "\(scanId.uuidString).usdz"
        let lidarDir = FilePaths.lidarFolder(jobId: jobId)
        let usdzURL = lidarDir.appendingPathComponent(usdzFileName)
        do {
            try FileSecurity.ensureProtectedDirectory(lidarDir)
            try completed.export(to: usdzURL, exportOptions: .mesh)
            let scan = LiDARScan(
                id: scanId,
                versionId: jobId,
                usdzFileName: usdzFileName,
                floorplanPNGFileName: nil,
                measurements: [],
                capturedAt: Date()
            )
            LiDARScanStore.save(scan, jobId: jobId)
            DispatchQueue.main.async { [weak self] in self?.onComplete?(scan, true) }
        } catch {
            DispatchQueue.main.async { [weak self] in self?.onComplete?(nil, true) }
        }
    }
}

@available(iOS 16.0, *)
struct RoomPlanCaptureViewControllerRepresentable: UIViewControllerRepresentable {
    var jobId: UUID
    var onComplete: RoomPlanCaptureCompletion

    func makeCoordinator() -> RoomPlanCaptureCoordinator {
        let c = RoomPlanCaptureCoordinator()
        c.jobId = jobId
        c.onComplete = onComplete
        return c
    }

    func makeUIViewController(context: Context) -> RoomCaptureHostController {
        let vc = RoomCaptureHostController()
        vc.captureView.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: RoomCaptureHostController, context: Context) {}
}

/// Hosts RoomCaptureView (UIKit) so we can set the delegate and present full-screen.
/// Starts the capture session when the view appears so the scan actually runs.
@available(iOS 16.0, *)
final class RoomCaptureHostController: UIViewController {
    let captureView = RoomCaptureView()

    override func loadView() {
        view = captureView
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let config = RoomCaptureSession.Configuration()
        captureView.captureSession.run(configuration: config)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureView.captureSession.stop()
    }
}
#endif
