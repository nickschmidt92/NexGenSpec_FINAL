//
//  PreviewThumbnailFallbackTests.swift
//  NexGenSpecTests
//
//  Receiver-preview seam (post-build-40 ship polish): item photo THUMBNAILS sync
//  across devices (MediaAsset kind=thumbnail) but full-resolution originals
//  deliberately do NOT in 1.0 — so on a receiving device the draft Report
//  Preview used to render blank space where item photos belong, even though
//  perfectly good thumbnails sat on the same disk. The renderer's item-photo
//  loader now falls back to the photo's thumbnail (same fileName under
//  `thumbnails/` instead of `photos/`) when the original is missing/unreadable.
//  Covered here:
//    (a) Original present → the ORIGINAL is embedded and a planted
//        differently-colored thumbnail is ignored (editor-side bytes identical
//        to a render with no thumbnail on disk at all).
//    (b) Original absent + thumbnail materialized exactly the way the sync pull
//        does (InspectionStoreVersionWriter.applyRemoteAsset) → the thumbnail
//        is embedded and the PDF still generates with its text intact.
//    (c) Both absent → today's graceful skip is preserved: text renders, no
//        <img class="photo"> and no broken data URI.
//    (d) The cover-photo path is untouched: no thumbnail fallback exists for
//        covers (they sync at full quality), and a cover on disk renders
//        exactly as before.
//

import XCTest
import PDFKit
import UIKit
@testable import NexGenSpec

final class PreviewThumbnailFallbackTests: XCTestCase {

    // MARK: - Fixtures

    private let photoFileName = "photo-under-test.jpg"

    /// Draft version with one report-includable defect carrying one photo.
    private func makeVersion(jobId: UUID, coverPhotoFileName: String? = nil) -> InspectionVersion {
        let defect = InspectionItem(
            templateItemId: "test-defect",
            title: "Cracked Foundation",
            includeInReport: true,
            status: .inspected,
            defectSeverity: .major,
            location: "Basement",
            observed: "Crack along north wall",
            implication: "Structural instability",
            recommendation: "Consult structural engineer",
            photos: [InspectionPhoto(fileName: photoFileName)]
        )
        let inspection = Inspection(
            id: jobId,
            clientName: "Test Client",
            propertyAddress: "123 Sample St, Springfield",
            inspectionDate: Date(timeIntervalSince1970: 1_750_000_000),
            inspectorName: "Test Inspector",
            sections: [InspectionSection(title: "Structure", items: [defect])],
            coverPhotoFileName: coverPhotoFileName
        )
        return InspectionVersion(versionNumber: 1, status: .draft, locked: false, inspection: inspection)
    }

    private func solidJPEG(color: UIColor, size: CGSize) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }

    /// Writes a solid-fill JPEG to the canonical full-resolution original path.
    private func writeOriginal(jobId: UUID, color: UIColor) throws {
        try FilePaths.ensureAppStructure(jobId: jobId)
        let data = try solidJPEG(color: color, size: CGSize(width: 640, height: 480))
        try data.write(
            to: FilePaths.photosFolder(jobId: jobId).appendingPathComponent(photoFileName),
            options: [.atomic]
        )
    }

    /// Writes a solid-fill JPEG to the editor-side thumbnail path (what
    /// `PhotoLoadService.generateThumbnailIfNeeded` produces locally):
    /// the photo's exact fileName under `thumbnails/` instead of `photos/`.
    private func writeEditorThumbnail(jobId: UUID, color: UIColor) throws {
        try FilePaths.ensureAppStructure(jobId: jobId)
        let data = try solidJPEG(color: color, size: CGSize(width: 200, height: 150))
        try data.write(
            to: FilePaths.thumbnailsFolder(jobId: jobId).appendingPathComponent(photoFileName),
            options: [.atomic]
        )
    }

    /// Materializes a thumbnail EXACTLY the way a receiving device does: through
    /// `InspectionStoreVersionWriter.applyRemoteAsset` with a kind=thumbnail
    /// `SyncAssetRecord`, the same code the CloudKit pull hands received
    /// MediaAssets to. Returns the applyRemoteAsset result.
    private func materializeSyncedThumbnail(jobId: UUID, color: UIColor) async throws -> Bool {
        let payload = try solidJPEG(color: color, size: CGSize(width: 200, height: 150))
        let record = SyncAssetRecord(
            recordName: "asset-\(jobId.uuidString)-thumb",
            jobId: jobId,
            relativePath: "Inspections/\(jobId.uuidString)/thumbnails/\(photoFileName)",
            kind: .thumbnail,
            modifiedAt: Date(),
            schemaVersion: 1,
            payload: payload
        )
        let writer = InspectionStoreVersionWriter(store: nil)
        return await writer.applyRemoteAsset(record)
    }

    private func registerFolderCleanup(jobId: UUID) {
        addTeardownBlock {
            try? FileManager.default.removeItem(at: FilePaths.inspectionFolder(jobId: jobId))
        }
    }

    // MARK: - Probes

    /// Base64 payload of the FIRST embedded item photo (`img.photo` data URI).
    private func embeddedItemPhotoBase64(in html: String) throws -> String {
        let marker = "<img class=\"photo\" src=\"data:image/jpeg;base64,"
        let start = try XCTUnwrap(html.range(of: marker), "Expected an embedded item photo").upperBound
        let end = try XCTUnwrap(html[start...].firstIndex(of: "\""))
        return String(html[start..<end])
    }

    /// Average color of an encoded image, via a 1x1 bitmap draw. Solid-fill
    /// fixtures survive JPEG round-trips, so dominant-channel comparison is a
    /// robust "which source image is this?" probe.
    private func averageColor(of data: Data) throws -> (r: Int, g: Int, b: Int) {
        let image = try XCTUnwrap(UIImage(data: data))
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    // MARK: - (a) Original present → original wins, thumbnail ignored

    func testOriginalWinsOverPlantedThumbnail() throws {
        let jobId = UUID()
        registerFolderCleanup(jobId: jobId)
        try writeOriginal(jobId: jobId, color: .red)

        // Editor-side baseline: original only, no thumbnail anywhere on disk.
        let baselineHTML = HTMLReportRenderer.renderHTML(for: makeVersion(jobId: jobId))
        let baselinePhoto = try embeddedItemPhotoBase64(in: baselineHTML)

        // Plant a DIFFERENTLY-COLORED thumbnail; the original must still win.
        try writeEditorThumbnail(jobId: jobId, color: .blue)
        let html = HTMLReportRenderer.renderHTML(for: makeVersion(jobId: jobId))
        let embedded = try embeddedItemPhotoBase64(in: html)

        // Zero behavior change when the original exists: identical embedded bytes.
        XCTAssertEqual(embedded, baselinePhoto,
                       "With the original on disk, a thumbnail's presence must not change the embedded photo bytes")

        // And the pixels really are the original's (red), not the thumbnail's (blue).
        let color = try averageColor(of: try XCTUnwrap(Data(base64Encoded: embedded)))
        XCTAssertGreaterThan(color.r, color.b + 100,
                             "Embedded photo should be the red original, not the blue thumbnail (got \(color))")
    }

    // MARK: - (b) Original absent → synced thumbnail embedded

    @MainActor
    func testMissingOriginalFallsBackToSyncedThumbnail() async throws {
        let jobId = UUID()
        registerFolderCleanup(jobId: jobId)

        // No original ever written. Materialize the thumbnail through the REAL
        // receiver code path (applyRemoteAsset), then prove it landed exactly
        // where the renderer's fallback helper looks — locking the fileName ↔
        // thumbnail path convention shared by editor writes and sync pulls.
        let applied = try await materializeSyncedThumbnail(jobId: jobId, color: .blue)
        XCTAssertTrue(applied, "applyRemoteAsset should accept a kind=thumbnail record")
        let canonicalThumb = FilePaths.thumbnailsFolder(jobId: jobId).appendingPathComponent(photoFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalThumb.path),
                      "Sync-materialized thumbnail must land at FilePaths.thumbnailsFolder(jobId:)/<photo.fileName>")

        let version = makeVersion(jobId: jobId)
        let html = HTMLReportRenderer.renderHTML(for: version)

        // The thumbnail is embedded (blue pixels), and the item text is intact.
        let embedded = try embeddedItemPhotoBase64(in: html)
        let color = try averageColor(of: try XCTUnwrap(Data(base64Encoded: embedded)))
        XCTAssertGreaterThan(color.b, color.r + 100,
                             "Embedded photo should be the blue synced thumbnail (got \(color))")
        XCTAssertTrue(html.contains("Cracked Foundation"))
        XCTAssertTrue(html.contains("Crack along north wall"))

        // End-to-end: the PDF still generates with its pages and text.
        let pdfURL = try await PDFReportRenderer.generatePDF(for: version)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent())
        }
        let pdf = try XCTUnwrap(PDFDocument(url: pdfURL), "PDF should generate with a thumbnail-backed item photo")
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 2)
    }

    // MARK: - (c) Both absent → today's clean skip preserved

    @MainActor
    func testBothAbsentSkipsPhotoCleanly() async throws {
        let jobId = UUID()
        registerFolderCleanup(jobId: jobId)
        let version = makeVersion(jobId: jobId)

        let html = HTMLReportRenderer.renderHTML(for: version)

        // No item <img> of any kind — not an empty/broken data URI.
        XCTAssertFalse(html.contains("<img class=\"photo\""),
                       "Neither original nor thumbnail on disk → no item photo element at all")
        XCTAssertFalse(html.contains("base64,\""), "No empty data-URI payloads")
        // Text still renders.
        XCTAssertTrue(html.contains("Cracked Foundation"))
        XCTAssertTrue(html.contains("Structural instability"))

        let pdfURL = try await PDFReportRenderer.generatePDF(for: version)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent())
        }
        let pdf = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 2)
    }

    // MARK: - (d) Cover-photo path untouched

    func testCoverPhotoPathHasNoThumbnailFallback() throws {
        // A cover whose file is missing must STILL degrade to the no-cover
        // rendering even when a same-named file sits in thumbnails/ — the cover
        // path syncs at full quality (PR #123) and gets no fallback from this
        // change.
        let jobId = UUID()
        registerFolderCleanup(jobId: jobId)
        try FilePaths.ensureAppStructure(jobId: jobId)
        let strayThumb = try solidJPEG(color: .green, size: CGSize(width: 200, height: 150))
        try strayThumb.write(
            to: FilePaths.thumbnailsFolder(jobId: jobId)
                .appendingPathComponent(FilePaths.defaultCoverPhotoFileName),
            options: [.atomic]
        )
        let version = makeVersion(jobId: jobId, coverPhotoFileName: FilePaths.defaultCoverPhotoFileName)

        let html = HTMLReportRenderer.renderHTML(for: version)

        XCTAssertTrue(html.contains("<div class=\"cover-page\">"))
        XCTAssertFalse(html.contains("<div class=\"cover-page has-photo\">"),
                       "Missing cover file must not fall back to a thumbnails/ lookalike")
        XCTAssertFalse(html.contains("<img class=\"cover-photo\""))
    }

    func testCoverPhotoStillRendersFromItsCanonicalPath() throws {
        // And the positive cover path is byte-for-byte alive: cover on disk at
        // its canonical root location renders embedded, exactly as pre-change.
        let jobId = UUID()
        registerFolderCleanup(jobId: jobId)
        try FilePaths.ensureAppStructure(jobId: jobId)
        let cover = try solidJPEG(color: .systemTeal, size: CGSize(width: 640, height: 480))
        try cover.write(
            to: FilePaths.coverPhotoFile(jobId: jobId, fileName: FilePaths.defaultCoverPhotoFileName),
            options: [.atomic]
        )
        let version = makeVersion(jobId: jobId, coverPhotoFileName: FilePaths.defaultCoverPhotoFileName)

        let html = HTMLReportRenderer.renderHTML(for: version)

        XCTAssertTrue(html.contains("<div class=\"cover-page has-photo\">"))
        XCTAssertTrue(html.contains("<img class=\"cover-photo\" src=\"data:image/jpeg;base64,"))
    }
}
