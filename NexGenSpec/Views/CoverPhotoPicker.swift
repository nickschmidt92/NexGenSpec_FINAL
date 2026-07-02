//
//  CoverPhotoPicker.swift
//  NexGenSpec
//
//  A single SwiftUI wrapper around UIImagePickerController that
//  handles BOTH camera capture and library pick for the cover-photo
//  flow. One representable, one presentation path, one dismissal
//  callback — deliberately simple because the previous stack
//  (Menu → PhotosPicker → ActionSheet → fullScreenCover → sheet(item:))
//  never worked reliably on iOS 26.
//
//  UIImagePickerController is a 15-year-old UIKit API that predates
//  PhotosPicker and has zero iOS 26 lifecycle bugs. It also supports
//  inline editing (crop + zoom) out of the box via allowsEditing,
//  which quietly addresses the "cover photo auto-zoom" tester
//  feedback — users can frame the photo themselves before accepting.
//

import SwiftUI
import UIKit

/// The two legitimate ways to pick a cover photo. Drives
/// presentation via `.fullScreenCover(item:)` — setting to non-nil
/// presents, setting to nil dismisses. No separate isPresented
/// bool to get stuck in a half-state.
enum CoverPhotoSource: Identifiable {
    case camera
    case library
    var id: String { "\(self)" }

    /// Maps the enum onto UIKit's sourceType. The picker type is the
    /// only real difference — delegate, editing, dismissal all share.
    var uiSourceType: UIImagePickerController.SourceType {
        switch self {
        case .camera: return .camera
        case .library: return .photoLibrary
        }
    }
}

struct CoverPhotoPicker: UIViewControllerRepresentable {
    let source: CoverPhotoSource
    /// Called on user finishing OR cancelling. Image is nil on cancel.
    /// Caller is responsible for setting the source state back to nil
    /// to dismiss (typical pattern: `coverPhotoSource = nil` inside
    /// the callback body).
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // Defense-in-depth: a `.camera` source traps on camera-less devices. Fall
        // back to the library when camera is requested but unavailable, so an
        // unguarded path degrades instead of crashing.
        if source == .camera && !UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .photoLibrary
        } else {
            picker.sourceType = source.uiSourceType
        }
        picker.allowsEditing = true   // Gives the user crop/zoom before commit
        picker.delegate = context.coordinator
        if picker.sourceType == .camera {
            picker.cameraCaptureMode = .photo
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        // No-op. State is write-once: picker is instantiated with a
        // source and dismissed on user action.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // Prefer the edited (cropped/zoomed) version when
            // allowsEditing is on; fall back to the original.
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            onFinish(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
