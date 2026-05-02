//
//  AccountDeletionReceiptService.swift
//  NexGenSpec
//
//  Generates a single-page PDF receipt at account deletion time. The receipt
//  captures who deleted the account, when, and what was wiped, and is saved
//  outside `FilePaths.appRoot` so it survives `clearAllLocalData()`. The
//  Delete Account flow attaches it to a pre-composed email so the user has a
//  permanent record after the local wipe.
//

import Foundation
import UIKit

public enum AccountDeletionReceiptService {

    public struct Inputs {
        public let accountEmail: String
        public let firebaseUID: String
        public let fallbackEmail: String?
        public let inspectionsDeletedCount: Int
        public let providerLabel: String   // "Apple" / "Email & Password" / "Unknown"
        public let appVersion: String
        public let buildNumber: String
        public let deviceModel: String
        public let osVersion: String
        public let timestamp: Date

        public init(accountEmail: String,
                    firebaseUID: String,
                    fallbackEmail: String?,
                    inspectionsDeletedCount: Int,
                    providerLabel: String,
                    appVersion: String,
                    buildNumber: String,
                    deviceModel: String,
                    osVersion: String,
                    timestamp: Date = Date()) {
            self.accountEmail = accountEmail
            self.firebaseUID = firebaseUID
            self.fallbackEmail = fallbackEmail
            self.inspectionsDeletedCount = inspectionsDeletedCount
            self.providerLabel = providerLabel
            self.appVersion = appVersion
            self.buildNumber = buildNumber
            self.deviceModel = deviceModel
            self.osVersion = osVersion
            self.timestamp = timestamp
        }
    }

    /// Folder for deletion receipts. Lives at `Documents/NexGenSpecReceipts/` so it
    /// is OUTSIDE `FilePaths.appRoot` and survives `clearAllLocalData()`. Surfaced
    /// via UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace so the user can
    /// retrieve the receipt from the Files app even after deletion.
    public static var receiptFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("NexGenSpecReceipts", isDirectory: true)
    }

    /// Renders a single-page A4 PDF at the canonical receipt path and returns its URL.
    public static func generateReceipt(_ inputs: Inputs) throws -> URL {
        try ensureReceiptFolder()

        let stamp = Self.timestampFormatter.string(from: inputs.timestamp)
        let url = receiptFolder.appendingPathComponent("NexGenSpec_DeletionReceipt_\(stamp).pdf")

        // A4 portrait at 72 dpi.
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "NexGenSpec Account Deletion Receipt",
            kCGPDFContextAuthor as String: "NexGenSpec",
            kCGPDFContextSubject as String: "Permanent account and data deletion",
            kCGPDFContextCreator as String: "NexGenSpec \(inputs.appVersion) (\(inputs.buildNumber))"
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)

        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            drawReceipt(in: pageRect, inputs: inputs)
        }

        try data.write(to: url, options: .atomic)
        return url
    }

    public static func ensureReceiptFolder() throws {
        let folder = receiptFolder
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// Body text to accompany the receipt PDF when it is shared via the
    /// iOS share sheet. Includes a "please CC contact@nexgenspec.com"
    /// instruction since the share sheet — unlike MFMailComposeViewController
    /// — cannot pre-fill recipients.
    public static func shareBody(for inputs: Inputs, attachmentFileName: String) -> String {
        let displayDate = ISO8601DateFormatter().string(from: inputs.timestamp)
        return """
        NexGenSpec — Account Deletion Receipt

        Please send this email to yourself for your records, and CC contact@nexgenspec.com so NexGenSpec support has a copy on file.

        Deleted at: \(displayDate)
        Account: \(inputs.accountEmail)
        Sign-in method: \(inputs.providerLabel)
        Inspections wiped from this device: \(inputs.inspectionsDeletedCount)
        App: NexGenSpec \(inputs.appVersion) (\(inputs.buildNumber))
        Device: \(inputs.deviceModel) · iOS \(inputs.osVersion)

        The PDF attached (\(attachmentFileName)) is your permanent record. NexGenSpec has no server-side copy of your inspections, photos, signatures, or reports — local-first by design — so this receipt is the only artifact confirming the deletion took place.

        Per the NexGenSpec Terms of Use, the 5-year inspection-record retention obligation rests with you (the inspector). If you needed to keep any of the wiped inspection data for that obligation, contact contact@nexgenspec.com immediately; we cannot recover wiped data but we can document the timeline for your records.

        — NexGenSpec
        """
    }

    // MARK: - PDF drawing

    private static func drawReceipt(in rect: CGRect, inputs: Inputs) {
        let margin: CGFloat = 50
        let columnWidth = rect.width - margin * 2
        var y: CGFloat = margin

        let title = "NexGenSpec Account Deletion Receipt"
        title.draw(in: CGRect(x: margin, y: y, width: columnWidth, height: 36),
                   withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 22),
                    .foregroundColor: UIColor.black
                   ])
        y += 36

        let subtitle = "Permanent and irreversible. Save this receipt with your business records."
        subtitle.draw(in: CGRect(x: margin, y: y, width: columnWidth, height: 24),
                      withAttributes: [
                        .font: UIFont.italicSystemFont(ofSize: 12),
                        .foregroundColor: UIColor.darkGray
                      ])
        y += 32

        // Divider
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: y))
        path.addLine(to: CGPoint(x: rect.width - margin, y: y))
        UIColor.lightGray.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        y += 16

        let rows: [(String, String)] = [
            ("Deleted at",          ISO8601DateFormatter().string(from: inputs.timestamp)),
            ("Account email",       inputs.accountEmail),
            ("Fallback email",      inputs.fallbackEmail ?? "—"),
            ("Sign-in method",      inputs.providerLabel),
            ("Firebase UID",        inputs.firebaseUID),
            ("Inspections wiped",   "\(inputs.inspectionsDeletedCount)"),
            ("App version",         "\(inputs.appVersion) (\(inputs.buildNumber))"),
            ("Device",              "\(inputs.deviceModel) · iOS \(inputs.osVersion)")
        ]

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.darkGray
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: UIColor.black
        ]

        let labelColumnWidth: CGFloat = 130
        for (label, value) in rows {
            label.draw(in: CGRect(x: margin, y: y, width: labelColumnWidth, height: 18),
                       withAttributes: labelAttrs)
            value.draw(in: CGRect(x: margin + labelColumnWidth, y: y, width: columnWidth - labelColumnWidth, height: 18),
                       withAttributes: valueAttrs)
            y += 22
        }

        y += 12

        let body = """
        NexGenSpec is local-first. Your inspections, photos, signatures, and reports lived only on this device and have now been removed. NexGenSpec retains no server-side copy and cannot recover wiped data.

        Per the NexGenSpec Terms of Use, the 5-year inspection-record retention obligation rests with you, the inspector. This receipt is your permanent confirmation that the deletion occurred and what was wiped. Save it with your business records.

        For audit or legal questions, contact contact@nexgenspec.com.
        """

        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: UIColor.black
        ]
        let bodyRect = CGRect(x: margin, y: y, width: columnWidth, height: rect.height - y - 90)
        (body as NSString).draw(in: bodyRect, withAttributes: bodyAttrs)

        // Footer
        let footer = "NexGenSpec LLC — contact@nexgenspec.com"
        footer.draw(in: CGRect(x: margin, y: rect.height - 40, width: columnWidth, height: 16),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 9),
                        .foregroundColor: UIColor.gray
                    ])
    }

    // MARK: - Formatters

    private static let timestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt
    }()
}
