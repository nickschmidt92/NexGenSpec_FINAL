//
//  VideoRecorderView.swift
//  NexGenSpec
//
//  Presents the system camera in video-capture mode. Calls onRecorded
//  with the URL of the captured .mov file when the inspector finishes
//  recording, or onCancel when they dismiss without keeping the clip.
//
//  Mirrors `CameraCaptureView`'s photo-capture pattern so the two
//  behave consistently (cover photo and walk-through video). Testers
//  correctly pointed out that v1 only supported library upload for
//  video, which was useless for on-site walkthrough footage.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct VideoRecorderView: UIViewControllerRepresentable {
    var onRecorded: (URL) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        // Don't allow trim/edit — keep the capture flow single-step. A
        // follow-up edit pass can happen after we add a video editor.
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onRecorded: onRecorded, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onRecorded: (URL) -> Void
        let onCancel: () -> Void

        init(onRecorded: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onRecorded = onRecorded
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // `mediaURL` is the temporary .mov file written to the
            // sandbox's tmp directory — iOS deletes it when the app
            // relaunches, so callers must copy it into permanent
            // storage before returning.
            if let url = info[.mediaURL] as? URL {
                onRecorded(url)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
