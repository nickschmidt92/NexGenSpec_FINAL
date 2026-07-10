//
//  NexGenSpecTests.swift
//  NexGenSpec
//

import XCTest
import PDFKit
import UIKit
import Combine
import CoreImage
import Security
@testable import NexGenSpec

final class FilePathsTests: XCTestCase {

    func testDocumentDirectoryExists() {
        let url = FilePaths.documentDirectory
        XCTAssertFalse(url.path.isEmpty)
        XCTAssertTrue(url.isFileURL)
    }

    func testAppRootIsNamespacedUnderUsersContainer() {
        // B-0096: appRoot is now per-user — …/NexGenSpec/Users/<segment> — so it
        // no longer ends in "NexGenSpec". It must still live under the private
        // NexGenSpec tree and sit directly inside the `Users` container.
        let url = FilePaths.appRoot
        XCTAssertTrue(url.path.contains("NexGenSpec"))
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Users")
        XCTAssertEqual(url.deletingLastPathComponent(), FilePaths.usersContainer)
        XCTAssertTrue(FilePaths.usersContainer.path.hasPrefix(FilePaths.legacySharedRoot.path))
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

    // MARK: - I-E legacy integrity-hash self-heal (FinalizationService.legacyHealedVersion)

    private func ieFinalizedVersion(updatedAt: Date?) -> InspectionVersion {
        let id = UUID()
        let inspection = Inspection(
            id: id, clientName: "Legacy Client", clientEmail: "", clientPhone: "",
            propertyAddress: "1 Heal St", inspectionDate: Date(timeIntervalSince1970: 500),
            inspectorName: "Inspector", sections: []
        )
        var v = InspectionVersion(
            id: id, versionNumber: 1, status: .final,
            finalizedAt: Date(timeIntervalSince1970: 500), locked: true, inspection: inspection
        )
        v.updatedAt = updatedAt
        return v
    }

    func testLegacyHealRestoresUpdatedAtWhenOnlyDrift() throws {
        let sealedAt = Date(timeIntervalSince1970: 1_000)
        let sealedModel = ieFinalizedVersion(updatedAt: sealedAt)
        let sealedHash = try FinalizationService.canonicalHash(sealedModel)
        let sealed = FinalizedVersionSnapshot(version: sealedModel, reportHash: sealedHash, finalizedAt: sealedAt)

        // Legacy drift: identical content, only updatedAt re-stamped to finalize-time.
        var drifted = sealedModel
        drifted.updatedAt = Date(timeIntervalSince1970: 2_000)

        let healed = try XCTUnwrap(FinalizationService.legacyHealedVersion(drifted, against: sealed))
        XCTAssertEqual(healed.updatedAt, sealedAt, "updatedAt is restored to the sealed value")
        XCTAssertEqual(try FinalizationService.canonicalHash(healed), sealedHash,
                       "the healed model matches the ORIGINAL seal, so verify() will pass")
    }

    func testLegacyHealRefusesWhenContentDiffersBeyondUpdatedAt() throws {
        let sealedAt = Date(timeIntervalSince1970: 1_000)
        let sealedModel = ieFinalizedVersion(updatedAt: sealedAt)
        let sealed = FinalizedVersionSnapshot(
            version: sealedModel, reportHash: try FinalizationService.canonicalHash(sealedModel), finalizedAt: sealedAt
        )

        // Genuine divergence: a hash-covered content field differs (not just updatedAt).
        var tampered = sealedModel
        tampered.updatedAt = Date(timeIntervalSince1970: 2_000)
        tampered.finalizedAt = Date(timeIntervalSince1970: 9_999)

        XCTAssertNil(FinalizationService.legacyHealedVersion(tampered, against: sealed),
                     "content tampering is NEVER masked — heal refuses unless ONLY updatedAt drifted")
    }

    // MARK: - Build-26 branding snapshot must not break pre-26 finalized hashes (audit F1)

    private func brandingFinalizedVersion(companyName: String = "", licenseNumber: String = "",
                                          companyPhone: String = "", companyEmail: String = "") -> InspectionVersion {
        let id = UUID()
        var inspection = Inspection(
            id: id, clientName: "Brand Client", clientEmail: "", clientPhone: "",
            propertyAddress: "1 Brand St", inspectionDate: Date(timeIntervalSince1970: 500),
            inspectorName: "Inspector", sections: []
        )
        inspection.companyName = companyName
        inspection.licenseNumber = licenseNumber
        inspection.companyPhone = companyPhone
        inspection.companyEmail = companyEmail
        return InspectionVersion(
            id: id, versionNumber: 1, status: .final,
            finalizedAt: Date(timeIntervalSince1970: 500), locked: true, inspection: inspection
        )
    }

    /// A report finalized under build <= 25 sealed its integrity hash over canonical
    /// JSON that contained NO branding keys. Build 26 added four branding strings; if
    /// they were encoded even when empty, the sorted-key canonical JSON would differ
    /// and verify() would FALSE-positive an INTEGRITY CHECK FAILED on a legitimate,
    /// untouched report. Guard: empty branding must be OMITTED from the encoding so it
    /// stays byte-identical to pre-26 and the old sealed hash keeps verifying.
    func testEmptyBrandingIsOmittedFromCanonicalEncoding() throws {
        let version = brandingFinalizedVersion()  // all branding empty
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(version), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"companyName\""), "empty branding must be omitted (byte-identity with pre-26 seal)")
        XCTAssertFalse(json.contains("\"licenseNumber\""))
        XCTAssertFalse(json.contains("\"companyPhone\""))
        XCTAssertFalse(json.contains("\"companyEmail\""))
        XCTAssertFalse(json.contains("\"companyLogoBase64\""), "nil logo must be omitted")
    }

    /// Populated branding IS sealed into the canonical form and hashes deterministically
    /// (sorted keys; every device encodes the same frozen model bytes).
    func testPopulatedBrandingIsSealedAndDeterministic() throws {
        let version = brandingFinalizedVersion(companyName: "Acme Inspections", licenseNumber: "LIC-123",
                                               companyPhone: "555-0100", companyEmail: "ops@acme.test")
        XCTAssertEqual(try FinalizationService.canonicalHash(version),
                       try FinalizationService.canonicalHash(version),
                       "populated branding hashes deterministically")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(version), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("Acme Inspections"), "populated branding is sealed into the canonical form")
        XCTAssertTrue(json.contains("LIC-123"))
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

/// Build 22 — P6 remediation: the InspectionStore-side fixes (D immutability
/// belt-and-suspenders, E integrity-snapshot recompute on a finalized apply, I no
/// re-stamp of a locked version, and B's writer cross-account guard). Coupled to
/// the real on-disk store, so `setUp` stashes any existing store aside for a clean
/// deterministic `appRoot` and `tearDown` restores it (mirrors
/// InspectionIndexRecoveryTests).
@MainActor
final class Build22RemediationTests: XCTestCase {

    private var stashDir: URL!
    private var inspectionsDir: URL { FilePaths.appRoot.appendingPathComponent("Inspections", isDirectory: true) }

    override func setUpWithError() throws {
        let fm = FileManager.default
        try FileSecurity.ensureProtectedDirectory(FilePaths.appRoot)
        stashDir = fm.temporaryDirectory.appendingPathComponent("ngs-b22rem-\(UUID().uuidString)", isDirectory: true)
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

    private func makeFinalized(id: UUID, updatedAt: Date) -> InspectionVersion {
        let inspection = Inspection(id: id, clientName: "Final Client", clientEmail: "", clientPhone: "",
                                    propertyAddress: "1 Seal St", inspectionDate: Date(), inspectorName: "Insp", sections: [])
        var v = InspectionVersion(id: id, versionNumber: 1, status: .final, finalizedAt: updatedAt, locked: true, inspection: inspection)
        v.updatedAt = updatedAt
        return v
    }

    // MARK: - Fix I: a locked version's updatedAt is never re-stamped on write

    func testFinalizedVersionWriteDoesNotRestampUpdatedAt() throws {
        let store = InspectionStore()
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        store.insert(version: makeFinalized(id: id, updatedAt: t1))   // local write of a LOCKED version
        let onDisk = try XCTUnwrap(store.loadFullVersion(id: id))
        XCTAssertEqual(onDisk.updatedAt, t1,
                       "fix I: a locked version's updatedAt must NOT be re-stamped on write (it must match the sealed snapshot)")
    }

    // MARK: - Fix E: applying a finalized remote recomputes the integrity snapshot

    func testApplyingFinalizedRemoteRecomputesIntegritySnapshotByteIdentical() throws {
        let store = InspectionStore()
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let v = makeFinalized(id: id, updatedAt: t1)
        let jobId = UUID(uuidString: v.inspection.inspectionId) ?? v.id

        // The ORIGIN device's sealed hash, over its in-memory model.
        let originHash = try FinalizationService.writeSnapshot(v)
        // Simulate device B: only current.json syncs — the snapshot is NOT present.
        try? FileManager.default.removeItem(at: FilePaths.versionSnapshotFile(jobId: jobId, versionId: id))
        XCTAssertNil(FinalizationService.loadReportHash(jobId: jobId, versionId: id),
                     "precondition: device B starts without the integrity snapshot")

        // Mimic the REAL pull path: the version arrives as JSON payload BYTES and is
        // decoded before apply (InspectionStoreVersionWriter decodes payload Data).
        // Round-trip through encode/decode so any Date-precision / optional-field loss
        // that would break cross-device byte-identity is caught (#8), not bypassed by
        // reusing the in-memory object.
        let payload = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(InspectionVersion.self, from: payload)
        XCTAssertTrue(store.applyRemoteVersion(decoded), "a finalized remote version applies")

        let recomputed = FinalizationService.loadReportHash(jobId: jobId, versionId: id)
        XCTAssertNotNil(recomputed, "fix E: applying a finalized version must recompute the integrity snapshot locally")
        XCTAssertEqual(recomputed, originHash, "the recomputed hash (over the decoded synced payload) must be byte-identical to the origin's")
    }

    // MARK: - Fix D: in-memory immutability belt-and-suspenders

    func testApplyRemoteRefusesToOverwriteLockedLocalWithDraft() throws {
        let store = InspectionStore()
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)

        // Local device holds a FINALIZED version for this id.
        XCTAssertTrue(store.applyRemoteVersion(makeFinalized(id: id, updatedAt: t1)))
        XCTAssertEqual(store.loadFullVersion(id: id)?.locked, true)

        // A NON-finalized remote arrives for the SAME id (e.g. an undecodable
        // localState upstream, or a resurrected draft). It must be REFUSED.
        var draft = makeFinalized(id: id, updatedAt: t1)
        draft.status = .draft
        draft.locked = false
        draft.finalizedAt = nil
        draft.updatedAt = Date()   // "newer" — must still not win over a locked local
        XCTAssertTrue(store.applyRemoteVersion(draft),
                      "a refused immutable overwrite is a deliberate keep-local (true), not a retry")

        let onDisk = try XCTUnwrap(store.loadFullVersion(id: id))
        XCTAssertEqual(onDisk.locked, true, "fix D: a locked local version must not be overwritten by a non-finalized remote")
        XCTAssertEqual(onDisk.status, .final)
        XCTAssertEqual(store.metadataList.first(where: { $0.id == id })?.locked, true)
    }

    // MARK: - Fix D: real DiskVersionReader.localState fails closed on undecodable JSON

    func testLocalStateFailsClosedOnUndecodableCurrentJson() throws {
        let id = UUID()
        let url = FilePaths.currentVersionFile(jobId: id)
        try FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
        try FileSecurity.writeProtected(Data("}{ not valid json".utf8), to: url)   // present but undecodable

        let state = DiskVersionReader().localState(forVersionId: id)
        XCTAssertTrue(state.exists, "an existing-but-undecodable current.json must report exists:true")
        XCTAssertTrue(state.isFinalized, "fix D: fail CLOSED — treat undecodable as finalized so it is never overwritten")
        // And the resolver maps that fail-closed state to keepLocal for BOTH paths.
        XCTAssertEqual(SyncConflictResolver.resolveUpsert(local: state, remoteLocked: false, remoteUpdatedAt: Date()), .keepLocal,
                       "undecodable local must keepLocal against a remote upsert")
        XCTAssertEqual(SyncConflictResolver.resolveDelete(local: state), .keepLocal,
                       "undecodable local must keepLocal against a remote tombstone")
    }

    // MARK: - Fix B: the writer refuses to apply across an account switch

    func testWriterRefusesCrossAccountApply() async throws {
        let store = InspectionStore()
        let boundUID = "fixB-bound-\(UUID().uuidString)"
        let otherUID = "fixB-other-\(UUID().uuidString)"
        let writer = InspectionStoreVersionWriter(store: store, boundUID: boundUID)
        let savedProvider = SessionScope.uidProvider
        defer { SessionScope.uidProvider = savedProvider }
        SessionScope.uidProvider = { otherUID }   // live active user != bound UID

        let id = UUID()
        let inspection = Inspection(id: id, clientName: "X", clientEmail: "", clientPhone: "",
                                    propertyAddress: "addr", inspectionDate: Date(), inspectorName: "I", sections: [])
        let v = InspectionVersion(id: id, versionNumber: 1, status: .draft, finalizedAt: nil, locked: false, inspection: inspection)
        let before = store.metadataList.count

        let result = await writer.applyRemoteVersion(try JSONEncoder().encode(v))
        XCTAssertFalse(result, "a refused cross-account apply returns FALSE so pull() HOLDS the change token for retry (round-2 fix) — true would advance it past the bound account's own record and lose it")
        XCTAssertEqual(store.metadataList.count, before, "fix B: a cross-account apply must not modify the store")
        XCTAssertFalse(store.metadataList.contains { $0.id == id }, "the cross-account version must not be inserted")
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
        // B-0096 nests appRoot one extra level deep (…/NexGenSpec/Users/<uid>),
        // so it is no longer a DIRECT child of Application Support — but the
        // security intent is unchanged: it must live somewhere under the private
        // Application Support tree and never under the file-shared Documents dir.
        XCTAssertTrue(appRoot.path.hasPrefix(appSupport.path + "/"),
                      "appRoot must live under the private Application Support tree")
        XCTAssertEqual(FilePaths.legacySharedRoot.standardizedFileURL.deletingLastPathComponent().path,
                       appSupport.path,
                       "the NexGenSpec store root must sit directly under Application Support")
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

    /// The report mirror publishes the PDF only — never raw inspection data —
    /// into the per-UID private store under `appRoot`, NEVER the file-shared
    /// Documents directory (the cross-account PII leak this closes).
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
        XCTAssertTrue(unwrapped.standardizedFileURL.path.hasPrefix(FilePaths.appRoot.standardizedFileURL.path),
                      "published report must live under the private per-UID appRoot")
        XCTAssertFalse(unwrapped.standardizedFileURL.path.hasPrefix(FilePaths.documentDirectory.standardizedFileURL.path),
                       "published report must NOT be in the file-shared Documents directory")
        XCTAssertEqual(unwrapped.deletingLastPathComponent().lastPathComponent, "Reports")
        XCTAssertTrue(fm.fileExists(atPath: unwrapped.appendingPathComponent("Inspection_Report.pdf").path),
                      "published PDF missing")
        XCTAssertFalse(fm.fileExists(atPath: unwrapped.appendingPathComponent("_data").path),
                       "raw _data was mirrored into the published folder")
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

    /// 5.1.1(v): the inspector-profile PII keys (name/company/license/phone/email)
    /// must be swept by clearAll() so the force-quit account-deletion recovery
    /// wipe (NexGenSpecApp recovery branch → performDiskWipe → clearAll) is
    /// self-contained and can't leave a deleted user's identity behind for the
    /// next inspector. (B-0086)
    func testClearAllSweepsInspectorProfilePII() {
        let defaults = UserDefaults.standard
        let profileKeys = [
            "nexgenspec.profile.inspectorName",
            "nexgenspec.profile.companyName",
            "nexgenspec.profile.licenseNumber",
            "nexgenspec.profile.phone",
            "nexgenspec.profile.email",
        ]
        profileKeys.forEach { defaults.set("prev-user-PII", forKey: $0) }

        InspectionFlags.clearAll()

        for key in profileKeys {
            XCTAssertNil(defaults.object(forKey: key),
                         "clearAll must sweep inspector-profile PII key \(key) (5.1.1(v))")
        }
    }

    /// Per-UID scoping (audit follow-up): an account's invoice/archived soft flags
    /// must be ISOLATED from another account's on a shared device, and PRESERVED
    /// for the owning account across an account switch (logout/login). Flag keys
    /// are namespaced by `SessionScope.currentSegment`, overridden here via the
    /// `uidProvider` test hook.
    func testInvoiceAndArchivedFlagsAreScopedPerUID() {
        let job = "job-scope-\(UUID().uuidString)"
        let savedProvider = SessionScope.uidProvider
        defer {
            for uid in ["flagscope-A", "flagscope-B"] {
                SessionScope.uidProvider = { uid }
                InspectionFlags.setArchived(false, inspectionId: job)
            }
            SessionScope.uidProvider = savedProvider
        }

        // Account A sets an archived flag.
        SessionScope.uidProvider = { "flagscope-A" }
        InspectionFlags.setArchived(true, inspectionId: job)
        XCTAssertTrue(InspectionFlags.isArchived(inspectionId: job), "A's own flag should read back")

        // Account B on the SAME device must NOT see A's flag.
        SessionScope.uidProvider = { "flagscope-B" }
        XCTAssertFalse(InspectionFlags.isArchived(inspectionId: job),
                       "account B must not see account A's archived flag (cross-account leak)")

        // Back to A — the flag must still be there (logout/login preserves it).
        SessionScope.uidProvider = { "flagscope-A" }
        XCTAssertTrue(InspectionFlags.isArchived(inspectionId: job),
                      "account A's flag must persist across an account switch")
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
        // This version is a DRAFT, so both renders also carry the `draft` body
        // class — a tiled background marker that paginates across every PDF page
        // (the old position:fixed .draft-watermark div only landed on page 1).
        let freeHTML = HTMLReportRenderer.renderHTML(for: version, watermark: true)
        let proHTML = HTMLReportRenderer.renderHTML(for: version, watermark: false)
        XCTAssertTrue(freeHTML.contains("class=\"wm draft\""), "Free DRAFT HTML body must carry both the watermark (wm) and paginating draft classes")
        XCTAssertTrue(freeHTML.contains("Upgrade to Pro"), "Free HTML must carry the upgrade banner")
        XCTAssertFalse(proHTML.contains("class=\"wm"), "Pro HTML must not be watermarked")
        XCTAssertTrue(proHTML.contains("class=\"draft\""), "Pro DRAFT HTML body must carry the paginating draft class")
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
                fromHTMLFile: htmlURL, baseURL: dir, outputBaseName: label)
            return PDFDocument(url: pdfURL)?.string ?? ""
        }
        let freeText = try await exportPDF(watermark: true, label: "free")
        let proText = try await exportPDF(watermark: false, label: "pro")
        XCTAssertTrue(freeText.contains("Upgrade to Pro"), "Free PDF must carry the upgrade banner")
        XCTAssertFalse(proText.contains("Upgrade to Pro"), "Pro PDF must be clean")
    }

    /// Regression guard for PDF pagination (B-0070): a multi-section report must
    /// paginate into multiple US-Letter (612x792) pages via UIPrintPageRenderer —
    /// NOT a single content-tall page like WKWebView.pdf() produced — and the free
    /// watermark banner must survive the print path. Drives the production low-level path.
    @MainActor
    func testReportPaginatesIntoMultipleLetterPages() async throws {
        InspectorProfile.shared.companyName = "ACME VERIFY"
        defer { InspectorProfile.shared.companyName = "" }
        var sections: [InspectionSection] = []
        for s in 0..<6 {
            var items: [InspectionItem] = []
            for i in 0..<3 {
                items.append(InspectionItem(
                    templateItemId: "s\(s)i\(i)", title: "Item \(s)-\(i)",
                    includeInReport: true, status: .inspected, defectSeverity: .major,
                    location: "Location \(s)-\(i)",
                    observed: "Observed condition \(s)-\(i): wear and deterioration noted across the component, requiring attention from a qualified professional during the inspection walkthrough.",
                    implication: "If left unaddressed this may lead to water intrusion, structural concerns, or safety hazards over time.",
                    recommendation: "Recommend evaluation and repair by a licensed contractor prior to close of the transaction."))
            }
            sections.append(InspectionSection(title: "Section \(s)", items: items))
        }
        let inspection = Inspection(
            clientName: "Pagination Client", clientEmail: "v@example.com", clientPhone: "",
            propertyAddress: "1 Pagination Way", inspectionDate: Date(),
            inspectorName: "PG Inspector", sections: sections)
        let version = InspectionVersion(versionNumber: 1, status: .draft, locked: false, inspection: inspection)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ngs-pg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let html = HTMLReportRenderer.renderHTML(for: version, imageFolderURL: dir.appendingPathComponent("images"), videosFolderURL: nil, watermark: true)
        let htmlURL = dir.appendingPathComponent("index.html")
        try Data(html.utf8).write(to: htmlURL)
        let pdfURL = try await PDFReportRenderer.generatePDF(fromHTMLFile: htmlURL, baseURL: dir, outputBaseName: "Pagination")
        let doc = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertGreaterThan(doc.pageCount, 1, "multi-section report must paginate into multiple pages, not one tall page")
        let bounds = try XCTUnwrap(doc.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 612, accuracy: 1, "pages should be US Letter width")
        XCTAssertEqual(bounds.height, 792, accuracy: 1, "pages should be US Letter height")
        XCTAssertTrue((doc.string ?? "").contains("Upgrade to Pro"), "free watermark banner must survive the print path")
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

    /// Deletes the Keychain entitlement-cache item (mirrors the private
    /// constants at SubscriptionManager.swift:224-225). A stale
    /// EntitlementCache(isPro:false) left by a prior run's async
    /// updateEntitlements() would skip legacy UserDefaults migration and rot
    /// these fixtures; clearing it in setUp AND tearDown makes both tests
    /// deterministic regardless of prior Keychain state.
    private func clearKeychainEntitlementCache() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.nexgenspec.entitlement.cache",
            kSecAttrAccount as String: "current"
        ]
        SecItemDelete(query as CFDictionary)
    }

    override func setUp() {
        super.setUp()
        clearKeychainEntitlementCache()
    }

    override func tearDown() {
        clearKeychainEntitlementCache()
        super.tearDown()
    }

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
        // Receipt PDFs MUST live OUTSIDE FilePaths.appRoot so they survive
        // store.clearAllLocalData() (the receipt outlives the wipe it documents),
        // AND outside the file-shared Documents directory so a previous account's
        // email / recovery-email / UID is never browsable by the next inspector.
        let receipt = AccountDeletionReceiptService.receiptFolder
        XCTAssertEqual(receipt.deletingLastPathComponent().standardizedFileURL,
                       FilePaths.applicationSupportDirectory.standardizedFileURL,
                       "Receipt folder must live directly under Application Support")
        XCTAssertEqual(receipt.lastPathComponent, "NexGenSpecReceipts")
        XCTAssertFalse(receipt.standardizedFileURL.path.hasPrefix(FilePaths.documentDirectory.standardizedFileURL.path),
                       "Receipt folder must NOT be in the file-shared Documents directory")
        XCTAssertFalse(receipt.standardizedFileURL.path.hasPrefix(FilePaths.appRoot.standardizedFileURL.path),
                       "Receipt folder must NOT be under appRoot (it must survive the Delete Account wipe)")
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

    func testExportFolderIsUnderAppRootNotFileShared() {
        // ZIP exports now live UNDER FilePaths.appRoot in the per-UID private
        // store — NOT the file-shared Documents directory — so one account's
        // client-PII bundles are never browsable by the next inspector on a
        // shared device. They persist across logout and are removed only by the
        // Account Deletion appRoot wipe (which is what the owner asked for:
        // logout preserves, only Delete Account deletes).
        let exports = InspectionZIPExportService.exportFolder
        XCTAssertTrue(exports.standardizedFileURL.path.hasPrefix(FilePaths.appRoot.standardizedFileURL.path),
                      "Export folder must live under the private per-UID appRoot")
        XCTAssertFalse(exports.standardizedFileURL.path.hasPrefix(FilePaths.documentDirectory.standardizedFileURL.path),
                       "Export folder must NOT be in the file-shared Documents directory")
        XCTAssertEqual(exports.lastPathComponent, "Exports")
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
        XCTAssertEqual(zipURL.deletingPathExtension().lastPathComponent,
                       ExportNaming.baseStem(for: version.inspection),
                       "ZIP must be named with the human-readable export stem, not an internal temp name")
        XCTAssertTrue(zipURL.path.contains("/Exports/"))
        XCTAssertTrue(zipURL.standardizedFileURL.path.hasPrefix(FilePaths.appRoot.standardizedFileURL.path),
                      "exported ZIP must live under the private per-UID appRoot, not Documents")

        let size = (try? FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 1000, "ZIP archive should be more than a few bytes — got \(size)")
    }
}

// MARK: - Cross-account deliverable isolation (PII leak fix)

/// Locks in the fix for the cross-account PII leak: NONE of the three deliverable
/// trees (exported ZIPs, mirrored report PDFs, deletion receipts) may live in the
/// file-shared Documents directory, and the one-time legacy sweep removes only the
/// app's own old exposed copies.
final class DeliverableIsolationTests: XCTestCase {

    func testNoDeliverableTreeLivesInFileSharedDocuments() {
        let docs = FilePaths.documentDirectory.standardizedFileURL.path

        // ZIP exports + mirrored PDFs are under the private per-UID appRoot.
        XCTAssertFalse(InspectionZIPExportService.exportFolder.standardizedFileURL.path.hasPrefix(docs),
                       "exported ZIPs (full client PII) must not be in file-shared Documents")
        XCTAssertTrue(InspectionZIPExportService.exportFolder.standardizedFileURL.path
                        .hasPrefix(FilePaths.appRoot.standardizedFileURL.path))

        let jobId = UUID()
        let sample = Inspection(id: jobId, clientName: "Leak Check", clientEmail: "", clientPhone: "",
                                propertyAddress: "1 Privacy Ln", inspectionDate: Date(),
                                inspectorName: "Insp", sections: [])
        let publishedFolder = FilesAppPublisher.publishedFolderURL(for: sample, jobId: jobId)
        XCTAssertFalse(publishedFolder.standardizedFileURL.path.hasPrefix(docs),
                       "mirrored report PDFs must not be in file-shared Documents")
        XCTAssertTrue(publishedFolder.standardizedFileURL.path
                        .hasPrefix(FilePaths.appRoot.standardizedFileURL.path))

        // Deletion receipts are outside Documents AND outside appRoot (must survive
        // the wipe) — i.e. directly under Application Support.
        XCTAssertFalse(AccountDeletionReceiptService.receiptFolder.standardizedFileURL.path.hasPrefix(docs),
                       "deletion receipts (email + recovery email + UID) must not be in file-shared Documents")
        XCTAssertFalse(AccountDeletionReceiptService.receiptFolder.standardizedFileURL.path
                        .hasPrefix(FilePaths.appRoot.standardizedFileURL.path),
                       "deletion receipts must survive the Delete Account appRoot wipe")
    }

    func testCleanupLegacyDocumentsDeliverablesRemovesOnlyAppsOwnExposedCopies() throws {
        let fm = FileManager.default
        let docs = FilePaths.documentDirectory

        let legacyExports = docs.appendingPathComponent("NexGenSpecExports", isDirectory: true)
        let legacyReports = docs.appendingPathComponent("NexGenSpecReports", isDirectory: true)
        let legacyReceipts = docs.appendingPathComponent("NexGenSpecReceipts", isDirectory: true)
        // An unrelated user file in Documents that the sweep must never touch.
        let unrelated = docs.appendingPathComponent("user-keepsake-\(UUID().uuidString).txt", isDirectory: false)

        for folder in [legacyExports, legacyReports, legacyReceipts] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("pii".utf8).write(to: folder.appendingPathComponent("leak.pdf"))
        }
        try Data("keep me".utf8).write(to: unrelated)
        addTeardownBlock {
            for url in [legacyExports, legacyReports, legacyReceipts, unrelated] {
                try? fm.removeItem(at: url)
            }
        }

        FilePaths.cleanupLegacyDocumentsDeliverables()

        XCTAssertFalse(fm.fileExists(atPath: legacyExports.path), "legacy exposed exports not removed")
        XCTAssertFalse(fm.fileExists(atPath: legacyReports.path), "legacy exposed reports not removed")
        XCTAssertFalse(fm.fileExists(atPath: legacyReceipts.path), "legacy exposed receipts not removed")
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path), "sweep deleted an unrelated user file")
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

/// B-0096 — per-UID local-data scoping + lossless migration. Proves the working
/// store is namespaced per Firebase UID (so one account can't read another's
/// data on a shared device), that the account-deletion pin overrides the live
/// UID (so the wipe targets the deleted user's namespace even after Firebase has
/// cleared `currentUser`), and that pre-fix un-namespaced data migrates into the
/// signed-in user's namespace with no loss and no clobber.
final class B0096ScopingTests: XCTestCase {

    private var savedProvider: (() -> String?)!

    override func setUp() {
        super.setUp()
        savedProvider = SessionScope.uidProvider
        SessionScope.unpin()
    }

    override func tearDown() {
        SessionScope.uidProvider = savedProvider
        SessionScope.unpin()
        super.tearDown()
    }

    func testAppRootIsDistinctPerUID() {
        SessionScope.uidProvider = { "uid-AAAA" }
        let rootA = FilePaths.appRoot
        SessionScope.uidProvider = { "uid-BBBB" }
        let rootB = FilePaths.appRoot
        XCTAssertNotEqual(rootA, rootB, "different accounts must get different store roots")
        XCTAssertEqual(rootA.lastPathComponent, "uid-AAAA")
        XCTAssertEqual(rootB.lastPathComponent, "uid-BBBB")
        XCTAssertEqual(rootA, FilePaths.userRoot(uid: "uid-AAAA"))
    }

    func testSignedOutUsesSentinelSegment() {
        SessionScope.uidProvider = { nil }
        XCTAssertEqual(FilePaths.appRoot.lastPathComponent, SessionScope.signedOutSegment)
        XCTAssertNil(SessionScope.activeUID)
    }

    func testDeletionPinOverridesLiveUID() {
        SessionScope.uidProvider = { "uid-live" }
        XCTAssertEqual(FilePaths.appRoot.lastPathComponent, "uid-live")
        SessionScope.pin("uid-deleting")
        XCTAssertEqual(FilePaths.appRoot.lastPathComponent, "uid-deleting",
                       "deletion pin must override the live UID so the wipe hits the deleted namespace")
        SessionScope.unpin()
        XCTAssertEqual(FilePaths.appRoot.lastPathComponent, "uid-live",
                       "appRoot must revert to the live UID once unpinned")
    }

    func testMigrationMovesLegacyDataIntoUserNamespaceWithoutLoss() throws {
        let fm = FileManager.default
        let uid = "uid-migrate-\(UUID().uuidString)"
        SessionScope.uidProvider = { uid }
        let dest = FilePaths.userRoot(uid: uid)
        try? fm.removeItem(at: dest)

        // Seed pre-fix un-namespaced data directly under the legacy shared root,
        // exactly where build ≤17 wrote it.
        try FileSecurity.ensureProtectedDirectory(FilePaths.legacySharedRoot)
        let legacyIndex = FilePaths.legacySharedRoot.appendingPathComponent("inspections.json")
        let payload = Data("LEGACY-INDEX-\(uid)".utf8)
        try FileSecurity.writeProtected(payload, to: legacyIndex)
        let legacyInspections = FilePaths.legacySharedRoot.appendingPathComponent("Inspections", isDirectory: true)
        let legacyJobDir = legacyInspections.appendingPathComponent("job-1", isDirectory: true)
        try FileSecurity.ensureProtectedDirectory(legacyJobDir)
        try FileSecurity.writeProtected(Data("LEGACY-JOB".utf8), to: legacyJobDir.appendingPathComponent("current.json"))

        defer {
            try? fm.removeItem(at: dest)
            try? fm.removeItem(at: legacyIndex)
            try? fm.removeItem(at: legacyInspections)
        }

        let moved = SessionMigration.runIfNeeded()
        XCTAssertTrue(moved, "migration should report it moved entries")

        // Legacy copies MOVED (not copied) out of the shared root — no residue.
        XCTAssertFalse(fm.fileExists(atPath: legacyIndex.path),
                       "legacy index must be moved out of the shared root, not left behind")
        // Data is intact in the user's namespace.
        let migratedIndex = dest.appendingPathComponent("inspections.json")
        XCTAssertTrue(fm.fileExists(atPath: migratedIndex.path))
        XCTAssertEqual(try Data(contentsOf: migratedIndex), payload, "migrated index bytes must be intact")
        let migratedJob = dest.appendingPathComponent("Inspections", isDirectory: true)
            .appendingPathComponent("job-1", isDirectory: true)
            .appendingPathComponent("current.json")
        XCTAssertTrue(fm.fileExists(atPath: migratedJob.path), "nested inspection folder must migrate too")
        // Marker written; a second run is a no-op.
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent(SessionMigration.markerName).path))
        XCTAssertFalse(SessionMigration.runIfNeeded(), "migration must not run twice for the same user")
    }

    func testMigrationNeverClobbersExistingUserData() throws {
        let fm = FileManager.default
        let uid = "uid-existing-\(UUID().uuidString)"
        SessionScope.uidProvider = { uid }
        let dest = FilePaths.userRoot(uid: uid)
        try FileSecurity.ensureProtectedDirectory(dest)
        let existing = dest.appendingPathComponent("inspections.json")
        let mine = Data("MY-OWN-DATA".utf8)
        try FileSecurity.writeProtected(mine, to: existing)
        let legacyIndex = FilePaths.legacySharedRoot.appendingPathComponent("inspections.json")
        try FileSecurity.ensureProtectedDirectory(FilePaths.legacySharedRoot)
        try FileSecurity.writeProtected(Data("SOMEONE-ELSE".utf8), to: legacyIndex)
        defer {
            try? fm.removeItem(at: dest)
            try? fm.removeItem(at: legacyIndex)
        }

        _ = SessionMigration.runIfNeeded()
        XCTAssertEqual(try Data(contentsOf: existing), mine,
                       "migration must never overwrite a user's existing index with legacy data")
    }

    func testWipeLegacyUnnamespacedDataLeavesUsersContainer() throws {
        let fm = FileManager.default
        try FileSecurity.ensureProtectedDirectory(FilePaths.usersContainer)
        let survivorRoot = FilePaths.userRoot(uid: "survivor-\(UUID().uuidString)")
        try FileSecurity.ensureProtectedDirectory(survivorRoot)
        let survivorFile = survivorRoot.appendingPathComponent("keep.json")
        try FileSecurity.writeProtected(Data("KEEP".utf8), to: survivorFile)
        let legacyFile = FilePaths.legacySharedRoot.appendingPathComponent("audit_log.txt")
        try FileSecurity.writeProtected(Data("LEGACY".utf8), to: legacyFile)
        defer { try? fm.removeItem(at: survivorRoot); try? fm.removeItem(at: legacyFile) }

        SessionMigration.wipeLegacyUnnamespacedData()
        XCTAssertFalse(fm.fileExists(atPath: legacyFile.path), "legacy un-namespaced file must be removed")
        XCTAssertTrue(fm.fileExists(atPath: survivorFile.path), "Users/<uid> namespaces must NOT be touched")
    }

    /// On-device repro guard: ONE long-lived store, the active user changes, and
    /// the index (the dashboard list) must follow the new user — not stay frozen
    /// to the segment that was active when the store was constructed. A stored
    /// (non-computed) `indexURL` froze it to the launch (signed-out) segment, so
    /// after login every account read the SAME inspections.json and saw each
    /// other's inspections. The earlier tests missed this because they built a
    /// fresh store per case; this one mutates the UID on a live store + reloads.
    @MainActor
    func testLiveStoreIndexFollowsActiveUIDAcrossReload() throws {
        let fm = FileManager.default
        let uidA = "uid-A-\(UUID().uuidString)"
        let uidB = "uid-B-\(UUID().uuidString)"
        defer {
            try? fm.removeItem(at: FilePaths.userRoot(uid: uidA))
            try? fm.removeItem(at: FilePaths.userRoot(uid: uidB))
        }

        // Store is built while signed out — mirrors the real app (the store is a
        // launch-time @StateObject, created before anyone logs in).
        SessionScope.uidProvider = { nil }
        let store = InspectionStore()

        // Account A logs in → create an inspection.
        SessionScope.uidProvider = { uidA }
        store.reloadFromDisk()
        let jobId = UUID()
        let inspection = Inspection(
            id: jobId, clientName: "A-ONLY", clientEmail: "", clientPhone: "",
            propertyAddress: "1 A Street", inspectionDate: Date(),
            inspectorName: "Inspector A", sections: []
        )
        store.insert(version: InspectionVersion(
            id: jobId, versionNumber: 1, status: .draft,
            finalizedAt: nil, locked: false, inspection: inspection
        ))
        XCTAssertEqual(store.metadataList.count, 1, "account A should see its own inspection")

        // Account B logs in on the SAME store → must NOT see A's inspection.
        SessionScope.uidProvider = { uidB }
        store.reloadFromDisk()
        XCTAssertTrue(store.metadataList.isEmpty,
                      "account B must NOT see account A's inspections after login (B-0096 index-path leak)")

        // Back to A → A's inspection returns (correct scoping, no data loss).
        SessionScope.uidProvider = { uidA }
        store.reloadFromDisk()
        XCTAssertEqual(store.metadataList.count, 1, "account A's data must return on re-login")
    }
}

/// B-0096 sibling — custom templates must be per-UID too. Drives the SINGLETON
/// (CustomTemplateStore.shared) across an account switch, the exact blind spot
/// that hid both the indexURL and CustomTemplateStore frozen-path leaks (every
/// other test built a fresh object).
@MainActor
final class B0096CustomTemplateScopingTests: XCTestCase {

    private var savedProvider: (() -> String?)!

    override func setUp() {
        super.setUp()
        savedProvider = SessionScope.uidProvider
        SessionScope.unpin()
    }

    override func tearDown() {
        SessionScope.uidProvider = savedProvider
        SessionScope.unpin()
        CustomTemplateStore.shared.clear()
        super.tearDown()
    }

    func testCustomTemplatesFollowActiveUIDOnReload() {
        let fm = FileManager.default
        let uidA = "tmpl-A-\(UUID().uuidString)"
        let uidB = "tmpl-B-\(UUID().uuidString)"
        defer {
            try? fm.removeItem(at: FilePaths.userRoot(uid: uidA))
            try? fm.removeItem(at: FilePaths.userRoot(uid: uidB))
        }
        let store = CustomTemplateStore.shared

        // Account A creates a custom template (writes to A's per-UID namespace).
        SessionScope.uidProvider = { uidA }
        store.reload()
        let template = CustomTemplate(templateId: "t-\(uidA)", name: "A's Template", sections: [])
        store.add(template)
        XCTAssertTrue(store.templates.contains { $0.templateId == template.templateId },
                      "account A should have its own template")

        // Account B logs in on the SAME singleton → must NOT see A's template.
        SessionScope.uidProvider = { uidB }
        store.reload()
        XCTAssertTrue(store.templates.isEmpty,
                      "account B must NOT see account A's custom templates (B-0096 sibling leak)")

        // Back to A → A's template returns.
        SessionScope.uidProvider = { uidA }
        store.reload()
        XCTAssertTrue(store.templates.contains { $0.templateId == template.templateId },
                      "account A's custom template must return on reload")
    }
}

/// Audit fix — the free-trial counter must advance only when an inspection was
/// actually created. `createNewInspection` now reports success so the caller can
/// gate `recordInspectionCreated()`.
@MainActor
final class CreateInspectionSuccessSignalTests: XCTestCase {

    func testReturnsFalseWhenInspectorNotConfirmed() {
        let store = InspectionStore()
        let created = store.createNewInspection(
            clientName: "C", clientEmail: "", clientPhone: "",
            propertyAddress: "1 Unconfirmed St", inspectorName: "I",
            inspectorConfirmed: false
        )
        XCTAssertFalse(created, "must not create (nor burn a trial slot) when the inspector isn't confirmed")
    }

    func testReturnsTrueAndInsertsOnSuccess() {
        let store = InspectionStore()
        let before = store.metadataList.count
        let created = store.createNewInspection(
            clientName: "C", clientEmail: "", clientPhone: "",
            propertyAddress: "1 Success St", inspectorName: "I",
            inspectorConfirmed: true
        )
        XCTAssertTrue(created)
        XCTAssertEqual(store.metadataList.count, before + 1)
        if let id = store.metadataList.first?.id { _ = store.deleteVersion(id: id) }
    }
}

/// Audit fix [5.1.1(v)] — Account Deletion must sweep report/PDF/ZIP staging
/// artifacts from the temp directory regardless of age (they carry client PII
/// and live outside appRoot, so the disk wipe never reaches them).
final class TempExportCleanupTests: XCTestCase {

    func testRemoveAllTempExportsClearsFreshPIIArtifactsButLeavesUnrelatedFiles() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let report = tmp.appendingPathComponent("report-\(UUID().uuidString)", isDirectory: true)
        let pdf = tmp.appendingPathComponent("pdf-\(UUID().uuidString)", isDirectory: true)
        let zip = tmp.appendingPathComponent("zip-staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: report, withIntermediateDirectories: true)
        try fm.createDirectory(at: pdf, withIntermediateDirectories: true)
        try fm.createDirectory(at: zip, withIntermediateDirectories: true)
        let unrelated = tmp.appendingPathComponent("KEEP-\(UUID().uuidString).txt")
        try Data("keep".utf8).write(to: unrelated)
        defer {
            try? fm.removeItem(at: report); try? fm.removeItem(at: pdf)
            try? fm.removeItem(at: zip); try? fm.removeItem(at: unrelated)
        }

        ReportExportService.removeAllTempExports()

        XCTAssertFalse(fm.fileExists(atPath: report.path), "fresh report-* staging must be swept on deletion")
        XCTAssertFalse(fm.fileExists(atPath: pdf.path), "fresh pdf-* staging must be swept on deletion")
        XCTAssertFalse(fm.fileExists(atPath: zip.path), "fresh zip-staging-* must be swept on deletion")
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path), "unrelated temp files must be left untouched")
    }
}

// MARK: - FilesAppPublisher path-traversal safety (B-0117)

/// Regression tests for the data-loss bug where a free-text Property Address of
/// "." or ".." became the report-mirror folder name, so `publish()`'s
/// rebuild-delete (`removeItem(at: reportsFolder/<name>)`) climbed to `appRoot`
/// and silently wiped the user's entire per-UID store.
final class FilesAppPublisherSafetyTests: XCTestCase {

    func testTraversalAndSeparatorComponentsAreRejected() {
        XCTAssertFalse(FilesAppPublisher.isSafeComponent(".."), "\"..\" must be rejected — it climbs to appRoot")
        XCTAssertFalse(FilesAppPublisher.isSafeComponent("."), "\".\" must be rejected — it targets the Reports root")
        XCTAssertFalse(FilesAppPublisher.isSafeComponent(""), "empty must be rejected")
        XCTAssertFalse(FilesAppPublisher.isSafeComponent("a/b"), "a forward slash must be rejected")
        XCTAssertFalse(FilesAppPublisher.isSafeComponent("a\\b"), "a backslash must be rejected")
        XCTAssertTrue(FilesAppPublisher.isSafeComponent("123 Main St"), "a normal address must be accepted")
        XCTAssertTrue(FilesAppPublisher.isSafeComponent(".hidden"), "a leading dot (not a traversal token) is fine")
    }

    func testSanitizedDoesNotStripDotsSoTheGuardIsLoadBearing() {
        // Documents WHY isSafeComponent must exist: sanitized() removes path
        // separators but leaves lone dots intact, so "." / ".." survive it and
        // must be caught downstream. If a future change makes sanitized() strip
        // dots, this test failing is the signal to re-evaluate the guard.
        XCTAssertEqual(FilesAppPublisher.sanitized(".."), "..")
        XCTAssertEqual(FilesAppPublisher.sanitized("  ..  "), "..")
        XCTAssertEqual(FilesAppPublisher.sanitized("123 Main St / Apt 2"), "123 Main St Apt 2")
    }

    func testEveryAcceptedNameStaysContainedInReportsFolder() {
        // The core data-loss invariant (B-0117): a folder name that passes
        // isSafeComponent, appended to reportsFolder, must resolve to a path
        // strictly INSIDE reportsFolder — never reportsFolder itself or appRoot —
        // so publish()'s removeItem can never wipe the store.
        let root = FilePaths.reportsFolder.standardizedFileURL.path
        let appRoot = FilePaths.appRoot.standardizedFileURL.path
        for candidate in ["..", ".", "", "a/b", "123 Main St", ".hidden", "Inspection-1234abcd"] {
            let name = FilesAppPublisher.isSafeComponent(candidate) ? candidate : "Inspection-fallback"
            let dest = FilePaths.reportsFolder.appendingPathComponent(name, isDirectory: true).standardizedFileURL.path
            XCTAssertTrue(dest.hasPrefix(root + "/"), "folder name \"\(candidate)\" escaped reportsFolder → \(dest)")
            XCTAssertNotEqual(dest, root, "folder name \"\(candidate)\" resolved to the Reports root itself")
            XCTAssertNotEqual(dest, appRoot, "folder name \"\(candidate)\" resolved to appRoot — store-wipe path")
        }
    }
}

// MARK: - Build 22 slice 4c — two-way apply (remote → local)

/// Records changes the store forwards to the cloud port, so a test can prove a
/// genuine local edit pushes but applying a synced-in remote change does NOT echo
/// back (the apply→push→apply loop the `isApplyingRemote` flag exists to break).
private final class RecordingSyncPort: SyncPort, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var changes: [SyncChange] = []
    var status: SyncStatus = .idle
    func bind(firebaseUID: String) async {}
    func unbind() {}
    func recordLocalChange(_ change: SyncChange) { lock.withLock { changes.append(change) } }
    func seedIfNeeded(firebaseUID: String) async {}
    func pull() async {}
    func flushPending() async {}
    var count: Int { lock.withLock { changes.count } }
}

/// Slice 4c — the InspectionStore-backed remote-apply path: it must suppress the
/// push-back loop, be quota-safe (upsert, never `recordInspectionCreated`), let a
/// remote finalization supersede a local draft, and preserve the remote's edit
/// time while stamping local edits. Coupled to the on-disk store (no injectable
/// root), so it stashes `appRoot` aside for determinism like the B-0044 suite.
@MainActor
final class Build22Slice4cSyncTests: XCTestCase {

    private var stashDir: URL!
    private var inspectionsDir: URL { FilePaths.appRoot.appendingPathComponent("Inspections", isDirectory: true) }

    override func setUpWithError() throws {
        let fm = FileManager.default
        try FileSecurity.ensureProtectedDirectory(FilePaths.appRoot)
        stashDir = fm.temporaryDirectory.appendingPathComponent("ngs-s4c-\(UUID().uuidString)", isDirectory: true)
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

    private func makeVersion(id: UUID = UUID(), locked: Bool = false, status: VersionStatus = .draft, marker: String = "x") -> InspectionVersion {
        let inspection = Inspection(
            id: id, clientName: "Client", clientEmail: "", clientPhone: "",
            propertyAddress: marker, inspectionDate: Date(), inspectorName: "Inspector", sections: []
        )
        return InspectionVersion(
            id: id, versionNumber: 1, status: status,
            finalizedAt: locked ? Date() : nil, locked: locked, inspection: inspection
        )
    }

    func testApplyRemoteVersionDoesNotEchoPushButLocalEditDoes() {
        let port = RecordingSyncPort()
        let coord = SyncCoordinator(isEnabled: { true }, makeCloudPort: { port })
        let store = InspectionStore()
        store.syncCoordinator = coord
        coord.userDidChange(uid: "u")   // binds the recording port (selection is synchronous)

        store.insert(version: makeVersion(marker: "local"))
        XCTAssertEqual(port.count, 1, "A genuine local write mirrors to the cloud port.")

        let remote = makeVersion(marker: "remote")
        store.applyRemoteVersion(remote)
        XCTAssertEqual(port.count, 1, "Applying a synced-in version must not push it back (no apply→push loop).")
        XCTAssertTrue(store.metadataList.contains { $0.id == remote.id }, "The remote version is applied locally.")
    }

    func testApplyRemoteDeleteRemovesDraftWithoutEcho() {
        let port = RecordingSyncPort()
        let coord = SyncCoordinator(isEnabled: { true }, makeCloudPort: { port })
        let store = InspectionStore()
        store.syncCoordinator = coord
        coord.userDidChange(uid: "u")

        let v = makeVersion(marker: "to-delete")
        store.applyRemoteVersion(v)
        XCTAssertEqual(port.count, 0, "apply does not push")
        XCTAssertTrue(store.metadataList.contains { $0.id == v.id })

        store.applyRemoteDelete(id: v.id)
        XCTAssertFalse(store.metadataList.contains { $0.id == v.id }, "A remote tombstone removes the local draft.")
        XCTAssertEqual(port.count, 0, "Applying a remote delete must not echo a delete push.")
    }

    func testRemoteFinalizationSupersedesLocalDraftAsUpsert() {
        let store = InspectionStore()
        let id = UUID()
        store.insert(version: makeVersion(id: id, locked: false, status: .draft, marker: "draft"))
        XCTAssertEqual(store.metadataList.filter { $0.id == id }.count, 1)
        XCTAssertEqual(store.metadataList.first { $0.id == id }?.locked, false)

        var finalized = makeVersion(id: id, locked: true, status: .final, marker: "final")
        finalized.updatedAt = Date()
        store.applyRemoteVersion(finalized)

        XCTAssertEqual(store.metadataList.filter { $0.id == id }.count, 1, "Upsert replaces in place — never duplicates a row.")
        XCTAssertEqual(store.metadataList.first { $0.id == id }?.locked, true, "A remote finalization supersedes the local draft (a case update() would refuse).")
        XCTAssertEqual(store.loadFullVersion(id: id)?.status, .final)
    }

    func testApplyRemoteVersionPreservesRemoteUpdatedAtButLocalWriteStamps() {
        let store = InspectionStore()

        // Applying a remote version preserves its edit time (no re-stamp to pull time).
        let remoteTime = Date(timeIntervalSince1970: 1_600_000_000)
        var remote = makeVersion(marker: "remote-ts")
        remote.updatedAt = remoteTime
        store.applyRemoteVersion(remote)
        XCTAssertEqual(store.loadFullVersion(id: remote.id)?.updatedAt, remoteTime,
                       "Applying a remote version preserves its updatedAt (no re-stamp).")

        // A genuine local write stamps updatedAt to ~now.
        let before = Date().addingTimeInterval(-2)
        let local = makeVersion(marker: "local-stamp")
        store.insert(version: local)
        let stamped = store.loadFullVersion(id: local.id)?.updatedAt
        XCTAssertNotNil(stamped, "A local write stamps updatedAt.")
        if let stamped { XCTAssertGreaterThanOrEqual(stamped, before, "Local updatedAt is ~now.") }
    }

    func testLiveWriterDecodesPayloadAndAppliesViaStore() async {
        let store = InspectionStore()
        let writer = InspectionStoreVersionWriter(store: store)
        let v = makeVersion(marker: "via-writer")
        let payload = try! JSONEncoder().encode(v)

        let applied = await writer.applyRemoteVersion(payload)
        XCTAssertTrue(applied, "applyRemoteVersion reports success.")
        XCTAssertTrue(store.metadataList.contains { $0.id == v.id }, "The live writer decodes the payload and applies it via the store.")

        let deleted = await writer.deleteLocalVersion(recordName: v.id.uuidString)
        XCTAssertTrue(deleted, "deleteLocalVersion reports success.")
        XCTAssertFalse(store.metadataList.contains { $0.id == v.id }, "The live writer applies a remote tombstone.")
    }

    func testRemoteTombstoneLeavesFilesAppExportButLocalDeleteRemovesIt() throws {
        let store = InspectionStore()

        // A REMOTE tombstone removes the local version but must NOT reach into the
        // user's exported Files-app report folder (observer/mirror contract, F4).
        let id = UUID()
        let v = makeVersion(id: id, marker: "F4-remote-\(id.uuidString.prefix(6))")
        store.insert(version: v)
        let folder = FilesAppPublisher.publishedFolderURL(for: v.inspection, jobId: id)
        try FileSecurity.ensureProtectedDirectory(folder)
        let marker = folder.appendingPathComponent("report.pdf")
        try FileSecurity.writeProtected(Data("pdf".utf8), to: marker)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        _ = store.applyRemoteDelete(id: id)
        XCTAssertFalse(store.metadataList.contains { $0.id == id }, "Remote tombstone removes the local version.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "Remote tombstone must NOT delete the user's Files-app export (F4).")

        // Control: a genuine USER delete DOES remove its export.
        let id2 = UUID()
        let v2 = makeVersion(id: id2, marker: "F4-local-\(id2.uuidString.prefix(6))")
        store.insert(version: v2)
        let folder2 = FilesAppPublisher.publishedFolderURL(for: v2.inspection, jobId: id2)
        try FileSecurity.ensureProtectedDirectory(folder2)
        let marker2 = folder2.appendingPathComponent("report.pdf")
        try FileSecurity.writeProtected(Data("pdf".utf8), to: marker2)
        defer { try? FileManager.default.removeItem(at: folder2) }

        _ = store.deleteVersion(id: id2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker2.path),
                       "A user-initiated delete still removes the export (control).")
    }

    func testLegacyMigrationKeepsIndexAndDiskUpdatedAtInAgreement() throws {
        // Write a legacy-format index (bare [InspectionVersion] array) with a known
        // updatedAt, then load a fresh store (init→load→applyDecodedIndex legacy
        // migration) and assert the migration PRESERVED the clock identically on the
        // index row and current.json — no fabricated migration-time stamp, no
        // index↔disk divergence (review F1 follow-up).
        let id = UUID()
        let legacyTime = Date(timeIntervalSince1970: 1_500_000_000)
        var v = makeVersion(id: id, marker: "legacy-migrate")
        v.updatedAt = legacyTime
        let legacyArray = try JSONEncoder().encode([v])   // bare array == legacy format
        try FileSecurity.ensureProtectedDirectory(FilePaths.appRoot)
        try FileSecurity.writeProtected(legacyArray, to: FilePaths.inspectionsIndex)

        let store = InspectionStore()
        let row = store.metadataList.first { $0.id == id }
        XCTAssertNotNil(row, "Legacy version migrated into the index.")
        XCTAssertEqual(row?.updatedAt, legacyTime, "Migration preserves the legacy updatedAt in the index.")
        XCTAssertEqual(store.loadFullVersion(id: id)?.updatedAt, legacyTime, "Migration preserves the legacy updatedAt on disk.")
        XCTAssertEqual(row?.updatedAt, store.loadFullVersion(id: id)?.updatedAt,
                       "Index and current.json agree on updatedAt after migration (F1 follow-up).")
    }

    func testLocalWriteKeepsMetadataUpdatedAtConsistentWithDisk() {
        let store = InspectionStore()
        let v = makeVersion(marker: "F1-consistency")
        store.insert(version: v)
        XCTAssertEqual(store.metadataList.first { $0.id == v.id }?.updatedAt,
                       store.loadFullVersion(id: v.id)?.updatedAt,
                       "insert: metadataList updatedAt matches current.json — no stale index clock (F1).")

        var edited = store.loadFullVersion(id: v.id)!
        edited.inspection.clientName = "Edited"
        store.update(version: edited)
        XCTAssertEqual(store.metadataList.first { $0.id == v.id }?.updatedAt,
                       store.loadFullVersion(id: v.id)?.updatedAt,
                       "update: metadataList updatedAt matches current.json (F1).")
    }

    func testDiskReaderLocalStatePrefersModelUpdatedAt() {
        let store = InspectionStore()
        let ts = Date(timeIntervalSince1970: 1_650_000_000)
        var v = makeVersion(marker: "disk-ts")
        v.updatedAt = ts
        store.applyRemoteVersion(v)

        let state = DiskVersionReader().localState(forVersionId: v.id)
        XCTAssertTrue(state.exists)
        XCTAssertFalse(state.isFinalized)
        XCTAssertEqual(state.updatedAt, ts, "localState uses the model's updatedAt as the LWW clock.")
    }

    func testUpdatedAtCodableIsAdditiveAndRoundTrips() throws {
        var v = makeVersion(marker: "codable")

        // nil ⇒ key omitted (back-compat: legacy readers/JSON unaffected), decodes to nil.
        v.updatedAt = nil
        let dataNil = try JSONEncoder().encode(v)
        XCTAssertFalse(String(decoding: dataNil, as: UTF8.self).contains("updatedAt"),
                       "updatedAt is omitted when nil (additive / forward-compatible).")
        XCTAssertNil(try JSONDecoder().decode(InspectionVersion.self, from: dataNil).updatedAt)

        // set ⇒ round-trips through both the version and its metadata projection.
        let ts = Date(timeIntervalSince1970: 1_680_000_000)
        v.updatedAt = ts
        let data = try JSONEncoder().encode(v)
        XCTAssertEqual(try JSONDecoder().decode(InspectionVersion.self, from: data).updatedAt, ts)

        let meta = VersionMetadata(from: v)
        XCTAssertEqual(meta.updatedAt, ts, "VersionMetadata mirrors the version's updatedAt.")
        let metaData = try JSONEncoder().encode(meta)
        XCTAssertEqual(try JSONDecoder().decode(VersionMetadata.self, from: metaData).updatedAt, ts)
    }
}

// MARK: - Asset sync classifier + recordName (W1, D-0203)

/// Pure-function coverage for the synced-asset path classifier (defense-in-depth on
/// both push and pull) and the deterministic asset recordName. No CloudKit / disk.
final class SyncAssetPathsTests: XCTestCase {

    private let jobId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let scanId = "22222222-2222-2222-2222-222222222222"
    private let photoId = "33333333-3333-3333-3333-333333333333"

    func testCanonicalPathsMapToExpectedKinds() {
        let insp = "Inspections/\(jobId.uuidString)"
        XCTAssertEqual(SyncAssetPaths.kind(forRelativePath: "\(insp)/thumbnails/\(photoId).jpg"), .thumbnail)
        XCTAssertEqual(SyncAssetPaths.kind(forRelativePath: "\(insp)/lidar/\(scanId).json"), .lidarScan)
        XCTAssertEqual(SyncAssetPaths.kind(forRelativePath: "\(insp)/lidar/\(scanId)_floorplan.png"), .lidarFloorplan)
        XCTAssertEqual(SyncAssetPaths.kind(forRelativePath: "\(insp)/lidar/\(scanId)_room.json"), .lidarRoom)
        XCTAssertEqual(SyncAssetPaths.kind(forRelativePath: "Reports/123 Main St/Inspection_Report.pdf"), .reportPDF)
    }

    func testExcludedAndForeignPathsMapToNil() {
        let insp = "Inspections/\(jobId.uuidString)"
        XCTAssertNil(SyncAssetPaths.kind(forRelativePath: "\(insp)/photos/\(photoId).jpg"))     // full-res photo
        XCTAssertNil(SyncAssetPaths.kind(forRelativePath: "\(insp)/videos/\(scanId).mov"))       // video
        XCTAssertNil(SyncAssetPaths.kind(forRelativePath: "\(insp)/lidar/\(scanId).usdz"))        // 3D scan
        XCTAssertNil(SyncAssetPaths.kind(forRelativePath: "\(insp)/lidar/whole_home_x.png"))      // derived cache
        XCTAssertNil(SyncAssetPaths.kind(forRelativePath: "\(insp)/lidar/other.png"))             // other png guard
        XCTAssertNil(SyncAssetPaths.kind(forRelativePath: "somewhere/else.txt"))                  // foreign
    }

    func testTraversalAndMalformedPathsRejected() {
        XCTAssertNil(SyncAssetPaths.kind(forRelativePath: "Inspections/\(jobId.uuidString)/lidar/../../escape.json"))
        XCTAssertNil(SyncAssetPaths.kind(forRelativePath: ""))
        XCTAssertNil(SyncAssetPaths.kind(forRelativePath: "/abs/Reports/x.pdf"))
    }

    func testAssetRecordNameIsDeterministicAndPathSensitive() {
        let a = "Inspections/\(jobId.uuidString)/lidar/\(scanId).json"
        let b = "Inspections/\(jobId.uuidString)/lidar/\(scanId)_room.json"
        // Same inputs → same output (idempotent overwrite target).
        XCTAssertEqual(CloudKitSchema.assetRecordName(jobId: jobId, relativePath: a),
                       CloudKitSchema.assetRecordName(jobId: jobId, relativePath: a))
        // Different path → different record.
        XCTAssertNotEqual(CloudKitSchema.assetRecordName(jobId: jobId, relativePath: a),
                          CloudKitSchema.assetRecordName(jobId: jobId, relativePath: b))
        // Different jobId → different record.
        XCTAssertNotEqual(CloudKitSchema.assetRecordName(jobId: jobId, relativePath: a),
                          CloudKitSchema.assetRecordName(jobId: UUID(), relativePath: a))
        // Prefixed + bounded, never collides with a versionId.uuidString.
        let name = CloudKitSchema.assetRecordName(jobId: jobId, relativePath: a)
        XCTAssertTrue(name.hasPrefix("asset-"))
        XCTAssertNil(UUID(uuidString: name))
    }

    func testRecordTypeRoutingByKind() {
        XCTAssertEqual(CloudKitSchema.recordType(forAssetKind: SyncAssetKind.reportPDF.rawValue),
                       CloudKitSchema.RecordType.reportPDF)
        for kind: SyncAssetKind in [.thumbnail, .lidarFloorplan, .lidarScan, .lidarRoom] {
            XCTAssertEqual(CloudKitSchema.recordType(forAssetKind: kind.rawValue),
                           CloudKitSchema.RecordType.mediaAsset)
        }
    }
}

// MARK: - Export file naming (client-facing deliverables)

/// Locks the human-readable naming for exported/shared artifacts (the ZIP + its
/// unzipped folder, the shared PDF, and the text summary). The prior scheme
/// leaked an internal `zip-staging-<UUID>` folder name and generic
/// `Inspection_Report.pdf` names to clients; `ExportNaming` makes every
/// deliverable read "<Company>_<Property>_<Date>".
final class ExportNamingTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_783_900_800)

    func testBaseStemCompanyPropertyDate() {
        let stem = ExportNaming.baseStem(company: "Summit Home Inspections",
                                         property: "123 Main St", date: fixedDate)
        XCTAssertTrue(stem.hasPrefix("Summit-Home-Inspections_123-Main-St_"), stem)
        let fields = stem.split(separator: "_")
        XCTAssertEqual(fields.count, 3)
        let date = String(fields[2])
        XCTAssertEqual(date.count, 10)                        // yyyy-MM-dd
        XCTAssertEqual(date.filter { $0 == "-" }.count, 2)
    }

    func testBaseStemDropsEmptyCompany() {
        let stem = ExportNaming.baseStem(company: "   ", property: "45 Oak Ave", date: fixedDate)
        XCTAssertTrue(stem.hasPrefix("45-Oak-Ave_"), stem)
        XCTAssertEqual(stem.split(separator: "_").count, 2)
    }

    func testBaseStemEmptyPropertyBecomesInspection() {
        let stem = ExportNaming.baseStem(company: "", property: "  ", date: fixedDate)
        XCTAssertTrue(stem.hasPrefix("Inspection_"), stem)
    }

    func testBaseStemSanitizesUnsafeCharacters() {
        let stem = ExportNaming.baseStem(company: "A/B: Co.", property: "12 O'Neil Rd #4", date: fixedDate)
        for bad in ["/", ":", "'", "#", " ", ".."] {
            XCTAssertFalse(stem.contains(bad), "stem must not contain \(bad): \(stem)")
        }
        XCTAssertFalse(stem.contains("--"), stem)             // no doubled hyphens
    }

    func testBaseStemClampsLongComponents() {
        let long = String(repeating: "a", count: 200)
        let stem = ExportNaming.baseStem(company: long, property: long, date: fixedDate)
        for field in stem.split(separator: "_").dropLast() {  // skip the date field
            XCTAssertLessThanOrEqual(field.count, 60)
        }
    }

    func testPreparedShareURLRenamesOnlyWhenNeeded() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngs-share-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let internalPDF = tmp.appendingPathComponent("Inspection_Report.pdf")
        try Data("pdf".utf8).write(to: internalPDF)

        // Different desired name → a copy under the clean name, in a reap-tagged dir.
        let renamed = ExportNaming.preparedShareURL(for: internalPDF, desiredName: "123-Main-St_2026-07-10.pdf")
        XCTAssertEqual(renamed.lastPathComponent, "123-Main-St_2026-07-10.pdf")
        XCTAssertNotEqual(renamed.path, internalPDF.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertTrue(renamed.path.contains("ngs-export-"), "share copy must live in a reap-tagged dir")
        try? FileManager.default.removeItem(at: renamed.deletingLastPathComponent())

        // Same name → original returned unchanged (no wasteful copy — e.g. ZIP backups).
        let same = ExportNaming.preparedShareURL(for: internalPDF, desiredName: "Inspection_Report.pdf")
        XCTAssertEqual(same.path, internalPDF.path)
    }
}
