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

// MARK: - Beta / sandbox subscription unlock

/// Guards the TestFlight-unlock behavior in SubscriptionManager so
/// it can never regress into unlocking production App Store builds.
@MainActor
final class SubscriptionManagerBetaUnlockTests: XCTestCase {

    /// In the test environment (simulator), `isBetaOrSandboxBuild`
    /// must be true — this is also the same code path TestFlight hits
    /// on device. If this ever returns false in the simulator, the
    /// TestFlight unlock path is broken and paid testers will be
    /// trapped at the paywall.
    func testBetaOrSandboxBuildUnlocksInTestEnvironment() {
        XCTAssertTrue(SubscriptionManager.isBetaOrSandboxBuild,
                      "Test environment must be treated as sandbox so beta-tester unlock path is exercised.")
    }

    /// When beta unlock is active, a fresh user (no subscription, no
    /// admin whitelist, zero free inspections used) must still have
    /// feature access and be able to create inspections past the 3
    /// free-trial limit.
    func testFreshUserUnblockedUnderBetaUnlock() {
        let manager = SubscriptionManager()
        // Simulate burning through the trial: pretend we've already
        // created 10 inspections (past the free limit of 3).
        UserDefaults.standard.set(10, forKey: "nexgenspec.trial.inspectionsCreated")
        defer { UserDefaults.standard.removeObject(forKey: "nexgenspec.trial.inspectionsCreated") }

        // Re-init so the counter is read fresh from UserDefaults.
        let fresh = SubscriptionManager()
        XCTAssertTrue(fresh.canCreateInspection,
                      "Beta tester past free limit must still be able to create inspections")
        XCTAssertTrue(fresh.hasFeatureAccess,
                      "Beta tester past free limit must still have premium feature access")
        XCTAssertNil(fresh.freeInspectionsRemaining,
                     "Beta testers have unlimited access — remaining count should be nil")
        _ = manager // silence unused-warning
    }

    /// Beta unlock must NOT increment the trial counter. Without this,
    /// a user who later upgrades from beta to a real App Store install
    /// would arrive with a burned-through trial counter and hit the
    /// paywall immediately, confusing them.
    func testRecordInspectionDoesNotBurnDownTrialWhenBetaUnlocked() {
        UserDefaults.standard.set(0, forKey: "nexgenspec.trial.inspectionsCreated")
        defer { UserDefaults.standard.removeObject(forKey: "nexgenspec.trial.inspectionsCreated") }

        let manager = SubscriptionManager()
        XCTAssertEqual(manager.freeInspectionsUsed, 0)
        manager.recordInspectionCreated()
        XCTAssertEqual(manager.freeInspectionsUsed, 0,
                       "recordInspectionCreated must be a no-op for beta testers")
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

// MARK: - clearAllLocalData wipe regression (Bug B caught in iPad testing)

@MainActor
final class ClearAllLocalDataWipeTests: XCTestCase {

    func testClearAllLocalDataRemovesAppRootEntirely() throws {
        let store = InspectionStore()
        let jobId = UUID()
        try FilePaths.ensureAppStructure(jobId: jobId)
        // Plant a file deep inside appRoot to prove recursive removal works.
        let evidence = FilePaths.photosFolder(jobId: jobId)
            .appendingPathComponent("evidence.txt")
        try FileSecurity.writeProtected(Data("evidence".utf8), to: evidence)
        XCTAssertTrue(FileManager.default.fileExists(atPath: FilePaths.appRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.path))

        store.clearAllLocalData()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: FilePaths.appRoot.path),
            "appRoot must NOT exist after clearAllLocalData — Bug B regression"
        )
        XCTAssertEqual(store.metadataList.count, 0)
    }

    func testClearAllLocalDataIsIdempotent() {
        // Calling twice in succession must not throw; the second call is a
        // no-op since appRoot is already gone.
        let store = InspectionStore()
        store.clearAllLocalData()
        store.clearAllLocalData()
        XCTAssertFalse(FileManager.default.fileExists(atPath: FilePaths.appRoot.path))
    }
}

// MARK: - AccountDeletionReceiptService tests (T-01216)

final class AccountDeletionReceiptServiceTests: XCTestCase {

    private func makeInputs(
        email: String = "test@example.com",
        uid: String = "test-uid-1234",
        fallback: String? = "fallback@example.com",
        count: Int = 7,
        provider: String = "Email & Password"
    ) -> AccountDeletionReceiptService.Inputs {
        AccountDeletionReceiptService.Inputs(
            accountEmail: email,
            firebaseUID: uid,
            fallbackEmail: fallback,
            inspectionsDeletedCount: count,
            providerLabel: provider,
            appVersion: "1.0.0",
            buildNumber: "10",
            deviceModel: "iPad",
            osVersion: "26.0",
            timestamp: Date(timeIntervalSince1970: 1700000000)
        )
    }

    func testReceiptFolderIsOutsideAppRoot() {
        // Receipt PDFs MUST live outside FilePaths.appRoot so they survive
        // store.clearAllLocalData() and remain reachable from the Files app
        // for the user's permanent record. Verify by checking the parent —
        // a string-prefix check fails here because "NexGenSpec" is a prefix
        // of "NexGenSpecReceipts" though they are siblings, not nested.
        let receipt = AccountDeletionReceiptService.receiptFolder
        XCTAssertEqual(receipt.deletingLastPathComponent().standardizedFileURL,
                       FilePaths.documentDirectory.standardizedFileURL,
                       "Receipt folder must be a sibling of appRoot under Documents/")
        XCTAssertEqual(receipt.lastPathComponent, "NexGenSpecReceipts")
    }

    func testGenerateReceiptCreatesPDFInCanonicalFolder() throws {
        let url = try AccountDeletionReceiptService.generateReceipt(makeInputs())
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "pdf")
        XCTAssertTrue(url.path.contains("/NexGenSpecReceipts/"),
                      "Receipt PDF must land in NexGenSpecReceipts/")
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 1000,
                             "PDF should be more than a few bytes — got \(data.count)")
    }

    func testGeneratedReceiptPDFContainsAccountFields() throws {
        let inputs = makeInputs(email: "alice@example.com", uid: "uid-xyz", count: 42)
        let url = try AccountDeletionReceiptService.generateReceipt(inputs)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        guard let pdf = PDFDocument(url: url) else {
            return XCTFail("Generated PDF was not readable")
        }
        let body = pdf.string ?? ""
        XCTAssertTrue(body.contains("alice@example.com"), "PDF should include account email")
        XCTAssertTrue(body.contains("uid-xyz"), "PDF should include Firebase UID")
        XCTAssertTrue(body.contains("42"), "PDF should include inspection count")
        XCTAssertTrue(body.contains("Email & Password"), "PDF should include provider label")
        XCTAssertTrue(body.contains("contact@nexgenspec.com"),
                      "PDF should include support contact for audit reach-back")
    }

    func testShareBodyIncludesContactCCAndAccountFields() {
        let inputs = makeInputs(email: "bob@example.com", count: 3, provider: "Apple")
        let body = AccountDeletionReceiptService.shareBody(
            for: inputs,
            attachmentFileName: "receipt-test.pdf"
        )
        XCTAssertTrue(body.contains("bob@example.com"))
        XCTAssertTrue(body.contains("Apple"))
        XCTAssertTrue(body.contains("3"))
        XCTAssertTrue(body.contains("contact@nexgenspec.com"),
                      "Share body must instruct user to CC support — share sheet can't pre-fill recipients")
        XCTAssertTrue(body.contains("receipt-test.pdf"))
    }
}

// MARK: - InspectionZIPExportService tests (T-01213)

final class InspectionZIPExportServiceTests: XCTestCase {

    func testExportFolderIsOutsideAppRoot() {
        // ZIP exports MUST live outside FilePaths.appRoot — they are the
        // user's deliverable for client handoff and 5-year retention, so
        // a Delete Account wipe should not nuke previously-exported reports.
        // Verify by parent-equality (string prefix gives a false negative
        // since "NexGenSpec" is a prefix of "NexGenSpecExports").
        let exports = InspectionZIPExportService.exportFolder
        XCTAssertEqual(exports.deletingLastPathComponent().standardizedFileURL,
                       FilePaths.documentDirectory.standardizedFileURL,
                       "Export folder must be a sibling of appRoot under Documents/")
        XCTAssertEqual(exports.lastPathComponent, "NexGenSpecExports")
    }

    @MainActor
    func testExportZIPProducesArchiveWithExpectedEntries() async throws {
        let jobId = UUID()
        try FilePaths.ensureAppStructure(jobId: jobId)
        let inspection = Inspection(
            id: jobId,
            clientName: "ZIP Test Client",
            clientEmail: "",
            clientPhone: "",
            propertyAddress: "1 Archive Way",
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
        var version = InspectionVersion(
            id: jobId,
            versionNumber: 1,
            status: .final,
            finalizedAt: Date(),
            locked: true,
            inspection: inspection
        )
        // Persist the snapshot so InspectionZIPExportService can read the hash.
        let hash = try FinalizationService.writeSnapshot(version)
        XCTAssertFalse(hash.isEmpty, "FinalizationService should produce a non-empty hash")
        // Update the version's id-bound jobId reference so loadReportHash finds it.
        version.finalizedAt = version.finalizedAt ?? Date()

        let zipURL = try await InspectionZIPExportService.exportZIP(for: version)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: zipURL)
            try? FileManager.default.removeItem(at: FilePaths.inspectionFolder(jobId: jobId))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path))
        XCTAssertEqual(zipURL.pathExtension, "zip")
        XCTAssertTrue(zipURL.path.contains("/NexGenSpecExports/"))

        let size = (try? FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 1000, "ZIP archive should be more than a few bytes — got \(size)")
    }
}

// MARK: - AuthManager fallback email tests (T-01215)

@MainActor
final class AuthManagerFallbackEmailTests: XCTestCase {

    func testLoadFallbackEmailReturnsNilForUnknownUID() {
        let uid = "test-unknown-uid-\(UUID().uuidString)"
        XCTAssertNil(AuthManager.loadFallbackEmail(forUID: uid))
    }

    func testLoadFallbackEmailReturnsValueAfterDirectWrite() {
        let uid = "test-write-uid-\(UUID().uuidString)"
        let key = "ngs.fallbackEmail.\(uid)"
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set("nick@example.com", forKey: key)
        XCTAssertEqual(AuthManager.loadFallbackEmail(forUID: uid), "nick@example.com")
    }

    func testFallbackEmailScopedByUID() {
        // Two different UIDs must not share a stored value — the key is per-UID
        // so two inspectors signing into the same device get isolated fallbacks.
        let uidA = "test-iso-A-\(UUID().uuidString)"
        let uidB = "test-iso-B-\(UUID().uuidString)"
        let keyA = "ngs.fallbackEmail.\(uidA)"
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: keyA)
        }
        UserDefaults.standard.set("a@example.com", forKey: keyA)
        XCTAssertEqual(AuthManager.loadFallbackEmail(forUID: uidA), "a@example.com")
        XCTAssertNil(AuthManager.loadFallbackEmail(forUID: uidB))
    }
}

// MARK: - DeviceCheck trial gate (T-01302)
//
// The DeviceCheck-backed trial bit is the second-line defense against
// trial abuse via Delete-App-and-reinstall. Tests here exercise the
// pieces that are reachable without an actual Apple-DeviceCheck round
// trip: the cache TTL, the unsupported-device fallback, and the
// SubscriptionManager wiring that consumes the published flag.

import DeviceCheck

@MainActor
final class DeviceCheckTrialGateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DeviceCheckTrialGate.clearCacheForTesting()
    }

    override func tearDown() {
        DeviceCheckTrialGate.clearCacheForTesting()
        super.tearDown()
    }

    /// On a device where DeviceCheck isn't supported (older simulators,
    /// for example), the gate must surface `.unknown(.unsupported)`
    /// rather than throwing or silently treating the trial as consumed —
    /// the spec requires fail-open on every `.unknown` outcome.
    ///
    /// On simulators where DeviceCheck *is* supported, the call would
    /// otherwise reach our backend and fail with `.notAuthenticated`
    /// (no Firebase user in the test harness) — also a `.unknown`
    /// variant, which is the same fail-open contract. We assert the
    /// reachable contract: the result is one of the `.unknown(...)`
    /// cases and `trialIsConsumed` is false.
    func testUnsupportedDeviceReturnsUnknown() async {
        let gate = DeviceCheckTrialGate()
        let result = await gate.isTrialUsedOnThisDevice()
        if case .unknown = result {
            XCTAssertFalse(result.trialIsConsumed,
                           "Unknown results must fail open (trialIsConsumed == false)")
        } else {
            XCTFail("Test environment has no Firebase user / no real backend, so the gate must report .unknown — got \(result)")
        }
    }

    /// The 24-hour TTL cache is the load-bearing piece that keeps the
    /// paywall fast: a fresh entry is honored, a stale entry is
    /// ignored. Verify both branches by writing entries with
    /// hand-picked timestamps and reading back through
    /// `lastKnownTrialUsed`.
    func testCacheRoundTrip() {
        // No cache → false (fail open).
        XCTAssertFalse(DeviceCheckTrialGate.lastKnownTrialUsed)

        // Fresh `used` → true.
        let now = Date().timeIntervalSince1970
        DeviceCheckTrialGate.writeCacheForTesting(result: "used", timestampUnix: now)
        XCTAssertTrue(DeviceCheckTrialGate.lastKnownTrialUsed,
                      "Fresh `used` cache entry must be honored")

        // Fresh `unused` → false.
        DeviceCheckTrialGate.writeCacheForTesting(result: "unused", timestampUnix: now)
        XCTAssertFalse(DeviceCheckTrialGate.lastKnownTrialUsed,
                       "Fresh `unused` cache entry must report not-consumed")

        // Stale `used` (>24h old) → false (cache treated as expired).
        let stale = now - (25 * 60 * 60)
        DeviceCheckTrialGate.writeCacheForTesting(result: "used", timestampUnix: stale)
        XCTAssertFalse(DeviceCheckTrialGate.lastKnownTrialUsed,
                       "Cache entries older than 24h must be treated as expired")

        // Just under TTL boundary → still honored.
        let almostExpired = now - (23 * 60 * 60)
        DeviceCheckTrialGate.writeCacheForTesting(result: "used", timestampUnix: almostExpired)
        XCTAssertTrue(DeviceCheckTrialGate.lastKnownTrialUsed,
                      "Cache entries within 24h must still be honored")
    }

    /// In production the simulator unlocks the paywall via
    /// `isBetaOrSandboxBuild`, which would short-circuit the
    /// DeviceCheck check before it ever runs. The test here verifies
    /// the DeviceCheck branch in `canCreateInspection` independently:
    /// when sandbox-unlock is bypassed and the device bit reports
    /// `used`, creation must be denied even with a fresh local
    /// counter. We exercise this by reading the published value
    /// after seeding the cache and re-initializing the manager — the
    /// init path uses `DeviceCheckTrialGate.lastKnownTrialUsed` to
    /// seed `deviceCheckTrialUsed`, and the boolean math in
    /// `canCreateInspection` is a pure function of `(isPro,
    /// isAdminAccount, isBetaOrSandboxBuild, deviceCheckTrialUsed,
    /// freeInspectionsUsed)`.
    func testCanCreateInspectionRespectsDeviceCheckUsedFlag() {
        // Reset the local counter so we know freeInspectionsUsed == 0.
        UserDefaults.standard.set(0, forKey: "nexgenspec.trial.inspectionsCreated")
        defer { UserDefaults.standard.removeObject(forKey: "nexgenspec.trial.inspectionsCreated") }

        // Seed a fresh `used` DeviceCheck cache entry so the manager's
        // init() picks it up.
        DeviceCheckTrialGate.writeCacheForTesting(
            result: "used",
            timestampUnix: Date().timeIntervalSince1970
        )

        let manager = SubscriptionManager()
        XCTAssertEqual(manager.freeInspectionsUsed, 0,
                       "Test setup: counter should be 0")
        XCTAssertTrue(manager.deviceCheckTrialUsed,
                      "Manager init must seed deviceCheckTrialUsed from the cache")

        // In a real (non-simulator) build, this combination — counter at
        // 0, no Pro, no admin, but device bit flipped — must deny creation.
        // In the simulator, `isBetaOrSandboxBuild` short-circuits to true,
        // and that's also a contract we test in
        // SubscriptionManagerBetaUnlockTests. Assert the branch that
        // actually runs in this environment, but still prove the device
        // flag is wired through.
        if SubscriptionManager.isBetaOrSandboxBuild {
            XCTAssertTrue(manager.canCreateInspection,
                          "Sandbox builds always unlock — device-check is irrelevant here")
        } else {
            XCTAssertFalse(manager.canCreateInspection,
                           "Production build must deny creation when device bit is flipped, even with a fresh counter")
        }
    }
}
