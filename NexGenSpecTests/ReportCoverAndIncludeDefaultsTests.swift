//
//  ReportCoverAndIncludeDefaultsTests.swift
//  NexGenSpecTests
//
//  Build-39 report-quality pass:
//    A. The inspection's cover photo renders on the report cover page —
//       embedded base64 (same size-budget helper as item photos), gracefully
//       absent when there is no readable cover file, and never allowed to
//       push the cover past a single printed page (page-count parity check).
//    B. The "Include in report" trap: assigning a severity to an item that had
//       none must one-shot arm the report gates (includeInReport = true,
//       notInspected → inspected) via InspectionItem.setDefectSeverity, while a
//       manual opt-out afterwards is never re-forced.
//

import XCTest
import PDFKit
import UIKit
@testable import NexGenSpec

final class ReportCoverAndIncludeDefaultsTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a draft version whose inspection id == the version's jobId, with
    /// one report-includable defect so the body/summary render real content.
    private func makeVersion(jobId: UUID, coverPhotoFileName: String?) -> InspectionVersion {
        let defect = InspectionItem(
            templateItemId: "test-defect",
            title: "Cracked Foundation",
            includeInReport: true,
            status: .inspected,
            defectSeverity: .major,
            location: "Basement",
            observed: "Crack along north wall",
            implication: "Structural instability",
            recommendation: "Consult structural engineer"
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

    /// Writes a real JPEG (solid-fill via UIGraphicsImageRenderer) to the
    /// canonical cover path and registers cleanup of the inspection folder.
    private func writeCoverJPEG(jobId: UUID, fileName: String) throws {
        try FilePaths.ensureAppStructure(jobId: jobId)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480))
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        try data.write(to: FilePaths.coverPhotoFile(jobId: jobId, fileName: fileName), options: [.atomic])
    }

    private func registerFolderCleanup(jobId: UUID) {
        addTeardownBlock {
            try? FileManager.default.removeItem(at: FilePaths.inspectionFolder(jobId: jobId))
        }
    }

    // MARK: - A. Cover photo on the report cover page

    func testCoverPhotoRendersOnCoverPageWhenFileExists() throws {
        let jobId = UUID()
        registerFolderCleanup(jobId: jobId)
        try writeCoverJPEG(jobId: jobId, fileName: FilePaths.defaultCoverPhotoFileName)
        let version = makeVersion(jobId: jobId, coverPhotoFileName: FilePaths.defaultCoverPhotoFileName)

        let html = HTMLReportRenderer.renderHTML(for: version)

        // Cover page carries the compact-layout class and an embedded (base64,
        // not file-URL) property photo — like every other cover-page asset.
        XCTAssertTrue(html.contains("<div class=\"cover-page has-photo\">"),
                      "Cover page should switch to the compact has-photo layout")
        XCTAssertTrue(html.contains("<img class=\"cover-photo\" src=\"data:image/jpeg;base64,"),
                      "Cover photo should be embedded as a base64 JPEG data URI")
        // The data URI must actually carry image bytes (guards against an
        // empty-src regression that renders a broken image icon).
        let marker = "<img class=\"cover-photo\" src=\"data:image/jpeg;base64,"
        let afterMarker = try XCTUnwrap(html.range(of: marker)).upperBound
        let base64Head = String(html[afterMarker...].prefix(64))
        XCTAssertGreaterThanOrEqual(base64Head.count, 64, "Embedded cover base64 payload should be non-trivial")
        XCTAssertFalse(base64Head.hasPrefix("\""), "Embedded cover base64 payload must not be empty")
    }

    func testCoverPageRendersCleanWithoutCoverPhoto() {
        let jobId = UUID()
        let version = makeVersion(jobId: jobId, coverPhotoFileName: nil)

        let html = HTMLReportRenderer.renderHTML(for: version)

        // Exactly the pre-existing cover page: original class, no cover <img>.
        // (The .has-photo CSS RULES are always in the <style> block; what must
        // be absent is the class on the markup and the image element itself.)
        XCTAssertTrue(html.contains("<div class=\"cover-page\">"),
                      "No cover file → cover page keeps its original (non-compact) layout")
        XCTAssertFalse(html.contains("<div class=\"cover-page has-photo\">"))
        XCTAssertFalse(html.contains("<img class=\"cover-photo\""))
        // Rest of the cover still renders.
        XCTAssertTrue(html.contains("123 Sample St, Springfield"))
    }

    func testMissingCoverFileOnDiskRendersCleanNotBroken() {
        // coverPhotoFileName is set, but the file never made it to disk (e.g.
        // synced-in record whose asset hasn't arrived). Must degrade to the
        // no-cover rendering — no broken <img>, no render failure.
        let jobId = UUID()
        let version = makeVersion(jobId: jobId, coverPhotoFileName: FilePaths.defaultCoverPhotoFileName)

        let html = HTMLReportRenderer.renderHTML(for: version)

        XCTAssertTrue(html.contains("<div class=\"cover-page\">"))
        XCTAssertFalse(html.contains("<div class=\"cover-page has-photo\">"))
        XCTAssertFalse(html.contains("<img class=\"cover-photo\""))
    }

    /// End-to-end PDF gate: the report PDF generates with a cover photo, and
    /// the photo does NOT overflow the cover page. The only difference between
    /// the two renders is the cover photo, and `.cover-page` has
    /// page-break-after:always — so an overflowing cover would show up as an
    /// extra PDF page. Page-count parity proves single-page containment.
    @MainActor
    func testPDFGeneratesWithCoverPhotoWithoutOverflowingCoverPage() async throws {
        let jobId = UUID()
        registerFolderCleanup(jobId: jobId)
        try writeCoverJPEG(jobId: jobId, fileName: FilePaths.defaultCoverPhotoFileName)

        let withCover = makeVersion(jobId: jobId, coverPhotoFileName: FilePaths.defaultCoverPhotoFileName)
        var withoutCover = withCover
        withoutCover.inspectionVersionId = UUID()   // distinct temp render dir
        withoutCover.inspection.coverPhotoFileName = nil

        let pdfWithCoverURL = try await PDFReportRenderer.generatePDF(for: withCover)
        let pdfWithoutCoverURL = try await PDFReportRenderer.generatePDF(for: withoutCover)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: pdfWithCoverURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: pdfWithoutCoverURL.deletingLastPathComponent())
        }

        let pdfWithCover = try XCTUnwrap(PDFDocument(url: pdfWithCoverURL), "PDF with cover photo should generate")
        let pdfWithoutCover = try XCTUnwrap(PDFDocument(url: pdfWithoutCoverURL), "PDF without cover photo should generate")
        XCTAssertGreaterThanOrEqual(pdfWithCover.pageCount, 2)
        XCTAssertEqual(pdfWithCover.pageCount, pdfWithoutCover.pageCount,
                       "Cover photo must not push the cover page into an extra page")
    }

    // MARK: - B. setDefectSeverity one-shot transition

    private func freshItem(status: ItemStatus = .notInspected) -> InspectionItem {
        InspectionItem(templateItemId: "t", title: "Item", status: status)
    }

    func testFirstSeverityAssignmentArmsReportGates() {
        var item = freshItem(status: .notInspected)
        XCTAssertFalse(item.includeInReport)

        item.setDefectSeverity(.major)

        XCTAssertEqual(item.defectSeverity, .major)
        XCTAssertTrue(item.includeInReport, "nil → severity must default the item into the report")
        XCTAssertEqual(item.status, .inspected, "notInspected must upgrade to inspected on first severity")
        XCTAssertTrue(item.isDefect, "Item must now pass the report's isDefect gate")
    }

    func testAlreadyInspectedStatusIsUntouched() {
        var item = freshItem(status: .inspected)

        item.setDefectSeverity(.safety)

        XCTAssertEqual(item.status, .inspected)
        XCTAssertTrue(item.includeInReport)
    }

    func testNotPresentStatusIsNotUpgraded() {
        // Only .notInspected upgrades; a deliberate non-inspected disposition
        // like .notPresent is the inspector's call and stays put.
        var item = freshItem(status: .notPresent)

        item.setDefectSeverity(.minor)

        XCTAssertEqual(item.status, .notPresent)
        XCTAssertTrue(item.includeInReport)
    }

    func testManualOptOutIsNotReforcedBySeverityChange() {
        var item = freshItem()
        item.setDefectSeverity(.major)          // arms the gates (one-shot)
        item.includeInReport = false            // inspector manually opts out

        item.setDefectSeverity(.safety)         // non-nil → non-nil change

        XCTAssertEqual(item.defectSeverity, .safety)
        XCTAssertFalse(item.includeInReport, "Changing severity between values must not re-force includeInReport")
        XCTAssertEqual(item.status, .inspected)
    }

    func testSameSeverityReassignmentIsNotReforced() {
        // Re-saving / re-selecting the SAME severity is also non-nil → non-nil:
        // a manual opt-out must survive it.
        var item = freshItem()
        item.setDefectSeverity(.marginal)
        item.includeInReport = false

        item.setDefectSeverity(.marginal)

        XCTAssertFalse(item.includeInReport)
    }

    func testNilToNilSeverityIsNoOp() {
        var item = freshItem(status: .notInspected)

        item.setDefectSeverity(nil)

        XCTAssertNil(item.defectSeverity)
        XCTAssertFalse(item.includeInReport)
        XCTAssertEqual(item.status, .notInspected)
    }

    func testClearingSeverityOnlyClearsSeverity() {
        var item = freshItem()
        item.setDefectSeverity(.major)

        item.setDefectSeverity(nil)             // value → nil transition

        XCTAssertNil(item.defectSeverity)
        XCTAssertTrue(item.includeInReport, "Clearing severity must not silently flip other flags")
        XCTAssertEqual(item.status, .inspected)
    }

    func testReassigningAfterClearRearmsGates() {
        // Clearing to None and picking a severity again is a NEW nil → value
        // transition, so the default fires again (documented semantics).
        var item = freshItem()
        item.setDefectSeverity(.major)
        item.includeInReport = false
        item.setDefectSeverity(nil)

        item.setDefectSeverity(.minor)

        XCTAssertTrue(item.includeInReport)
    }
}
