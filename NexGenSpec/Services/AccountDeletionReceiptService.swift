//
//  AccountDeletionReceiptService.swift
//  NexGenSpec
//
//  Generates a single-page PDF receipt at account deletion time. The receipt
//  captures who deleted the account, when, and what was wiped. It is saved to
//  `FilePaths.receiptsFolder` (Application Support/NexGenSpecReceipts) — OUTSIDE
//  `FilePaths.appRoot` so it survives `clearAllLocalData()` (the receipt must
//  outlive the wipe it documents), and OUTSIDE the file-shared Documents
//  directory so a previous account's email / recovery-email / UID is never
//  browsable by the next inspector on a shared device. The Delete Account flow
//  hands it to the user via the share sheet so they keep a permanent record.
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

    /// Folder for deletion receipts: `FilePaths.receiptsFolder`
    /// (`Application Support/NexGenSpecReceipts/`). OUTSIDE `FilePaths.appRoot` so it
    /// survives `clearAllLocalData()` (the receipt outlives the wipe it documents),
    /// and OUTSIDE the file-shared Documents directory so a previous account's
    /// email / recovery-email / UID is never browsable by the next inspector. The
    /// user receives the receipt at deletion time via the share sheet.
    public static var receiptFolder: URL {
        FilePaths.receiptsFolder
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

        // PII (account email, fallback email, Firebase UID) — write with the
        // same data-protection class as inspection files so it isn't readable
        // at rest on a locked device.
        try FileSecurity.writeProtected(data, to: url)
        return url
    }

    public static func ensureReceiptFolder() throws {
        // Same data-protection class as the rest of the private store — the
        // receipt holds account email, recovery email, and Firebase UID.
        try FileSecurity.ensureProtectedDirectory(receiptFolder)
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
        let footer = "NexGenSpec — contact@nexgenspec.com"
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
