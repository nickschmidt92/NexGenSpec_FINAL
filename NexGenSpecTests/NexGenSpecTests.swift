//
//  NexGenSpecTests.swift
//  NexGenSpec
//

import XCTest
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
}

@MainActor
final class AuthManagerTests: XCTestCase {
    func testLoginRejectsEmptyCredentials() {
        let auth = AuthManager()
        XCTAssertFalse(auth.login(username: "", password: ""))
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertEqual(auth.role, .none)
    }

    func testCreateAccountThenLogin() {
        let auth = AuthManager()
        let username = "tester-\(UUID().uuidString)"
        XCTAssertTrue(auth.createAccount(username: username, password: "pass1234"))
        auth.logout()
        XCTAssertTrue(auth.login(username: username, password: "pass1234"))
        XCTAssertTrue(auth.isAuthenticated)
    }
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
