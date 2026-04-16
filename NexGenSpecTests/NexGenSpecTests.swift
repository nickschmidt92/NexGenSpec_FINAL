//
//  NexGenSpecTests.swift
//  NexGenSpec
//

import XCTest
import PDFKit
import UIKit
import Combine
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

// MARK: - Calendar / scheduling

final class InspectionSchedulingFieldsTests: XCTestCase {

    /// Verifies the new calendar fields round-trip cleanly through
    /// JSON. Backward compatibility relies on `decodeIfPresent`, so
    /// also check a decode from JSON that omits the new keys.
    func testSchedulingFieldsRoundTripThroughJSON() throws {
        let jobId = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var inspection = Inspection(
            id: jobId,
            clientName: "Client",
            propertyAddress: "1 Test Ln",
            inspectionDate: start,
            inspectorName: "Inspector",
            sections: [],
            inspectorConfirmed: false
        )
        inspection.scheduledDurationMinutes = 180
        inspection.calendarEventIdentifier = "ek-event-123"
        inspection.calendarIdentifier = "ek-cal-abc"

        let encoded = try JSONEncoder().encode(inspection)
        let decoded = try JSONDecoder().decode(Inspection.self, from: encoded)

        XCTAssertEqual(decoded.scheduledDurationMinutes, 180)
        XCTAssertEqual(decoded.calendarEventIdentifier, "ek-event-123")
        XCTAssertEqual(decoded.calendarIdentifier, "ek-cal-abc")
        XCTAssertEqual(decoded.inspectionDate, start)
    }

    func testDecodeFromLegacyJSONWithoutSchedulingFieldsDefaultsToNil() throws {
        let jobId = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // Hand-construct legacy JSON (no scheduling keys).
        let legacy: [String: Any] = [
            "inspectionId": jobId.uuidString,
            "inspectionNumber": 1,
            "title": "",
            "description": "",
            "creationDate": 0,
            "clientName": "Legacy",
            "propertyAddress": "Old Home",
            "inspectionDate": start.timeIntervalSinceReferenceDate,
            "inspectorName": "Inspector",
            "sections": [],
            "signatures": [],
            "inspectorConfirmed": true,
            "timerElapsedSeconds": 0
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let decoded = try decoder.decode(Inspection.self, from: data)

        XCTAssertNil(decoded.scheduledDurationMinutes)
        XCTAssertNil(decoded.calendarEventIdentifier)
        XCTAssertNil(decoded.calendarIdentifier)
    }

    func testHasScheduledStartTimeTreatsLocalMidnightAsUnscheduled() {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        let midnight = cal.date(from: comps)!
        let atNoon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!

        let midnightInspection = Inspection(
            clientName: "c", propertyAddress: "a",
            inspectionDate: midnight, inspectorName: "i",
            sections: [], inspectorConfirmed: false
        )
        let noonInspection = Inspection(
            clientName: "c", propertyAddress: "a",
            inspectionDate: atNoon, inspectorName: "i",
            sections: [], inspectorConfirmed: false
        )

        XCTAssertFalse(midnightInspection.hasScheduledStartTime)
        XCTAssertTrue(noonInspection.hasScheduledStartTime)
    }

    func testEffectiveDurationDefaultsToFourHours() {
        let inspection = Inspection(
            clientName: "c", propertyAddress: "a",
            inspectionDate: Date(), inspectorName: "i",
            sections: [], inspectorConfirmed: false
        )
        XCTAssertEqual(inspection.effectiveDurationMinutes, 240)
        var overridden = inspection
        overridden.scheduledDurationMinutes = 90
        XCTAssertEqual(overridden.effectiveDurationMinutes, 90)
    }

    func testScheduledEndDateAddsDuration() {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        var inspection = Inspection(
            clientName: "c", propertyAddress: "a",
            inspectionDate: start, inspectorName: "i",
            sections: [], inspectorConfirmed: false
        )
        inspection.scheduledDurationMinutes = 120
        XCTAssertEqual(
            inspection.scheduledEndDate.timeIntervalSince(start),
            120 * 60,
            accuracy: 0.1
        )
    }

    @MainActor
    func testCalendarEventTitleUsesAddress() {
        let inspection = Inspection(
            clientName: "c", propertyAddress: "42 Oak Street",
            inspectionDate: Date(), inspectorName: "i",
            sections: [], inspectorConfirmed: false
        )
        XCTAssertEqual(
            CalendarService.eventTitle(for: inspection),
            "NexGenSpec: 42 Oak Street"
        )
    }

    @MainActor
    func testCalendarEventNotesIncludeClientAndAgentContacts() {
        var inspection = Inspection(
            clientName: "Jane Buyer",
            clientEmail: "jane@example.com",
            clientPhone: "555-0100",
            propertyAddress: "42 Oak Street",
            inspectionDate: Date(),
            inspectorName: "Inspector",
            sections: [],
            inspectorConfirmed: false
        )
        inspection.buyersAgent = RealEstateAgent(
            name: "Agent Smith",
            brokerage: "ACME Realty",
            phone: "555-0123",
            email: "agent@example.com"
        )
        let notes = CalendarService.eventNotes(for: inspection)
        XCTAssertTrue(notes.contains("Jane Buyer"))
        XCTAssertTrue(notes.contains("jane@example.com"))
        XCTAssertTrue(notes.contains("555-0100"))
        XCTAssertTrue(notes.contains("Buyer's Agent"))
        XCTAssertTrue(notes.contains("ACME Realty"))
        XCTAssertTrue(notes.contains(inspection.inspectionId))
    }
}

// MARK: - Calendar preferences

final class CalendarPreferencesTests: XCTestCase {

    func testDefaultCalendarIdentifierIsNilWhenUnset() {
        CalendarPreferences.setDefaultCalendarIdentifier(nil, for: "newuser@example.com")
        XCTAssertNil(CalendarPreferences.defaultCalendarIdentifier(for: "newuser@example.com"))
    }

    func testSetAndGetDefaultCalendarIdentifier() {
        let email = "pref-test-\(UUID().uuidString)@example.com"
        CalendarPreferences.setDefaultCalendarIdentifier("cal-42", for: email)
        XCTAssertEqual(
            CalendarPreferences.defaultCalendarIdentifier(for: email),
            "cal-42"
        )
        // Normalization: same email with different case returns same value.
        XCTAssertEqual(
            CalendarPreferences.defaultCalendarIdentifier(for: email.uppercased()),
            "cal-42"
        )
        CalendarPreferences.setDefaultCalendarIdentifier(nil, for: email)
        XCTAssertNil(CalendarPreferences.defaultCalendarIdentifier(for: email))
    }

    func testAutoAddNewInspectionsDefaultsToFalse() {
        let email = "auto-test-\(UUID().uuidString)@example.com"
        XCTAssertFalse(CalendarPreferences.autoAddNewInspections(for: email))
        CalendarPreferences.setAutoAddNewInspections(true, for: email)
        XCTAssertTrue(CalendarPreferences.autoAddNewInspections(for: email))
        CalendarPreferences.setAutoAddNewInspections(false, for: email)
        XCTAssertFalse(CalendarPreferences.autoAddNewInspections(for: email))
    }
}

// MARK: - Voice command

final class VoiceCommandCalendarTests: XCTestCase {

    @MainActor
    func testGoToCalendarRecognized() {
        let mgr = VoiceCommandManager()
        let r1 = mgr.parseCommand(transcript: "go to calendar", fireAction: false)
        XCTAssertEqual(r1.command, "Go to calendar")

        let r2 = mgr.parseCommand(transcript: "open calendar", fireAction: false)
        XCTAssertEqual(r2.command, "Go to calendar")

        let r3 = mgr.parseCommand(transcript: "calendar", fireAction: false)
        XCTAssertEqual(r3.command, "Go to calendar")
    }
}

// MARK: - Calendar alarm DST / timezone correctness

/// `CalendarService.dayBeforeAt8AM` produces the absolute alarm date for
/// the day-before-8am reminder. The computation uses the user's local
/// calendar, so it must stay stable across DST transitions and must
/// not return dates in the past.
final class CalendarAlarmDSTTests: XCTestCase {

    /// US spring-forward: 8 AM on the day before a post-transition
    /// inspection must still land on the previous calendar day at
    /// 08:00 local time, not shift by an hour.
    @MainActor
    func testDayBeforeAt8AMAcrossUSSpringForward() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        // US 2026 spring-forward is 2026-03-08 02:00 -> 03:00.
        // Inspection scheduled for noon on 2026-03-08 (the DST day).
        var inspectionComps = DateComponents()
        inspectionComps.year = 2026; inspectionComps.month = 3; inspectionComps.day = 8
        inspectionComps.hour = 12; inspectionComps.minute = 0
        inspectionComps.timeZone = cal.timeZone
        let inspection = try XCTUnwrap(cal.date(from: inspectionComps))

        // Treat "now" as well before the inspection so the method
        // doesn't return nil for an in-the-past alarm.
        let now = try XCTUnwrap(cal.date(from: DateComponents(
            timeZone: cal.timeZone, year: 2026, month: 3, day: 1, hour: 0
        )))

        let alarm = try XCTUnwrap(CalendarService.dayBeforeAt8AM(
            relativeTo: inspection, calendar: cal, now: now
        ))
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: alarm)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 3)
        XCTAssertEqual(parts.day, 7)      // day before inspection
        XCTAssertEqual(parts.hour, 8)     // 8 AM local, despite DST next day
        XCTAssertEqual(parts.minute, 0)
    }

    /// US fall-back: same invariants on the other DST edge.
    @MainActor
    func testDayBeforeAt8AMAcrossUSFallBack() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        // US 2026 fall-back is 2026-11-01 02:00 -> 01:00.
        var inspectionComps = DateComponents()
        inspectionComps.year = 2026; inspectionComps.month = 11; inspectionComps.day = 1
        inspectionComps.hour = 14; inspectionComps.minute = 30
        inspectionComps.timeZone = cal.timeZone
        let inspection = try XCTUnwrap(cal.date(from: inspectionComps))
        let now = try XCTUnwrap(cal.date(from: DateComponents(
            timeZone: cal.timeZone, year: 2026, month: 10, day: 25, hour: 0
        )))

        let alarm = try XCTUnwrap(CalendarService.dayBeforeAt8AM(
            relativeTo: inspection, calendar: cal, now: now
        ))
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: alarm)
        XCTAssertEqual(parts.day, 31)
        XCTAssertEqual(parts.month, 10)
        XCTAssertEqual(parts.hour, 8)
    }

    /// If the computed alarm is already in the past the method returns
    /// nil — EventKit rejects absolute alarms for past dates.
    @MainActor
    func testDayBeforeAt8AMReturnsNilWhenInThePast() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let inspection = try XCTUnwrap(cal.date(from: DateComponents(
            timeZone: cal.timeZone, year: 2020, month: 6, day: 15, hour: 10
        )))
        let now = try XCTUnwrap(cal.date(from: DateComponents(
            timeZone: cal.timeZone, year: 2026, month: 1, day: 1, hour: 0
        )))

        let alarm = CalendarService.dayBeforeAt8AM(
            relativeTo: inspection, calendar: cal, now: now
        )
        XCTAssertNil(alarm)
    }

    /// Year-boundary crossover: an inspection on Jan 1 should produce a
    /// day-before alarm on Dec 31 of the previous year.
    @MainActor
    func testDayBeforeAt8AMCrossesYearBoundary() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Denver")!
        let inspection = try XCTUnwrap(cal.date(from: DateComponents(
            timeZone: cal.timeZone, year: 2027, month: 1, day: 1, hour: 9
        )))
        let now = try XCTUnwrap(cal.date(from: DateComponents(
            timeZone: cal.timeZone, year: 2026, month: 12, day: 15, hour: 0
        )))

        let alarm = try XCTUnwrap(CalendarService.dayBeforeAt8AM(
            relativeTo: inspection, calendar: cal, now: now
        ))
        let parts = cal.dateComponents([.year, .month, .day, .hour], from: alarm)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 12)
        XCTAssertEqual(parts.day, 31)
        XCTAssertEqual(parts.hour, 8)
    }
}

// MARK: - Tab router notification bridge

/// The voice-command deep-link "go to calendar" posts a notification
/// that `MainTabView` observes to switch the active tab. This test
/// validates the observer wiring without mounting the view hierarchy.
final class TabRouterNotificationTests: XCTestCase {

    @MainActor
    func testRouterSwitchesToCalendarOnNotification() async {
        let router = TabRouter(initial: .workspace)
        // Mirror the observer `MainTabView` installs.
        let cancellable = NotificationCenter.default
            .publisher(for: .nexGenSpecRequestCalendarTab)
            .sink { _ in router.show(.calendar) }
        defer { cancellable.cancel() }

        XCTAssertEqual(router.selected, .workspace)
        NotificationCenter.default.post(name: .nexGenSpecRequestCalendarTab, object: nil)
        // Publisher is synchronous on the main run loop, but yield to
        // flush any pending Combine delivery.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(router.selected, .calendar)
    }
}

// MARK: - End-to-end calendar integration flows
//
// These tests exercise the InspectionStore-level orchestration for
// the scheduling / Add-to-Calendar / Update / cascade-delete flows
// that would otherwise require a real device + EventKit grant to
// verify manually. EKEventStore access is gracefully rejected in
// the test environment (authorization state is .notDetermined), so
// any code that guards behind `authorizationState.canCreateEvents`
// no-ops; the value here is proving the surrounding InspectionStore
// logic is correct and doesn't crash when EventKit is unavailable.

@MainActor
final class CalendarIntegrationFlowsTests: XCTestCase {

    // MARK: - Helpers

    private func makeInspection(
        id: UUID = UUID(),
        start: Date = Date(timeIntervalSince1970: 1_750_000_000),
        calendarEventIdentifier: String? = nil,
        calendarIdentifier: String? = nil,
        durationMinutes: Int? = nil
    ) -> Inspection {
        var insp = Inspection(
            id: id,
            clientName: "Test Client",
            clientEmail: "",
            clientPhone: "",
            propertyAddress: "100 Integration Rd",
            inspectionDate: start,
            inspectorName: "Tester",
            sections: [],
            inspectorConfirmed: false
        )
        insp.scheduledDurationMinutes = durationMinutes
        insp.calendarEventIdentifier = calendarEventIdentifier
        insp.calendarIdentifier = calendarIdentifier
        return insp
    }

    private func makeFinalizedVersion(inspection: Inspection) -> InspectionVersion {
        InspectionVersion(
            id: UUID(),
            versionNumber: 1,
            status: .final,
            finalizedAt: Date(),
            locked: true,
            inspection: inspection
        )
    }

    private func makeDraftVersion(inspection: Inspection) -> InspectionVersion {
        InspectionVersion(
            id: UUID(),
            versionNumber: 1,
            status: .draft,
            finalizedAt: nil,
            locked: false,
            inspection: inspection
        )
    }

    // MARK: - "New inspection with scheduling" flow

    /// When an inspector schedules a new inspection (sets duration +
    /// start time), those fields must survive the disk round-trip
    /// that happens inside `insert(version:)` → `loadFullVersion(id:)`.
    /// This is the path exercised when the user creates an inspection
    /// on one launch and reopens it on the next.
    func testNewInspectionPreservesSchedulingFieldsThroughStoreRoundTrip() throws {
        let jobId = UUID()
        try FilePaths.ensureAppStructure(jobId: jobId)
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let inspection = makeInspection(
            id: jobId,
            start: start,
            calendarEventIdentifier: "ek-evt-xyz",
            calendarIdentifier: "ek-cal-abc",
            durationMinutes: 150
        )
        let version = makeDraftVersion(inspection: inspection)

        let store = InspectionStore()
        store.insert(version: version)

        guard let reloaded = store.loadFullVersion(id: version.id) else {
            return XCTFail("Could not reload inserted version")
        }
        XCTAssertEqual(reloaded.inspection.scheduledDurationMinutes, 150)
        XCTAssertEqual(reloaded.inspection.calendarEventIdentifier, "ek-evt-xyz")
        XCTAssertEqual(reloaded.inspection.calendarIdentifier, "ek-cal-abc")
        XCTAssertEqual(reloaded.inspection.inspectionDate, start)

        // Cleanup — otherwise subsequent tests see a lingering version.
        _ = store.deleteVersion(id: version.id)
    }

    // MARK: - "Update flow"

    /// After calling `update(version:)` on a draft whose inspector
    /// changed the scheduled start time, the reloaded copy must
    /// reflect the new start time AND retain the previously-set
    /// calendar event identifier (the UI is expected to call
    /// CalendarService.updateEvent separately for that).
    func testUpdateVersionPersistsNewStartAndKeepsCalendarIdentifier() throws {
        let jobId = UUID()
        try FilePaths.ensureAppStructure(jobId: jobId)
        let initialStart = Date(timeIntervalSince1970: 1_750_000_000)
        let inspection = makeInspection(
            id: jobId,
            start: initialStart,
            calendarEventIdentifier: "ek-evt-keep",
            calendarIdentifier: "ek-cal-keep",
            durationMinutes: 90
        )
        let version = makeDraftVersion(inspection: inspection)

        let store = InspectionStore()
        store.insert(version: version)

        // Mutate start and duration; re-save.
        var edited = version
        let newStart = initialStart.addingTimeInterval(3600)
        edited.inspection.inspectionDate = newStart
        edited.inspection.scheduledDurationMinutes = 180
        store.update(version: edited)

        guard let reloaded = store.loadFullVersion(id: version.id) else {
            return XCTFail("Could not reload updated version")
        }
        XCTAssertEqual(reloaded.inspection.inspectionDate, newStart)
        XCTAssertEqual(reloaded.inspection.scheduledDurationMinutes, 180)
        XCTAssertEqual(reloaded.inspection.calendarEventIdentifier, "ek-evt-keep")
        XCTAssertEqual(reloaded.inspection.calendarIdentifier, "ek-cal-keep")

        _ = store.deleteVersion(id: version.id)
    }

    // MARK: - Cascade delete

    /// `deleteVersion` must also try to remove any mirrored EKEvent.
    /// In a test context EventKit access is not granted, so
    /// `CalendarService.deleteEvent` throws `.notAuthorized`; the
    /// InspectionStore path wraps that in `try?` so the version
    /// removal still succeeds. This test proves the cascade path
    /// does not crash and the local metadata + files are still
    /// cleaned up even when EventKit is unavailable.
    func testDeleteVersionWithCalendarIDCleanlyRemovesLocalArtifactsWithoutEventKit() throws {
        let jobId = UUID()
        try FilePaths.ensureAppStructure(jobId: jobId)
        let inspection = makeInspection(
            id: jobId,
            calendarEventIdentifier: "ek-evt-nuke",
            calendarIdentifier: "ek-cal-nuke"
        )
        let version = makeDraftVersion(inspection: inspection)

        // Seed an artifact on disk inside the inspection folder so
        // we can assert the folder is actually nuked, not just the
        // metadata entry.
        let artifact = FilePaths.photosFolder(jobId: jobId).appendingPathComponent("seed.txt")
        try FileSecurity.writeProtected(Data("seed".utf8), to: artifact)

        let store = InspectionStore()
        store.insert(version: version)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))

        XCTAssertTrue(store.deleteVersion(id: version.id))
        XCTAssertNil(store.loadFullVersion(id: version.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            FilePaths.inspectionFolder(jobId: jobId).path))
    }

    // MARK: - Revision-created from finalized version (audit-fix regression)

    /// When the inspector hits "Create Revision" on a finalized
    /// version that was linked to a calendar event, the new DRAFT
    /// must NOT inherit the parent's `calendarEventIdentifier` /
    /// `calendarIdentifier`. Otherwise deleting the draft would
    /// cascade-delete the parent's calendar event — a silent data
    /// loss bug caught in the 2026-04-15 audit.
    func testCreateRevisionFromFinalizedClearsCalendarLink() throws {
        let jobId = UUID()
        try FilePaths.ensureAppStructure(jobId: jobId)
        let inspection = makeInspection(
            id: jobId,
            calendarEventIdentifier: "ek-evt-finalized",
            calendarIdentifier: "ek-cal-finalized"
        )
        let finalized = makeFinalizedVersion(inspection: inspection)

        let store = InspectionStore()
        store.insert(version: finalized)

        guard let newDraftId = store.createRevision(from: finalized.id) else {
            return XCTFail("createRevision should succeed from a finalized version")
        }
        guard let draft = store.loadFullVersion(id: newDraftId) else {
            return XCTFail("Could not reload newly-created revision draft")
        }

        XCTAssertNil(draft.inspection.calendarEventIdentifier,
                     "Revision draft must not inherit parent EKEvent identifier")
        XCTAssertNil(draft.inspection.calendarIdentifier,
                     "Revision draft must not inherit parent EKCalendar identifier")
        // Parent remains untouched.
        let parent = store.loadFullVersion(id: finalized.id)
        XCTAssertEqual(parent?.inspection.calendarEventIdentifier, "ek-evt-finalized")
        XCTAssertEqual(parent?.inspection.calendarIdentifier, "ek-cal-finalized")

        _ = store.deleteVersion(id: newDraftId)
        // Finalized parent cannot be deleted via deleteVersion; cleanup
        // by removing the folder directly.
        try? FileManager.default.removeItem(at: FilePaths.inspectionFolder(jobId: jobId))
    }

    // MARK: - Purge cascade

    /// Parallel to the deleteVersion cascade: purging finalized
    /// inspections older than the retention window must also try to
    /// delete mirrored EKEvents. With no EventKit access the EK side
    /// quietly fails; the InspectionStore purge must still remove
    /// the inspection folder and return the version ID in the
    /// deleted set.
    func testPurgeExpiredCascadesWithoutEventKitAccess() throws {
        let jobId = UUID()
        try FilePaths.ensureAppStructure(jobId: jobId)
        let oldFinalizedAt = Calendar.current.date(byAdding: .year, value: -6, to: Date())!
        let inspection = makeInspection(
            id: jobId,
            calendarEventIdentifier: "ek-evt-expired",
            calendarIdentifier: "ek-cal-expired"
        )
        let expired = InspectionVersion(
            id: UUID(),
            versionNumber: 1,
            status: .final,
            finalizedAt: oldFinalizedAt,
            locked: true,
            inspection: inspection
        )

        let store = InspectionStore()
        store.insert(version: expired)

        let result = store.purgeExpiredInspections(isAdmin: true, actorId: "tester@example.com")
        XCTAssertTrue(result.deletedInspectionIDs.contains(expired.id),
                      "Expired finalized version should be purged")
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            FilePaths.inspectionFolder(jobId: jobId).path))
    }

    // MARK: - Legacy inspection load

    /// When opening an inspection created BEFORE the scheduling
    /// fields existed (pre-2026-04 build), loading must succeed and
    /// leave the new fields as nil rather than corrupting decoding
    /// or forcing a user-visible default. This is the primary
    /// backward-compat guarantee we ship.
    func testLegacyInspectionLoadsCleanlyWithNilCalendarFields() throws {
        let jobId = UUID()
        try FilePaths.ensureAppStructure(jobId: jobId)
        let legacy = makeInspection(id: jobId) // no calendar fields, no duration
        let version = makeDraftVersion(inspection: legacy)

        let store = InspectionStore()
        store.insert(version: version)

        guard let reloaded = store.loadFullVersion(id: version.id) else {
            return XCTFail("Legacy inspection failed to reload")
        }
        XCTAssertNil(reloaded.inspection.scheduledDurationMinutes)
        XCTAssertNil(reloaded.inspection.calendarEventIdentifier)
        XCTAssertNil(reloaded.inspection.calendarIdentifier)
        // Default-duration accessor still returns the 4-hour fallback.
        XCTAssertEqual(reloaded.inspection.effectiveDurationMinutes, 240)

        _ = store.deleteVersion(id: version.id)
    }
}
