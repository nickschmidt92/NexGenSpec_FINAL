//
//  MailComposeView.swift
//  NexGenSpec
//
//  Presents system mail composer with pre-filled recipients, subject, body, and optional attachment.
//

import SwiftUI
import MessageUI

/// Presents MFMailComposeViewController. Dismisses when user sends or cancels.
struct MailComposeView: UIViewControllerRepresentable {
    var toRecipients: [String]
    var subject: String
    var body: String
    var isHTML: Bool = false
    var attachmentURL: URL?
    var onDismiss: () -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients(toRecipients)
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: isHTML)
        if let url = attachmentURL, let data = try? Data(contentsOf: url) {
            vc.addAttachmentData(data, mimeType: "application/pdf", fileName: url.lastPathComponent)
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true)
            onDismiss()
        }
    }
}
