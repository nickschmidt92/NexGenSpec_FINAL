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
final class RoomPlanCaptureCoordinator: NSObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate, NSCoding {
    weak var pending: LiDARCapturePending?

    /// True once the user tapped Done. The session-delegate fallback must not
    /// build a room for a cancel/teardown stop() — that wasted seconds of CPU
    /// and could set pending.isReady AFTER a cancel reset, resurrecting the
    /// naming sheet for a discarded scan.
    var finishRequested = false

    /// Fires when the underlying RoomCaptureSession reports an unrecoverable
    /// failure (ARKit tracking lost, sensor blocked, etc.). Host controller
    /// uses this to surface an actionable alert instead of leaving the user
    /// staring at a frozen scan UI.
    var onSessionFailed: ((Error) -> Void)?

    /// Held so we can process `CapturedRoomData` ourselves as a fallback path
    /// when the view-delegate `didPresent` callback doesn't fire (observed in
    /// the wild on some devices — session ends but the preview never finalizes).
    private var roomBuilder: RoomBuilder?

    func encode(with coder: NSCoder) {}
    required init?(coder: NSCoder) { nil }
    override init() {
        super.init()
        self.roomBuilder = RoomBuilder(options: [.beautifyObjects])
    }

    // MARK: - RoomCaptureViewDelegate (primary path)

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    func captureView(didPresent processedResult: CapturedRoom?, error: Error?) {
        // Primary path: the view delegate hands us the processed room once
        // the post-scan preview is rendered.
        DispatchQueue.main.async { [weak self] in
            guard let pending = self?.pending else { return }
            guard !pending.isReady else { return }   // fallback path already won
            pending.capturedRoom = processedResult
            pending.isReady = (processedResult != nil)
        }
    }

    // MARK: - RoomCaptureSessionDelegate (fallback path)

    /// Fires when `captureSession.stop()` has ended the scan. This runs even
    /// when the view delegate's `didPresent` doesn't, so we process the raw
    /// `CapturedRoomData` ourselves and feed the result back into `pending`.
    func captureSession(_ session: RoomCaptureSession,
                        didEndWith data: CapturedRoomData,
                        error: Error?) {
        if let error = error {
            // RoomPlan reports unrecoverable failures (tracking lost, sensor
            // blocked, low-light) through this error param — there is no separate
            // didFailWith delegate method. Surface it instead of swallowing.
            DispatchQueue.main.async { [weak self] in
                self?.onSessionFailed?(error)
            }
            return
        }
        guard finishRequested else { return }   // stop() came from cancel/teardown, not Done
        guard let builder = self.roomBuilder else { return }
        // Capture `pending` strongly into the Task so we don't have to touch
        // `self` from the concurrent context (Swift 6 rejects that). The
        // strong hold only lasts for the single RoomBuilder call, which is
        // exactly as long as we need the pending state alive.
        guard let pending = self.pending else { return }
        Task {
            // Grace period: the view delegate's didPresent usually delivers the
            // processed room within a few seconds. Only run our own RoomBuilder
            // (a full duplicate pipeline) if it hasn't. Stays well inside the
            // 45 s processing timeout.
            try? await Task.sleep(for: .seconds(10))
            let alreadyDelivered = await MainActor.run { pending.isReady }
            guard !alreadyDelivered else { return }
            do {
                let room = try await builder.capturedRoom(from: data)
                await MainActor.run {
                    guard !pending.isReady else { return }   // primary path won during build
                    pending.capturedRoom = room
                    pending.isReady = true
                }
            } catch {
                // Swallow — the host controller's timeout will surface an
                // error to the user if neither path produces a room.
            }
        }
    }
}

@available(iOS 16.0, *)
struct RoomPlanCaptureViewControllerRepresentable: UIViewControllerRepresentable {
    @ObservedObject var pending: LiDARCapturePending
    var onCancel: () -> Void
    var onSaveRequested: () -> Void

    func makeCoordinator() -> RoomPlanCaptureCoordinator {
        let c = RoomPlanCaptureCoordinator()
        c.pending = pending
        return c
    }

    func makeUIViewController(context: Context) -> RoomCaptureHostController {
        let vc = RoomCaptureHostController()
        // Wire BOTH delegates — view (primary) + session (fallback). Whichever
        // fires first produces the CapturedRoom and sets pending.isReady.
        vc.captureView.delegate = context.coordinator
        vc.captureView.captureSession.delegate = context.coordinator
        let coordinator = context.coordinator
        vc.onDoneTapped = { [weak vc] in
            // Finalize capture — triggers processing. When processing completes,
            // `pending.isReady` becomes true (either via the view delegate's
            // didPresent callback or via the session delegate's didEndWith),
            // and updateUIViewController flips the UI to "Save Scan".
            coordinator.finishRequested = true
            vc?.showProcessingState()
            vc?.captureView.captureSession.stop()
        }
        vc.onCancelTapped = {
            onCancel()
        }
        vc.onSaveTapped = {
            onSaveRequested()
        }
        context.coordinator.onSessionFailed = { [weak vc] error in
            vc?.sessionDidFail(with: error)
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: RoomCaptureHostController, context: Context) {
        // When RoomPlan finishes processing, pending.isReady becomes true.
        // Flip the UI so the user sees (and can tap) a clear "Save Scan" button.
        if pending.isReady {
            uiViewController.showSaveState()
        }
    }
}

/// Hosts RoomCaptureView (UIKit) with "Done", "Cancel", and (post-processing) "Save Scan" buttons.
/// Starts the capture session when the view appears.
@available(iOS 16.0, *)
final class RoomCaptureHostController: UIViewController {
    let captureView = RoomCaptureView()

    var onDoneTapped: (() -> Void)?
    var onCancelTapped: (() -> Void)?
    var onSaveTapped: (() -> Void)?

    private enum UIState { case scanning, processing, readyToSave }
    private var state: UIState = .scanning

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

    private let saveButton: UIButton = {
        var cfg = UIButton.Configuration.filled()
        cfg.title = "Save Scan"
        cfg.image = UIImage(systemName: "square.and.arrow.down.fill")
        cfg.imagePadding = 6
        cfg.baseBackgroundColor = .systemGreen
        cfg.baseForegroundColor = .white
        cfg.cornerStyle = .capsule
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)
        let b = UIButton(configuration: cfg)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        b.isHidden = true
        return b
    }()

    private let processingStack: UIStackView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.startAnimating()
        let label = UILabel()
        label.text = "Processing…"
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .medium)
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)
        let bg = UIView()
        bg.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        bg.layer.cornerRadius = 22
        bg.layer.masksToBounds = true
        bg.translatesAutoresizingMaskIntoConstraints = false
        stack.insertSubview(bg, at: 0)
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: stack.topAnchor),
            bg.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            bg.bottomAnchor.constraint(equalTo: stack.bottomAnchor)
        ])
        stack.isHidden = true
        return stack
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

    /// Safety net: if neither the view delegate's didPresent nor the session
    /// delegate's didEndWith produces a room within this window, surface an
    /// error instead of leaving the user stuck on the spinner forever.
    private static let processingTimeoutSeconds: TimeInterval = 45
    private var processingTimeoutTask: DispatchWorkItem?

    override func loadView() {
        view = captureView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(doneButton)
        view.addSubview(saveButton)
        view.addSubview(processingStack)
        view.addSubview(cancelButton)

        doneButton.addTarget(self, action: #selector(tappedDone), for: .touchUpInside)
        saveButton.addTarget(self, action: #selector(tappedSave), for: .touchUpInside)
        cancelButton.addTarget(self, action: #selector(tappedCancel), for: .touchUpInside)

        NSLayoutConstraint.activate([
            doneButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            doneButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            saveButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            saveButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            processingStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            processingStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            cancelButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // ARKit does not disable auto-lock; a mid-scan screen lock kills tracking.
        UIApplication.shared.isIdleTimerDisabled = true
        LiDARCaptureActivity.shared.captureDidStart()
        guard LiDARCapability.isSupported else { return }
        let config = RoomCaptureSession.Configuration()
        captureView.captureSession.run(configuration: config)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        LiDARCaptureActivity.shared.captureDidEnd()
        captureView.captureSession.stop()
    }

    /// Called from the representable once Done fires — swaps Done for a spinner.
    func showProcessingState() {
        guard state == .scanning else { return }
        state = .processing
        doneButton.isHidden = true
        saveButton.isHidden = true
        processingStack.isHidden = false

        // Arm the timeout. If nothing transitions us to readyToSave before it
        // fires, show an alert with actionable options instead of hanging.
        processingTimeoutTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.processingDidTimeOut()
        }
        processingTimeoutTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.processingTimeoutSeconds, execute: task)
    }

    /// Called from the representable when `pending.isReady` becomes true —
    /// swaps the spinner for a tappable "Save Scan" button.
    func showSaveState() {
        guard state != .readyToSave else { return }
        state = .readyToSave
        processingTimeoutTask?.cancel()
        processingTimeoutTask = nil
        doneButton.isHidden = true
        processingStack.isHidden = true
        saveButton.isHidden = false
        saveButton.isEnabled = true
    }

    private func processingDidTimeOut() {
        guard state == .processing else { return }
        let alert = UIAlertController(
            title: "Scan couldn't be processed",
            message: "RoomPlan didn't return a finished 3D model in time. This can happen in rooms with very little surface detail or when the scan was too brief.\n\nTry again — move the device slowly around the entire perimeter of the room for at least 20 seconds, keeping walls, floor, and ceiling in view.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Try Again", style: .default) { [weak self] _ in
            self?.onCancelTapped?()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.onCancelTapped?()
        })
        present(alert, animated: true)
    }

    /// Called from the coordinator when RoomCaptureSession reports a
    /// non-recoverable failure mid-scan (ARKit tracking lost, sensor
    /// blocked, low-light). Cancels any armed processing timeout,
    /// surfaces the error, and routes the user back through the
    /// existing cancel path so the SwiftUI parent dismisses cleanly.
    func sessionDidFail(with error: Error) {
        guard state != .readyToSave else { return }
        guard presentedViewController == nil else { return }
        processingTimeoutTask?.cancel()
        processingTimeoutTask = nil
        Diagnostics.logError(context: "RoomCaptureSession.didFailWith", error: error)
        let alert = UIAlertController(
            title: "Scan couldn't continue",
            message: "RoomPlan ran into an issue: \(error.localizedDescription)\n\nThis can happen in low-light rooms, when the LiDAR sensor is covered, or when device tracking is lost. Try again with steady movement, good lighting, and a clear view of the room.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Try Again", style: .default) { [weak self] _ in
            self?.onCancelTapped?()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.onCancelTapped?()
        })
        present(alert, animated: true)
    }

    @objc private func tappedDone() {
        onDoneTapped?()
    }

    @objc private func tappedSave() {
        saveButton.isEnabled = false
        onSaveTapped?()
    }

    @objc private func tappedCancel() {
        doneButton.isEnabled = false
        saveButton.isEnabled = false
        cancelButton.isEnabled = false
        onCancelTapped?()
    }
}

// MARK: - Persistence

@available(iOS 16.0, *)
enum LiDARScanPersistence {

    /// Persist a processed CapturedRoom to disk: USDZ export, floor-plan PNG
    /// render, and a LiDARScan record. Returns the saved scan on success.
    ///
    /// The whole pipeline runs off the main actor: `room.export` is a
    /// CPU-bound USD encode that takes seconds for a furnished room and
    /// froze the naming sheet when it ran on main. CapturedRoom is a value
    /// type, FloorplanRenderer uses the thread-safe UIGraphicsImageRenderer,
    /// and FileSecurity/LiDARScanStore are static helpers already used
    /// off-main elsewhere. The JSON record stays the LAST write (audit H4):
    /// a torn save can orphan a USDZ but never produce a record whose files
    /// are missing. NEEDS ON-DEVICE IPAD VERIFICATION: room.export(to:) has
    /// no documented main-thread requirement, but Apple's RoomPlan sample
    /// calls it from main and the simulator cannot exercise capture at all —
    /// do not merge on simulator evidence alone.
    static func save(room: CapturedRoom, jobId: UUID, name: String?, sectionId: UUID? = nil) async -> LiDARScan? {
        await Task.detached(priority: .userInitiated) { () -> LiDARScan? in
            saveSync(room: room, jobId: jobId, name: name, sectionId: sectionId)
        }.value
    }

    private static func saveSync(room: CapturedRoom, jobId: UUID, name: String?, sectionId: UUID?) -> LiDARScan? {
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

            // Persist the CapturedRoom itself so multiple rooms can later be merged
            // into a whole-home plan (StructureBuilder). Non-fatal, like the PNG.
            var roomJSONFileName: String? = nil
            do {
                let roomData = try JSONEncoder().encode(room)
                let fileName = "\(scanId.uuidString)_room.json"
                try roomData.write(to: lidarDir.appendingPathComponent(fileName), options: .atomic)
                roomJSONFileName = fileName
            } catch {
                // Non-fatal: scan still usable without the merge source.
            }

            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let userName = (trimmed?.isEmpty == false) ? trimmed : nil
            var finalName = userName
            var measurements: [Measurement] = []
            // LiDARScanMeasurements is @available(iOS 17.0, *); this enum stays
            // at 16.0, so gate the calls (deployment target 17.0 — always passes).
            if #available(iOS 17.0, *) {
                if finalName == nil {
                    finalName = LiDARScanMeasurements.autoName(from: room)
                }
                measurements = LiDARScanMeasurements.compute(from: room)
            }

            let scan = LiDARScan(
                id: scanId,
                versionId: jobId,
                usdzFileName: usdzFileName,
                floorplanPNGFileName: floorplanFileName,
                roomJSONFileName: roomJSONFileName,
                name: finalName,
                sectionId: sectionId,
                measurements: measurements,
                capturedAt: Date()
            )
            // If the scan record didn't reach disk, report capture as failed rather
            // than returning a scan loadScans will never find (audit H4).
            guard LiDARScanStore.save(scan, jobId: jobId) else { return nil }
            return scan
        } catch {
            return nil
        }
    }
}

#endif
