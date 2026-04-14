//
//  RoomPlanCaptureBridge.swift
//  NexGenSpec
//
//  Wraps RoomPlan's RoomCaptureViewController for LiDAR room capture.
//  After the user taps "Done" the scan is processed and returned to SwiftUI
//  so it can prompt for a name BEFORE writing anything to disk. Persistence
//  lives in LiDARScanPersistence.save(...).
//  Requires iOS 16+ and RoomPlan.framework linked in Xcode.
//

import Foundation
import SwiftUI
import UIKit

#if canImport(RoomPlan)
import RoomPlan
#endif

#if canImport(RoomPlan)

/// SwiftUI-visible ready state for a captured room that is awaiting a name.
/// Holds the `CapturedRoom` opaquely so SwiftUI files don't need to reach
/// into RoomPlan types for storage.
@available(iOS 16.0, *)
@MainActor
final class LiDARCapturePending: ObservableObject {
    /// True once RoomPlan has finished processing and we're waiting for the user to name it.
    @Published var isReady: Bool = false
    /// True while the capture view is dismissed and we're asking for a name.
    @Published var isNaming: Bool = false

    fileprivate var capturedRoom: CapturedRoom?

    func reset() {
        capturedRoom = nil
        isReady = false
        isNaming = false
    }

    /// Atomically take ownership of the captured room (clears the stored one).
    func takeRoom() -> CapturedRoom? {
        let r = capturedRoom
        capturedRoom = nil
        return r
    }
}

@available(iOS 16.0, *)
final class RoomPlanCaptureCoordinator: NSObject, RoomCaptureViewDelegate, NSCoding {
    weak var pending: LiDARCapturePending?

    func encode(with coder: NSCoder) {}
    required init?(coder: NSCoder) { nil }
    override init() { super.init() }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    func captureView(didPresent processedResult: CapturedRoom?, error: Error?) {
        // Hand the processed room to SwiftUI so it can present a naming prompt.
        // Persistence is deferred until the user taps "Save" in that prompt.
        DispatchQueue.main.async { [weak self] in
            guard let pending = self?.pending else { return }
            pending.capturedRoom = processedResult
            pending.isReady = (processedResult != nil)
        }
    }
}

@available(iOS 16.0, *)
struct RoomPlanCaptureViewControllerRepresentable: UIViewControllerRepresentable {
    @ObservedObject var pending: LiDARCapturePending
    var onCancel: () -> Void

    func makeCoordinator() -> RoomPlanCaptureCoordinator {
        let c = RoomPlanCaptureCoordinator()
        c.pending = pending
        return c
    }

    func makeUIViewController(context: Context) -> RoomCaptureHostController {
        let vc = RoomCaptureHostController()
        vc.captureView.delegate = context.coordinator
        vc.onDoneTapped = { [weak vc] in
            // Finalize capture — triggers processing, which fires the delegate
            // method and sets pending.isReady.
            vc?.captureView.captureSession.stop()
        }
        vc.onCancelTapped = {
            onCancel()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: RoomCaptureHostController, context: Context) {}
}

/// Hosts RoomCaptureView (UIKit) with explicit "Done" and "Cancel" buttons.
/// Starts the capture session when the view appears.
@available(iOS 16.0, *)
final class RoomCaptureHostController: UIViewController {
    let captureView = RoomCaptureView()

    var onDoneTapped: (() -> Void)?
    var onCancelTapped: (() -> Void)?

    private let doneButton: UIButton = {
        var cfg = UIButton.Configuration.filled()
        cfg.title = "Done"
        cfg.image = UIImage(systemName: "checkmark.circle.fill")
        cfg.imagePadding = 6
        cfg.baseBackgroundColor = .systemGreen
        cfg.baseForegroundColor = .white
        cfg.cornerStyle = .capsule
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)
        let b = UIButton(configuration: cfg)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        return b
    }()

    private let cancelButton: UIButton = {
        var cfg = UIButton.Configuration.gray()
        cfg.title = "Cancel"
        cfg.baseForegroundColor = .white
        cfg.cornerStyle = .capsule
        cfg.background.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        let b = UIButton(configuration: cfg)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        return b
    }()

    override func loadView() {
        view = captureView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(doneButton)
        view.addSubview(cancelButton)

        doneButton.addTarget(self, action: #selector(tappedDone), for: .touchUpInside)
        cancelButton.addTarget(self, action: #selector(tappedCancel), for: .touchUpInside)

        NSLayoutConstraint.activate([
            doneButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            doneButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            cancelButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
        ])
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

    @objc private func tappedDone() {
        // Disable Done to avoid double-fire, but leave Cancel enabled so the
        // user can back out if processing stalls.
        doneButton.isEnabled = false
        onDoneTapped?()
    }

    @objc private func tappedCancel() {
        doneButton.isEnabled = false
        cancelButton.isEnabled = false
        onCancelTapped?()
    }
}

// MARK: - Persistence

@available(iOS 16.0, *)
enum LiDARScanPersistence {

    /// Persist a processed CapturedRoom to disk: USDZ export, floor-plan PNG
    /// render, and a LiDARScan record. Returns the saved scan on success.
    @MainActor
    static func save(room: CapturedRoom, jobId: UUID, name: String?) -> LiDARScan? {
        let scanId = UUID()
        let usdzFileName = "\(scanId.uuidString).usdz"
        let lidarDir = FilePaths.lidarFolder(jobId: jobId)
        let usdzURL = lidarDir.appendingPathComponent(usdzFileName)

        do {
            try FileSecurity.ensureProtectedDirectory(lidarDir)
            try room.export(to: usdzURL, exportOptions: .mesh)

            // Render a top-down 2D floor plan PNG alongside the USDZ.
            var floorplanFileName: String? = nil
            if let pngData = FloorplanRenderer.renderPNG(from: room) {
                let pngFileName = "\(scanId.uuidString)_floorplan.png"
                let pngURL = lidarDir.appendingPathComponent(pngFileName)
                do {
                    try pngData.write(to: pngURL, options: .atomic)
                    floorplanFileName = pngFileName
                } catch {
                    // Non-fatal: scan still usable without floor-plan image.
                }
            }

            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let scan = LiDARScan(
                id: scanId,
                versionId: jobId,
                usdzFileName: usdzFileName,
                floorplanPNGFileName: floorplanFileName,
                name: (trimmed?.isEmpty == false) ? trimmed : nil,
                measurements: [],
                capturedAt: Date()
            )
            LiDARScanStore.save(scan, jobId: jobId)
            return scan
        } catch {
            return nil
        }
    }
}

#endif
