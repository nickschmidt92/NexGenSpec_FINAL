//
//  NexGenSpecTests.swift
//  NexGenSpec
//

import XCTest
import PDFKit
import UIKit
@testable import NexGenSpec

final class FilePathsTests: XCTestCase {

    func testDocumentDirectoryExists() {
        let url = FilePaths.documentDirectory
        XCTAssertFalse(url.path.isEmpty)
        XCTAssertTrue(url.isFileURL)
    }

    func testAppRootContainsNexGenSpec() {
        let url = FilePaths.appRoot
        XCTAssertTrue(url.lastPathComponent == "NexGenSpec")
        XCTAssertTrue(url.path.contains("NexGenSpec"))
    }

    func testInspectionPathsUseJobId() {
        let jobId = UUID()
        let folder = FilePaths.inspectionFolder(jobId: jobId)
        let file = FilePaths.currentVersionFile(jobId: jobId)
        XCTAssertTrue(folder.path.contains(jobId.uuidString))
        XCTAssertTrue(file.lastPathComponent == "current.json")
        XCTAssertTrue(file.path.hasPrefix(folder.path))
    }
}

@MainActor
final class InspectionStoreTests: XCTestCase {

    func testMetadataListInitiallyEmptyOrFromDisk() {
        let store = InspectionStore()
        // After init, metadataList is either empty or loaded from index
        XCTAssertNotNil(store.metadataList)
    }

    func testClearSaveErrorDoesNotCrash() {
        let store = InspectionStore()
        store.clearSaveError()
        XCTAssertNil(store.saveError)
    }

    func testClearLoadErrorDoesNotCrash() {
        let store = InspectionStore()
        store.clearLoadError()
        XCTAssertNil(store.loadError)
    }

    func testDeleteVersionRemovesInspectionArtifacts() throws {
        let store = InspectionStore()
        let jobId = UUID()
        let inspection = Inspection(
            id: jobId,
            clientName: "Delete Me",
            clientEmail: "",
            clientPhone: "",
            propertyAddress: "123 Cleanup Lane",
            inspectionDate: Date(),
            inspectorName: "Inspector",
            sections: []
        )
        let version = InspectionVersion(
            id: jobId,
            versionNumber: 999,
            status: .draft,
            finalizedAt: nil,
            locked: false,
            inspection: inspection
        )

        try FilePaths.ensureAppStructure(jobId: jobId)
        let evidenceURL = FilePaths.photosFolder(jobId: jobId).appendingPathComponent("evidence.txt")
        try FileSecurity.writeProtected(Data("evidence".utf8), to: evidenceURL)

        store.insert(version: version)
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidenceURL.path))

        XCTAssertTrue(store.deleteVersion(id: jobId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: FilePaths.inspectionFolder(jobId: jobId).path))
    }
}

@MainActor
final class StateMachineTests: XCTestCase {
    func testFinalizeRequiresSignatures() {
        let id = UUID()
        let denied = InspectionStateMachine.transitionToFinalized(
            from: .draft,
            hasRequiredSignatures: false,
            versionId: id
        )
        if case .failure = denied {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected finalize denial without signatures")
        }

        let allowed = InspectionStateMachine.transitionToFinalized(
            from: .draft,
            hasRequiredSignatures: true,
            versionId: id
        )
        switch allowed {
        case .success(let state):
            XCTAssertEqual(state, .finalized(versionId: id))
        case .failure:
            XCTFail("Expected finalize success with required signatures")
        }
    }

    func testOnlyFinalizedCanCreateRevision() {
        let denied = InspectionStateMachine.canCreateRevision(from: .draft)
        if case .failure = denied {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected revision denial from draft")
        }

        let id = UUID()
        let allowed = InspectionStateMachine.canCreateRevision(from: .finalized(versionId: id))
        if case .success = allowed {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected revision allowed from finalized")
        }
    }
}

final class HTMLReportRendererTests: XCTestCase {
    func testEscapesUserHTMLFields() {
        let item = InspectionItem(
            templateItemId: "item",
            title: "<b>Title</b>",
            includeInReport: true,
            status: .inspected,
            defectSeverity: .major,
            location: "",
            observed: "<script>alert(1)</script>",
            implication: "A & B",
            recommendation: "\"quoted\"",
            contractorTag: "",
            photos: []
        )
        let section = InspectionSection(title: "Section <x>", items: [item])
        let inspection = Inspection(
            clientName: "<client>",
            clientEmail: "me@example.com",
            clientPhone: "",
            propertyAddress: "1 & 2 St",
            inspectionDate: Date(),
            inspectorName: "Inspector > Name",
            sections: [section]
        )
        let version = InspectionVersion(versionNumber: 1, status: .draft, locked: false, inspection: inspection)
        let html = HTMLReportRenderer.renderHTML(for: version)
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("A &amp; B"))
    }

    func testReportHTMLUsesPrintSafeStylesAndEagerImageLoading() throws {
        let jobId = UUID()
        try FilePaths.ensureAppStructure(jobId: jobId)

        let fileName = "export-photo.png"
        let photoURL = FilePaths.photosFolder(jobId: jobId).appendingPathComponent(fileName)
        try FileSecurity.writeProtected(makeTestPNGData(), to: photoURL)

        let photo = InspectionPhoto(fileName: fileName, caption: "Photo")
        let item = InspectionItem(
            templateItemId: "item",
            title: "Outlet",
            includeInReport: true,
            status: .inspected,
            defectSeverity: .major,
            location: "Kitchen",
            observed: "Observed issue",
            implication: "Implication",
            recommendation: "Recommendation",
            contractorTag: "",
            photos: [photo]
        )
        let section = InspectionSection(title: "Electrical", items: [item])
        let inspection = Inspection(
            id: jobId,
            clientName: "Client",
            clientEmail: "",
            clientPhone: "",
            propertyAddress: "123 Street",
            inspectionDate: Date(),
            inspectorName: "Inspector",
            sections: [section]
        )
        let version = InspectionVersion(id: jobId, versionNumber: 1, status: .draft, finalizedAt: nil, locked: false, inspection: inspection)
        let imageDir = FileManager.default.temporaryDirectory.appendingPathComponent("html-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)

        addTeardownBlock {
            try? FileManager.default.removeItem(at: FilePaths.inspectionFolder(jobId: jobId))
            try? FileManager.default.removeItem(at: imageDir)
        }

        let html = HTMLReportRenderer.renderHTML(for: version, imageFolderURL: imageDir)
        let printHTML = HTMLReportRenderer.renderHTML(for: version, imageFolderURL: imageDir, absoluteAssetFileURLs: true)

        XCTAssertTrue(html.contains("color-scheme\" content=\"light\""))
        XCTAssertTrue(html.contains("@media print"))
        XCTAssertFalse(html.contains("loading=\"lazy\""))
        // Renderer bakes annotations + recompresses as JPEG for report output,
        // regardless of the source photo's extension.
        XCTAssertTrue(html.contains("src=\"images/\(photo.id.uuidString).jpg\""))
        XCTAssertTrue(printHTML.contains("src=\"file://"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageDir.appendingPathComponent("\(photo.id.uuidString).jpg").path))
    }

    @MainActor
    func testGeneratedPDFContainsReportText() async throws {
        let inspection = Inspection(
            clientName: "Taylor Client",
            clientEmail: "taylor@example.com",
            clientPhone: "",
            propertyAddress: "45 Export Lane",
            inspectionDate: Date(),
            inspectorName: "Inspector",
            sections: [
                InspectionSection(
                    title: "Roof",
                    items: [
                        InspectionItem(
                            templateItemId: "roof-1",
                            title: "Flashing",
                            includeInReport: true,
                            status: .inspected,
                            defectSeverity: .major,
                            location: "Roof edge",
                            observed: "Flashing is loose.",
                            implication: "Water intrusion is possible.",
                            recommendation: "Repair flashing."
                        )
                    ]
                )
            ]
        )
        let version = InspectionVersion(versionNumber: 1, status: .draft, locked: false, inspection: inspection)
        let pdfURL = try await PDFReportRenderer.generatePDF(for: version)

        guard let document = PDFDocument(url: pdfURL) else {
            return XCTFail("Expected readable PDF document")
        }

        if ProcessInfo.processInfo.environment["KEEP_GENERATED_REPORT_PDF"] == "1" {
            print("GENERATED_REPORT_PDF=\(pdfURL.path)")
        } else {
            addTeardownBlock {
                try? FileManager.default.removeItem(at: pdfURL)
            }
        }

        XCTAssertGreaterThan(document.pageCount, 0)
        XCTAssertTrue(document.string?.contains("Inspection Report") == true)
        XCTAssertTrue(document.string?.contains("Taylor Client") == true)
    }

    @MainActor
    func testGeneratedPDFContainsPhoto() async throws {
        let jobId = UUID()
        try FilePaths.ensureAppStructure(jobId: jobId)

        let fileName = "photo-proof.png"
        let photoURL = FilePaths.photosFolder(jobId: jobId).appendingPathComponent(fileName)
        try FileSecurity.writeProtected(makeLargeTestPNGData(), to: photoURL)

        let photo = InspectionPhoto(fileName: fileName, caption: "Blue sample")
        let item = InspectionItem(
            templateItemId: "item",
            title: "Window",
            includeInReport: true,
            status: .inspected,
            defectSeverity: .major,
            location: "Living room",
            observed: "Observed issue",
            implication: "Implication",
            recommendation: "Recommendation",
            contractorTag: "",
            photos: [photo]
        )
        let section = InspectionSection(title: "Exterior", items: [item])
        let inspection = Inspection(
            id: jobId,
            clientName: "Photo Client",
            clientEmail: "",
            clientPhone: "",
            propertyAddress: "1 Photo Way",
            inspectionDate: Date(),
            inspectorName: "Inspector",
            sections: [section]
        )
        let version = InspectionVersion(id: jobId, versionNumber: 1, status: .draft, finalizedAt: nil, locked: false, inspection: inspection)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: FilePaths.inspectionFolder(jobId: jobId))
        }

        let pdfURL = try await PDFReportRenderer.generatePDF(for: version)

        guard let document = PDFDocument(url: pdfURL), let page = document.page(at: 0) else {
            return XCTFail("Expected image PDF document")
        }

        addTeardownBlock {
            try? FileManager.default.removeItem(at: pdfURL)
        }

        let thumbnail = page.thumbnail(of: CGSize(width: 800, height: 1000), for: .mediaBox)
        XCTAssertTrue(imageContainsBlueRegion(thumbnail))
    }

    private func makeTestPNGData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 6, height: 6))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 6, height: 6))
        }
        guard let data = image.pngData() else {
            throw NSError(domain: "HTMLReportRendererTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create test PNG"])
        }
        return data
    }

    private func makeLargeTestPNGData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 320))
        let image = renderer.image { context in
            UIColor(red: 0.08, green: 0.46, blue: 0.98, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
            UIColor.white.setFill()
            context.fill(CGRect(x: 80, y: 100, width: 320, height: 120))
        }
        guard let data = image.pngData() else {
            throw NSError(domain: "HTMLReportRendererTests", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create large test PNG"])
        }
        return data
    }

    private func imageContainsBlueRegion(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var bluePixelCount = 0
        for index in stride(from: 0, to: pixels.count, by: 16) {
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])

            if blue > 170 && blue > red + 45 && blue > green + 25 {
                bluePixelCount += 1
                if bluePixelCount > 250 {
                    return true
                }
            }
        }

        return false
    }
}

@MainActor
final class AuthManagerTests: XCTestCase {
    func testLoginRejectsEmptyCredentials() async {
        let auth = AuthManager()
        let ok = await auth.login(email: "", password: "")
        XCTAssertFalse(ok)
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertEqual(auth.role, .none)
    }

    // NOTE: createAccount/login now hit Firebase Auth over the network and
    // require a real Firebase project + network access. We exercise only the
    // local "reject empty" path here; the round-trip is covered by manual
    // smoke tests against the dev Firebase project.
}

final class TermsAcceptanceStoreTests: XCTestCase {
    func testTermsAcceptanceDoesNotCarryAcrossUsers() {
        let defaults = makeDefaults()

        XCTAssertFalse(TermsAcceptanceStore.hasAcceptedTerms(username: "alice", defaults: defaults))
        XCTAssertFalse(TermsAcceptanceStore.hasAcceptedTerms(username: "bob", defaults: defaults))

        TermsAcceptanceStore.markAccepted(username: "alice", defaults: defaults)

        XCTAssertTrue(TermsAcceptanceStore.hasAcceptedTerms(username: "alice", defaults: defaults))
        XCTAssertFalse(TermsAcceptanceStore.hasAcceptedTerms(username: "bob", defaults: defaults))
    }

    func testTermsAcceptanceIsVersioned() {
        let defaults = makeDefaults()
        let oldVersion = "2026-02-07"
        let newVersion = "2026-03-23"

        TermsAcceptanceStore.markAccepted(username: "alice", version: oldVersion, defaults: defaults)

        XCTAssertTrue(TermsAcceptanceStore.hasAcceptedTerms(username: "alice", version: oldVersion, defaults: defaults))
        XCTAssertFalse(TermsAcceptanceStore.hasAcceptedTerms(username: "alice", version: newVersion, defaults: defaults))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TermsAcceptanceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

final class RetentionPolicyTests: XCTestCase {
    func testNonAdminCannotPurge() {
        let old = VersionMetadata(
            id: UUID(),
            inspectionId: UUID(),
            versionNumber: 1,
            status: .final,
            finalizedAt: Date(timeIntervalSince1970: 0),
            locked: true,
            clientName: "Client",
            propertyAddress: "Address",
            inspectionDate: Date(timeIntervalSince1970: 0)
        )
        let result = RetentionPolicyService.purgeExpiredInspections(
            metadata: [old],
            now: Date(),
            retentionYears: 5,
            isAdmin: false,
            actorId: "tester"
        )
        XCTAssertTrue(result.deletedInspectionIDs.isEmpty)
        XCTAssertEqual(result.skippedInspectionIDs.count, 1)
    }
}

@MainActor
final class IndexMigrationFixtureTests: XCTestCase {
    func testDecodeMetadataIndexFixture() throws {
        let version = sampleVersion(versionNumber: 1)
        let metadata = VersionMetadata(from: version)
        let payload = ["schemaVersion": 1, "metadata": [try metadataDictionary(metadata)] ] as [String : Any]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = InspectionStore.decodeIndexData(data)
        guard case .metadata(let list)? = decoded else {
            return XCTFail("Expected metadata index decoding")
        }
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].versionNumber, 1)
    }

    func testDecodeLegacyArrayFixture() throws {
        let versions = [sampleVersion(versionNumber: 3)]
        let data = try JSONEncoder().encode(versions)
        let decoded = InspectionStore.decodeIndexData(data)
        guard case .legacyVersions(let list)? = decoded else {
            return XCTFail("Expected legacy array decoding")
        }
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].versionNumber, 3)
    }

    func testDecodeLegacyObjectFixture() throws {
        let versions = [sampleVersion(versionNumber: 7)]
        let data = try JSONEncoder().encode(["versions": versions])
        let decoded = InspectionStore.decodeIndexData(data)
        guard case .legacyVersions(let list)? = decoded else {
            return XCTFail("Expected legacy object decoding")
        }
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].versionNumber, 7)
    }

    private func sampleVersion(versionNumber: Int) -> InspectionVersion {
        let inspection = Inspection(
            id: UUID(),
            clientName: "Fixture Client",
            clientEmail: "fixture@example.com",
            clientPhone: "5551231234",
            propertyAddress: "123 Fixture Ave",
            inspectionDate: Date(timeIntervalSince1970: 1_700_000_000),
            inspectorName: "Inspector",
            sections: []
        )
        return InspectionVersion(
            id: UUID(),
            versionNumber: versionNumber,
            status: .draft,
            finalizedAt: nil,
            locked: false,
            inspection: inspection
        )
    }

    private func metadataDictionary(_ metadata: VersionMetadata) throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(metadata)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    }
}
