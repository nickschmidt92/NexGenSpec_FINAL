//
//  NexGenSpecTests.swift
//  NexGenSpec
//

import XCTest
import PDFKit
import UIKit
import Combine
import CoreImage
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

    /// Perf-pass regression guard: the off-main autosave write
    /// (`writeVersionFileOnlyForAutoSave` → `ioQueue.async`) must still persist
    /// an edit durably across a process restart. A brand-new `InspectionStore`
    /// re-reads from disk in `init()`, exactly like a fresh process after a
    /// force-kill + relaunch; `writeProtected` is atomic, so a kill mid-write
    /// can only leave the complete old or complete new file (never a torn one).
    func testAutosaveWritePersistsEditAcrossRelaunch() throws {
        let store = InspectionStore()
        let jobId = UUID()
        let marker = "AUTOSAVE-PERSIST-\(UUID().uuidString)"

        let item = InspectionItem(templateItemId: "t1", title: "Roof covering")
        let section = InspectionSection(id: UUID(), title: "Roof", items: [item])
        let inspection = Inspection(
            id: jobId,
            clientName: "Autosave Test",
            clientEmail: "",
            clientPhone: "",
            propertyAddress: "1 Persistence Way",
            inspectionDate: Date(),
            inspectorName: "Inspector",
            sections: [section]
        )
        let version = InspectionVersion(
            id: jobId,
            versionNumber: 1,
            status: .draft,
            finalizedAt: nil,
            locked: false,
            inspection: inspection
        )
        store.insert(version: version)
        defer { _ = store.deleteVersion(id: jobId) }

        // Edit a finding comment and drive the exact off-main autosave path.
        var edited = version
        edited.inspection.sections[0].items[0].observed = marker
        store.writeVersionFileOnlyForAutoSave(edited)

        // loadFullVersion uses ioQueue.sync, which blocks behind the queued
        // async write (serial FIFO) — this confirms the write reached disk and
        // mirrors "edit, wait 2s for autosave to complete" before the kill.
        XCTAssertEqual(
            store.loadFullVersion(id: jobId)?.inspection.sections.first?.items.first?.observed,
            marker,
            "autosave write did not reach disk"
        )

        // Force-kill + relaunch simulation: a brand-new store reads from disk
        // in init(), exactly like a fresh process after the app is killed.
        let relaunched = InspectionStore()
        XCTAssertEqual(
            relaunched.loadFullVersion(id: jobId)?.inspection.sections.first?.items.first?.observed,
            marker,
            "edit did NOT persist across relaunch"
        )
    }
}

/// B-0044 — corrupt-index recovery / no-clobber. These tests are coupled to the
/// real on-disk store (`InspectionStore` has no injectable root), so `setUp`
/// relocates any existing store aside for a clean, deterministic `appRoot` and
/// `tearDown` restores it.
@MainActor
final class InspectionIndexRecoveryTests: XCTestCase {

    private var stashDir: URL!
    private var inspectionsDir: URL { FilePaths.appRoot.appendingPathComponent("Inspections", isDirectory: true) }

    override func setUpWithError() throws {
        let fm = FileManager.default
        try FileSecurity.ensureProtectedDirectory(FilePaths.appRoot)
        stashDir = fm.temporaryDirectory.appendingPathComponent("ngs-b0044-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stashDir, withIntermediateDirectories: true)
        try moveAside(inspectionsDir, named: "Inspections")
        try moveAside(FilePaths.inspectionsIndex, named: "inspections.json")
        try moveAside(FilePaths.inspectionsIndexBackup, named: "inspections.json.backup")
    }

    override func tearDownWithError() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: inspectionsDir)
        try? fm.removeItem(at: FilePaths.inspectionsIndex)
        try? fm.removeItem(at: FilePaths.inspectionsIndexBackup)
        try moveBack(named: "Inspections", to: inspectionsDir)
        try moveBack(named: "inspections.json", to: FilePaths.inspectionsIndex)
        try moveBack(named: "inspections.json.backup", to: FilePaths.inspectionsIndexBackup)
        try? fm.removeItem(at: stashDir)
        stashDir = nil
    }

    private func moveAside(_ url: URL, named: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.moveItem(at: url, to: stashDir.appendingPathComponent(named))
    }
    private func moveBack(named: String, to dest: URL) throws {
        let fm = FileManager.default
        let src = stashDir.appendingPathComponent(named)
        guard fm.fileExists(atPath: src.path) else { return }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: src, to: dest)
    }

    // MARK: fixtures

    private func makeVersion(id: UUID = UUID(), client: String) -> InspectionVersion {
        let inspection = Inspection(id: id, clientName: client, clientEmail: "", clientPhone: "",
                                    propertyAddress: "addr", inspectionDate: Date(), inspectorName: "Insp", sections: [])
        return InspectionVersion(id: id, versionNumber: 1, status: .draft, finalizedAt: nil, locked: false, inspection: inspection)
    }
    private func writeCurrentJson(_ v: InspectionVersion) throws {
        try FileSecurity.ensureProtectedDirectory(FilePaths.inspectionFolder(jobId: v.id))
        try FileSecurity.writeProtected(try JSONEncoder().encode(v), to: FilePaths.currentVersionFile(jobId: v.id))
    }
    /// Writes a native `MetadataIndex`-shaped index (so loading it does NOT
    /// trigger the legacy-array migration's extra saves).
    private func writeMetadataIndex(_ versions: [InspectionVersion], to url: URL) throws {
        let metaJSON = try JSONEncoder().encode(versions.map { VersionMetadata(from: $0) })
        let json = "{\"schemaVersion\":1,\"metadata\":\(String(decoding: metaJSON, as: UTF8.self))}"
        try FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
        try FileSecurity.writeProtected(Data(json.utf8), to: url)
    }
    private func writeGarbage(to url: URL) throws {
        try FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
        try FileSecurity.writeProtected(Data("}{ not a valid index ".utf8), to: url)
    }

    // MARK: tests

    /// A corrupt primary must NOT clobber a good backup: the store recovers from
    /// the backup AND leaves the backup file byte-identical (the central claim).
    func testCorruptPrimaryRecoversFromBackupWithoutClobberingIt() throws {
        let a = makeVersion(client: "Alpha"), b = makeVersion(client: "Bravo")
        try writeMetadataIndex([a, b], to: FilePaths.inspectionsIndexBackup)
        try writeGarbage(to: FilePaths.inspectionsIndex)
        let backupBefore = try Data(contentsOf: FilePaths.inspectionsIndexBackup)

        let store = InspectionStore()
        let ids = Set(store.metadataList.map(\.id))
        XCTAssertTrue(ids.contains(a.id) && ids.contains(b.id), "did not recover both entries from backup")
        XCTAssertNil(store.loadError)

        let backupAfter = try Data(contentsOf: FilePaths.inspectionsIndexBackup)
        XCTAssertEqual(backupBefore, backupAfter, "corrupt primary clobbered the good backup")
    }

    /// Both index files corrupt → rebuild from current.json files, and the
    /// rebuilt index is persisted (a fresh store loads it without rebuilding).
    func testBothIndexFilesCorruptRebuildsFromVersionFiles() throws {
        let a = makeVersion(client: "Alpha"), b = makeVersion(client: "Bravo")
        try writeCurrentJson(a); try writeCurrentJson(b)
        try writeGarbage(to: FilePaths.inspectionsIndex)
        try writeGarbage(to: FilePaths.inspectionsIndexBackup)

        let store = InspectionStore()
        XCTAssertNil(store.loadError)
        XCTAssertEqual(Set(store.metadataList.map(\.id)), Set([a.id, b.id]))

        let relaunched = InspectionStore()
        XCTAssertEqual(Set(relaunched.metadataList.map(\.id)), Set([a.id, b.id]),
                       "rebuilt index was not persisted")
    }

    /// Both index files corrupt AND no current.json → unrecoverable (gated);
    /// then creating a new inspection with OTHER survivors on disk must
    /// rebuild-then-merge and NEVER orphan the survivors.
    func testUnrecoverableThenCreateDoesNotOrphanSurvivors() throws {
        try writeGarbage(to: FilePaths.inspectionsIndex)
        try writeGarbage(to: FilePaths.inspectionsIndexBackup)

        let store = InspectionStore()
        XCTAssertNotNil(store.loadError, "expected an unrecoverable load error")
        XCTAssertTrue(store.metadataList.isEmpty)

        let s1 = makeVersion(client: "Survivor1"), s2 = makeVersion(client: "Survivor2")
        try writeCurrentJson(s1); try writeCurrentJson(s2)

        store.createNewInspection(clientName: "Fresh", clientEmail: "", clientPhone: "",
                                  propertyAddress: "x", inspectorName: "Insp", inspectorConfirmed: true)

        let ids = Set(store.metadataList.map(\.id))
        XCTAssertTrue(ids.contains(s1.id), "survivor 1 was orphaned by createNewInspection")
        XCTAssertTrue(ids.contains(s2.id), "survivor 2 was orphaned by createNewInspection")
        XCTAssertEqual(store.metadataList.count, 3, "expected 2 survivors + the new inspection")
    }

    /// A validly-empty index is NOT corruption: it loads clean, with no error,
    /// and writes are not gated.
    func testEmptyIndexIsNotTreatedAsCorruption() throws {
        try writeMetadataIndex([], to: FilePaths.inspectionsIndex)

        let store = InspectionStore()
        XCTAssertNil(store.loadError)
        XCTAssertTrue(store.metadataList.isEmpty)

        let v = makeVersion(client: "Persisted")
        store.insert(version: v)
        let relaunched = InspectionStore()
        XCTAssertTrue(relaunched.metadataList.map(\.id).contains(v.id),
                      "save was incorrectly gated for an empty index")
    }
}

/// B-0045 — the sensitive working store moved out of file-shared Documents into
/// Application Support, and the legacy exposed copy is deleted on launch.
@MainActor
final class LegacyStorageCleanupTests: XCTestCase {

    func testAppRootIsInApplicationSupportNotDocuments() {
        let appRoot = FilePaths.appRoot.standardizedFileURL
        let appSupport = FilePaths.applicationSupportDirectory.standardizedFileURL
        let docs = FilePaths.documentDirectory.standardizedFileURL
        XCTAssertEqual(appRoot.deletingLastPathComponent().path, appSupport.path,
                       "appRoot must live directly under Application Support")
        XCTAssertFalse(appRoot.path.hasPrefix(docs.path),
                       "appRoot must NOT be inside the file-shared Documents directory")
    }

    /// The cleanup must delete ONLY the two NexGenSpec-owned legacy paths and
    /// leave every unrelated file/folder in Documents untouched.
    func testCleanupDeletesOnlyNexGenSpecPathsAndLeavesOtherFilesUntouched() throws {
        let fm = FileManager.default
        let docs = FilePaths.documentDirectory

        // Legacy NexGenSpec-owned paths the cleanup SHOULD delete.
        let legacyStore = docs.appendingPathComponent("NexGenSpec", isDirectory: true)
        let legacyMarker = legacyStore.appendingPathComponent("marker.txt")
        let legacyLogo = docs.appendingPathComponent("company_logo.png")
        try fm.createDirectory(at: legacyStore, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: legacyMarker)
        try Data("x".utf8).write(to: legacyLogo)

        // Unrelated, NOT NexGenSpec-owned — MUST survive.
        let otherFile = docs.appendingPathComponent("UNRELATED-\(UUID().uuidString).txt")
        let otherFolder = docs.appendingPathComponent("OtherApp-\(UUID().uuidString)", isDirectory: true)
        let otherFolderFile = otherFolder.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: otherFile)
        try fm.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: otherFolderFile)
        defer {
            try? fm.removeItem(at: otherFile)
            try? fm.removeItem(at: otherFolder)
            try? fm.removeItem(at: legacyStore)
            try? fm.removeItem(at: legacyLogo)
        }

        FilePaths.cleanupLegacyExposedStore()

        XCTAssertFalse(fm.fileExists(atPath: legacyStore.path), "legacy store not deleted")
        XCTAssertFalse(fm.fileExists(atPath: legacyLogo.path), "legacy logo not deleted")
        XCTAssertTrue(fm.fileExists(atPath: otherFile.path), "cleanup deleted an unrelated file")
        XCTAssertTrue(fm.fileExists(atPath: otherFolderFile.path), "cleanup deleted an unrelated folder")
    }

    /// The Files-app mirror publishes the PDF only — never raw inspection data —
    /// and into Documents (the deliverables area), not the private app root.
    func testFilesAppPublisherPublishesPdfOnlyNoRawData() throws {
        let fm = FileManager.default
        let jobId = UUID()
        let inspection = Inspection(id: jobId, clientName: "Pub Test", clientEmail: "", clientPhone: "",
                                    propertyAddress: "500 Mirror St", inspectionDate: Date(),
                                    inspectorName: "Insp", sections: [])
        let version = InspectionVersion(id: jobId, versionNumber: 1, status: .draft,
                                        finalizedAt: nil, locked: false, inspection: inspection)

        let tmpPDF = fm.temporaryDirectory.appendingPathComponent("\(jobId).pdf")
        let pdfDoc = PDFDocument()
        pdfDoc.insert(PDFPage(), at: 0)
        XCTAssertTrue(pdfDoc.write(to: tmpPDF))
        defer { try? fm.removeItem(at: tmpPDF) }

        let folder = FilesAppPublisher.publish(version: version, pdfURL: tmpPDF)
        defer { if let folder { try? fm.removeItem(at: folder) } }

        let unwrapped = try XCTUnwrap(folder)
        XCTAssertTrue(unwrapped.path.contains("NexGenSpecReports"))
        XCTAssertTrue(unwrapped.standardizedFileURL.path.hasPrefix(FilePaths.documentDirectory.standardizedFileURL.path))
        XCTAssertTrue(fm.fileExists(atPath: unwrapped.appendingPathComponent("Inspection_Report.pdf").path),
                      "published PDF missing")
        XCTAssertFalse(fm.fileExists(atPath: unwrapped.appendingPathComponent("_data").path),
                       "raw _data was mirrored into the file-shared folder")
    }
}

/// B-0047 — encrypted backup uses a real PBKDF2 KDF, enforces a passphrase
/// minimum, and rejects legacy v1 backups. Isolated: stashes the real appRoot
/// aside so create/restore run against a clean store.
@MainActor
final class EncryptedBackupServiceTests: XCTestCase {

    private var stashDir: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        try FileSecurity.ensureProtectedDirectory(FilePaths.appRoot)
        stashDir = fm.temporaryDirectory.appendingPathComponent("ngs-b0047-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stashDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: FilePaths.appRoot.path) {
            try fm.moveItem(at: FilePaths.appRoot, to: stashDir.appendingPathComponent("appRoot"))
        }
        try FileSecurity.ensureProtectedDirectory(FilePaths.appRoot)
    }

    override func tearDownWithError() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: FilePaths.appRoot)
        let saved = stashDir.appendingPathComponent("appRoot")
        if fm.fileExists(atPath: saved.path) {
            try fm.moveItem(at: saved, to: FilePaths.appRoot)
        }
        try? fm.removeItem(at: stashDir)
        stashDir = nil
    }

    private func freshBackupURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).backup.enc")
    }

    func testRoundTripWithStrongPassphrase() throws {
        let marker = FilePaths.appRoot.appendingPathComponent("Inspections/x/current.json")
        try FileSecurity.ensureProtectedDirectory(marker.deletingLastPathComponent())
        let content = Data("round-trip-\(UUID().uuidString)".utf8)
        try FileSecurity.writeProtected(content, to: marker)

        let dest = freshBackupURL()
        defer { try? FileManager.default.removeItem(at: dest) }
        try EncryptedBackupService.createEncryptedBackup(passphrase: "correct horse battery staple", destinationURL: dest)

        try FileManager.default.removeItem(at: marker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        try EncryptedBackupService.restoreEncryptedBackup(passphrase: "correct horse battery staple", sourceURL: dest)
        XCTAssertEqual(try Data(contentsOf: marker), content, "round-trip restore did not reproduce the original file")
    }

    func testCreateRejectsShortPassphrase() {
        XCTAssertThrowsError(try EncryptedBackupService.createEncryptedBackup(passphrase: "short", destinationURL: freshBackupURL())) { error in
            guard case EncryptedBackupService.BackupError.passphraseTooShort = error else {
                return XCTFail("expected passphraseTooShort, got \(error)")
            }
        }
    }

    func testRestoreRejectsLegacyV1Backup() throws {
        // A v1 envelope: schemaVersion 1 and no kdf fields.
        let v1 = #"{"schemaVersion":1,"createdAt":0,"salt":"AA==","nonce":"AA==","cipherText":"AA==","tag":"AA=="}"#
        let dest = freshBackupURL()
        defer { try? FileManager.default.removeItem(at: dest) }
        try Data(v1.utf8).write(to: dest)
        XCTAssertThrowsError(try EncryptedBackupService.restoreEncryptedBackup(passphrase: "twelve chars ok", sourceURL: dest)) { error in
            guard case EncryptedBackupService.BackupError.unsupportedSchema = error else {
                return XCTFail("expected unsupportedSchema, got \(error)")
            }
        }
    }

    func testWrongPassphraseFailsToRestore() throws {
        let marker = FilePaths.appRoot.appendingPathComponent("Inspections/y/current.json")
        try FileSecurity.ensureProtectedDirectory(marker.deletingLastPathComponent())
        try FileSecurity.writeProtected(Data("secret".utf8), to: marker)
        let dest = freshBackupURL()
        defer { try? FileManager.default.removeItem(at: dest) }
        try EncryptedBackupService.createEncryptedBackup(passphrase: "passphrase-one-aaa", destinationURL: dest)
        // Wrong passphrase derives a different key → AES.GCM tag check fails.
        XCTAssertThrowsError(try EncryptedBackupService.restoreEncryptedBackup(passphrase: "passphrase-two-bbb", sourceURL: dest))
    }
}

/// T-01440 — persisted invoice amounts are swept on Account Deletion (the
/// `invoice.` prefix now covers price/services/total), but the
/// `deletion-pending-wipe` retry flag must survive.
final class InspectionFlagsClearAllTests: XCTestCase {
    func testClearAllSweepsInvoiceAmountsButKeepsDeletionPendingFlag() {
        let defaults = UserDefaults.standard
        let id = UUID().uuidString
        let invoiceKeys = ["invoice.sentAt.\(id)", "invoice.paidAt.\(id)",
                           "invoice.price.\(id)", "invoice.services.\(id)", "invoice.total.\(id)",
                           "inspection.archivedAt.\(id)"]
        invoiceKeys.forEach { defaults.set("x", forKey: $0) }
        defaults.set(true, forKey: "deletion-pending-wipe")
        defer { defaults.removeObject(forKey: "deletion-pending-wipe") }

        InspectionFlags.clearAll()

        for key in invoiceKeys {
            XCTAssertNil(defaults.object(forKey: key), "clearAll did not remove \(key)")
        }
        XCTAssertTrue(defaults.bool(forKey: "deletion-pending-wipe"),
                      "clearAll must not clear the deletion-pending-wipe retry flag")
    }
}

/// T-01439 — report-facing defect counts must exclude defects not flagged
/// includeInReport, so the header badges match the report body / per-section
/// counts instead of overstating them.
final class SummaryCountsTests: XCTestCase {
    func testSummaryCountsRespectsIncludeInReport() {
        func defect(_ sev: Severity, include: Bool) -> InspectionItem {
            InspectionItem(templateItemId: "t", title: "x", includeInReport: include,
                           status: .inspected, defectSeverity: sev)
        }
        let section = InspectionSection(id: UUID(), title: "S", items: [
            defect(.safety, include: true),
            defect(.major, include: true),
            defect(.minor, include: false),
        ])
        let inspection = Inspection(id: UUID(), clientName: "C", clientEmail: "", clientPhone: "",
                                    propertyAddress: "addr", inspectionDate: Date(), inspectorName: "I", sections: [section])

        let all = inspection.summaryCounts()
        XCTAssertEqual(all.safety, 1)
        XCTAssertEqual(all.major, 1)
        XCTAssertEqual(all.minor, 1)

        let report = inspection.summaryCounts(includeInReportOnly: true)
        XCTAssertEqual(report.safety, 1)
        XCTAssertEqual(report.major, 1)
        XCTAssertEqual(report.minor, 0, "a defect not flagged includeInReport must be excluded from report counts")
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

    /// Regression guard for B-0067 (free-tier watermark must reach the exported
    /// PDF) and B-0066 (a CIImage-backed custom logo whose pngData() returns nil
    /// must not crash report generation). Drives the SAME path production uses —
    /// renderHTML(watermark:) → low-level generatePDF(fromHTMLFile:) — not the
    /// preview overload. The diagonal "NEXGENSPEC FREE" mark is a CSS
    /// background-image (not extractable text), so the PDF assertion targets the
    /// upgrade BANNER (a flow element that survives pagination), and the HTML
    /// assertion guards the `wm` watermark class directly.
    @MainActor
    func testFreeWatermarkAndBannerInExportedPDF() async throws {
        // B-0066 failure mode: a CIImage-backed logo whose pngData() returns nil.
        let red = UIImage(ciImage: CIImage(color: CIColor(red: 0.85, green: 0.1, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 240, height: 240)))
        InspectorProfile.shared.companyName = "ACME VERIFY"
        InspectorProfile.shared.companyLogo = red
        // Reset the shared singleton even if an assertion/throw aborts the test,
        // so we don't leak ACME state into other tests in the suite.
        defer {
            InspectorProfile.shared.companyLogo = nil
            InspectorProfile.shared.companyName = ""
        }

        let inspection = Inspection(
            clientName: "Verify Client",
            clientEmail: "v@example.com",
            clientPhone: "",
            propertyAddress: "1 Verify Way",
            inspectionDate: Date(),
            inspectorName: "Verify Inspector",
            sections: [
                InspectionSection(title: "Roof", items: [
                    InspectionItem(
                        templateItemId: "r1",
                        title: "Flashing",
                        includeInReport: true,
                        status: .inspected,
                        defectSeverity: .major,
                        location: "Roof edge",
                        observed: "Flashing is loose.",
                        implication: "Water intrusion is possible.",
                        recommendation: "Repair flashing."
                    )
                ])
            ]
        )
        let version = InspectionVersion(versionNumber: 1, status: .draft, locked: false, inspection: inspection)

        // HTML-level guard for the actual watermark mechanism: the free render
        // carries the `wm` body class + upgrade banner; the Pro render is clean.
        let freeHTML = HTMLReportRenderer.renderHTML(for: version, watermark: true)
        let proHTML = HTMLReportRenderer.renderHTML(for: version, watermark: false)
        XCTAssertTrue(freeHTML.contains("class=\"wm\""), "Free HTML must tag body with the watermark class")
        XCTAssertTrue(freeHTML.contains("Upgrade to Pro"), "Free HTML must carry the upgrade banner")
        XCTAssertFalse(proHTML.contains("class=\"wm\""), "Pro HTML must not be watermarked")
        XCTAssertFalse(proHTML.contains("Upgrade to Pro"), "Pro HTML must not carry the banner")

        // End-to-end guard via the production low-level path: the banner is real,
        // extractable text, so it must be present in the free PDF and absent in Pro.
        func exportPDF(watermark: Bool, label: String) async throws -> String {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ngs-wm-\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let html = HTMLReportRenderer.renderHTML(
                for: version, imageFolderURL: dir.appendingPathComponent("images"),
                videosFolderURL: nil, watermark: watermark)
            let htmlURL = dir.appendingPathComponent("index.html")
            try Data(html.utf8).write(to: htmlURL)
            let pdfURL = try await PDFReportRenderer.generatePDF(
                fromHTMLFile: htmlURL, baseURL: dir, clientName: label)
            return PDFDocument(url: pdfURL)?.string ?? ""
        }
        let freeText = try await exportPDF(watermark: true, label: "free")
        let proText = try await exportPDF(watermark: false, label: "pro")
        XCTAssertTrue(freeText.contains("Upgrade to Pro"), "Free PDF must carry the upgrade banner")
        XCTAssertFalse(proText.contains("Upgrade to Pro"), "Pro PDF must be clean")
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

// MARK: - Monetization gate (B-0065)

/// B-0065: `hasFeatureAccess` is a pure ENTITLEMENT check — it gates premium
/// output (clean/unwatermarked branded PDFs). It must NOT be unlocked by the
/// free-trial counter. The old `|| freeInspectionsUsed <= freeInspectionLimit`
/// clause made it unconditionally true (the counter is capped 0...limit), so
/// free users received clean branded PDFs forever.
///
/// On the simulator/TestFlight test host `isBetaOrSandboxBuild` is true and
/// short-circuits `hasFeatureAccess` to true regardless of trial state — the
/// same masking documented in `DeviceCheckTrialGateTests`. So we branch on the
/// build: the production branch proves the trial counter no longer grants
/// access, and both branches prove an entitled (isPro) user is always unlocked.
@MainActor
final class SubscriptionMonetizationGateTests: XCTestCase {

    private func makeManager(trialUsed: Int) -> SubscriptionManager {
        UserDefaults.standard.set(trialUsed, forKey: "nexgenspec.trial.inspectionsCreated")
        // Re-init so the counter is read fresh from UserDefaults.
        return SubscriptionManager()
    }

    /// A fresh free user (counter == 0) and an exhausted free user
    /// (counter == limit) must BOTH be denied premium feature access in a
    /// production build — neither value may unlock clean branded output.
    func testFreeUsersDoNotGetPremiumFeatureAccess() {
        defer { UserDefaults.standard.removeObject(forKey: "nexgenspec.trial.inspectionsCreated") }

        let fresh = makeManager(trialUsed: 0)
        XCTAssertEqual(fresh.freeInspectionsUsed, 0, "Test setup: counter should be 0")

        let exhausted = makeManager(trialUsed: SubscriptionManager.freeInspectionLimit)
        XCTAssertEqual(exhausted.freeInspectionsUsed, SubscriptionManager.freeInspectionLimit,
                       "Test setup: counter should be at the free limit")

        XCTAssertFalse(fresh.isPro)
        XCTAssertFalse(fresh.isAdminAccount)
        XCTAssertFalse(exhausted.isPro)
        XCTAssertFalse(exhausted.isAdminAccount)

        if SubscriptionManager.isBetaOrSandboxBuild {
            // Sandbox/TestFlight host: the beta unlock dominates, so both
            // report true. The trial-counter regression isn't observable
            // here — the production branch below is what guards B-0065.
            XCTAssertTrue(fresh.hasFeatureAccess,
                          "Sandbox builds always unlock — entitlement gate is bypassed here")
            XCTAssertTrue(exhausted.hasFeatureAccess,
                          "Sandbox builds always unlock — entitlement gate is bypassed here")
        } else {
            XCTAssertFalse(fresh.hasFeatureAccess,
                           "Fresh free user must NOT have premium access (B-0065)")
            XCTAssertFalse(exhausted.hasFeatureAccess,
                           "Exhausted free user must NOT have premium access (B-0065)")
        }
    }

    /// An entitled (isPro) user must always have premium feature access,
    /// regardless of build environment. `isPro` is seeded through the offline
    /// grace cache that `SubscriptionManager.init()` restores on launch.
    func testEntitledUserHasPremiumFeatureAccess() {
        UserDefaults.standard.set(0, forKey: "nexgenspec.trial.inspectionsCreated")
        UserDefaults.standard.set(true, forKey: "nexgenspec.entitlement.isPro")
        UserDefaults.standard.set(Date(), forKey: "nexgenspec.entitlement.lastVerifiedDate")
        defer {
            UserDefaults.standard.removeObject(forKey: "nexgenspec.trial.inspectionsCreated")
            UserDefaults.standard.removeObject(forKey: "nexgenspec.entitlement.isPro")
            UserDefaults.standard.removeObject(forKey: "nexgenspec.entitlement.lastVerifiedDate")
        }

        let manager = SubscriptionManager()
        XCTAssertTrue(manager.isPro,
                      "Test setup: cached entitlement within grace must restore isPro == true")
        XCTAssertTrue(manager.hasFeatureAccess,
                      "Entitled (isPro) user must always have premium feature access")
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

    func testClearAllLocalDataRemovesAppRootEntirely() async throws {
        let store = InspectionStore()
        let jobId = UUID()
        try FilePaths.ensureAppStructure(jobId: jobId)
        // Plant a file deep inside appRoot to prove recursive removal works.
        let evidence = FilePaths.photosFolder(jobId: jobId)
            .appendingPathComponent("evidence.txt")
        try FileSecurity.writeProtected(Data("evidence".utf8), to: evidence)
        XCTAssertTrue(FileManager.default.fileExists(atPath: FilePaths.appRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.path))

        await store.clearAllLocalData()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: FilePaths.appRoot.path),
            "appRoot must NOT exist after clearAllLocalData — Bug B regression"
        )
        XCTAssertEqual(store.metadataList.count, 0)
    }

    func testClearAllLocalDataIsIdempotent() async {
        // Calling twice in succession must not throw; the second call is a
        // no-op since appRoot is already gone.
        let store = InspectionStore()
        await store.clearAllLocalData()
        await store.clearAllLocalData()
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

        let zipURL = try await InspectionZIPExportService.exportZIP(for: version, watermark: false)
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

/// T-01437 — backup restore must reject path-traversal / absolute / unsafe
/// stored paths so a crafted backup can't overwrite files outside appRoot.
final class BackupPathValidationTests: XCTestCase {
    func testSafeRestoreTargetAcceptsInsidePathsAndRejectsUnsafeOnes() {
        // Safe relative paths resolve to a descendant of appRoot.
        XCTAssertNotNil(EncryptedBackupService.safeRestoreTarget(forRelativePath: "Inspections/abc/current.json"))
        XCTAssertNotNil(EncryptedBackupService.safeRestoreTarget(forRelativePath: "inspections.json"))

        // Unsafe paths are rejected.
        for bad in ["../evil.txt", "../../etc/passwd", "ok/../../escape", "/etc/passwd", "", "a\u{0}b"] {
            XCTAssertNil(EncryptedBackupService.safeRestoreTarget(forRelativePath: bad),
                         "expected unsafe path to be rejected: \(bad)")
        }
    }
}

/// T-01441 — photos are downscaled before encode/save so a 48MP image isn't
/// PNG-encoded full-res on the main thread (watchdog + OOM). Tests the shared
/// downscale helper the save path uses.
final class ImageDownscaleTests: XCTestCase {
    func testResizedKeepingAspectCapsLongestSideAndPreservesSmallImages() {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }
        let small = big.resizedKeepingAspect(maxSide: 1000)
        XCTAssertLessThanOrEqual(max(small.size.width, small.size.height), 1000,
                                 "longest side must be capped at maxSide")
        XCTAssertGreaterThan(small.size.width, 0)
        // Aspect ratio preserved (4:3 → width is the long side).
        XCTAssertEqual(small.size.width / small.size.height, 4.0 / 3.0, accuracy: 0.05)
        // An already-small image is returned unchanged.
        let unchanged = small.resizedKeepingAspect(maxSide: 5000)
        XCTAssertEqual(unchanged.size, small.size)
    }
}

/// T-01438 — the v3 streaming backup round-trips multiple files (incl. a large
/// one) so the per-file framing read/write is correct. Isolated appRoot.
@MainActor
final class BackupStreamingRoundTripTests: XCTestCase {
    private var stashDir: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        try FileSecurity.ensureProtectedDirectory(FilePaths.appRoot)
        stashDir = fm.temporaryDirectory.appendingPathComponent("ngs-t01438-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stashDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: FilePaths.appRoot.path) {
            try fm.moveItem(at: FilePaths.appRoot, to: stashDir.appendingPathComponent("appRoot"))
        }
        try FileSecurity.ensureProtectedDirectory(FilePaths.appRoot)
    }

    override func tearDownWithError() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: FilePaths.appRoot)
        let saved = stashDir.appendingPathComponent("appRoot")
        if fm.fileExists(atPath: saved.path) { try fm.moveItem(at: saved, to: FilePaths.appRoot) }
        try? fm.removeItem(at: stashDir)
        stashDir = nil
    }

    func testStreamingRoundTripRestoresAllFilesIncludingLarge() throws {
        let fm = FileManager.default
        var expected: [String: Data] = [:]
        func put(_ rel: String, _ data: Data) throws {
            let url = FilePaths.appRoot.appendingPathComponent(rel)
            try FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
            try FileSecurity.writeProtected(data, to: url)
            expected[rel] = data
        }
        try put("inspections.json", Data("index".utf8))
        try put("Inspections/a/current.json", Data("alpha-\(UUID().uuidString)".utf8))
        try put("Inspections/b/current.json", Data("bravo-\(UUID().uuidString)".utf8))
        try put("Inspections/a/photos/big.jpg", Data((0..<2_000_000).map { UInt8($0 & 0xFF) }))

        let pass = "twelve-char-pass!"
        let dest = fm.temporaryDirectory.appendingPathComponent("stream-\(UUID().uuidString).backup.enc")
        defer { try? fm.removeItem(at: dest) }
        try EncryptedBackupService.createEncryptedBackup(passphrase: pass, destinationURL: dest)

        // Wipe the store, then restore from the streamed backup.
        try fm.removeItem(at: FilePaths.appRoot)
        try FileSecurity.ensureProtectedDirectory(FilePaths.appRoot)
        try EncryptedBackupService.restoreEncryptedBackup(passphrase: pass, sourceURL: dest)

        for (rel, data) in expected {
            let url = FilePaths.appRoot.appendingPathComponent(rel)
            XCTAssertEqual(try? Data(contentsOf: url), data, "restored file mismatch: \(rel)")
        }
    }
}

/// T-01445 / T-01447 — Account Deletion sweeps the recovery-email PII and the
/// Documents deliverable folders that live outside appRoot.
final class DeletionPIICompletenessTests: XCTestCase {
    func testClearAllSweepsFallbackEmailPrefixButKeepsDeletionPendingFlag() {
        let defaults = UserDefaults.standard
        let key = "ngs.fallbackEmail.\(UUID().uuidString)"
        defaults.set("secret@example.com", forKey: key)
        defaults.set(true, forKey: "deletion-pending-wipe")
        defer { defaults.removeObject(forKey: "deletion-pending-wipe") }

        InspectionFlags.clearAll()

        XCTAssertNil(defaults.object(forKey: key), "fallback recovery email (PII) was not cleared")
        XCTAssertTrue(defaults.bool(forKey: "deletion-pending-wipe"),
                      "clearAll must not clear the deletion-pending-wipe retry flag")
    }

    func testRemoveAllExportsDeletesTheExportsFolder() throws {
        let fm = FileManager.default
        let marker = InspectionZIPExportService.exportFolder.appendingPathComponent("test-\(UUID().uuidString).zip")
        try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("zip".utf8).write(to: marker)
        XCTAssertTrue(fm.fileExists(atPath: marker.path))

        InspectionZIPExportService.removeAllExports()

        XCTAssertFalse(fm.fileExists(atPath: InspectionZIPExportService.exportFolder.path),
                       "exports folder (client-PII ZIPs) was not removed on deletion")
    }
}

/// T-01449 — invoice decimal filter keeps the locale decimal separator (no 100x
/// billing bug) and strips the thousands separator, in both comma- and
/// dot-decimal locales.
final class FilterDecimalLocaleTests: XCTestCase {
    func testFilterDecimalRespectsLocaleSeparator() {
        // Comma-decimal locale: "," is the decimal, "." is thousands.
        XCTAssertEqual(filterDecimal("49,50", decimalSeparator: ","), "49,50",
                       "comma decimal must be preserved — not stripped to 4950")
        XCTAssertEqual(filterDecimal("1.000,50", decimalSeparator: ","), "1000,50")
        // Dot-decimal locale: "." is the decimal, "," is thousands.
        XCTAssertEqual(filterDecimal("49.50", decimalSeparator: "."), "49.50")
        XCTAssertEqual(filterDecimal("1,000.50", decimalSeparator: "."), "1000.50")
        // Only the first decimal separator is kept.
        XCTAssertEqual(filterDecimal("12.34.56", decimalSeparator: "."), "12.3456")
        // Stray letters dropped.
        XCTAssertEqual(filterDecimal("abc12.5x", decimalSeparator: "."), "12.5")
    }
}
