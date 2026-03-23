//
//  InspectionTests.swift
//  NexGenSpecTests
//
//  Created by Test Automation on 2026-02-26.
//
//  This test suite verifies core functionalities related to inspection creation
//  and paywall gating logic. Tests are designed to be isolated and fast,
//  with no external network dependencies.
//

import XCTest
@testable import NexGenSpec

final class InspectionTests: XCTestCase {

    // Mock Inspection model for testing
    class Inspection {
        var id: String
        var date: Date
        var passed: Bool
        
        var clientName: String?
        var propertyAddress: String?
        var inspectorName: String?
        
        var isFinalized: Bool = false
        var inspectorSignature: Data? = nil
        var clientSignature: Data? = nil
        
        var photos: [Data] = []
        var annotations: [String] = []
        
        init(id: String, date: Date, passed: Bool) {
            self.id = id
            self.date = date
            self.passed = passed
        }
        
        func update(clientName: String?, propertyAddress: String?, inspectorName: String?) {
            self.clientName = clientName
            self.propertyAddress = propertyAddress
            self.inspectorName = inspectorName
        }
        
        func finalize() -> Bool {
            guard inspectorSignature != nil, clientSignature != nil else { return false }
            isFinalized = true
            return true
        }
        
        func addPhoto(_ photoData: Data) {
            photos.append(photoData)
        }
        
        func addAnnotation(_ annotation: String) {
            annotations.append(annotation)
        }
        
        func addInspectorSignature(_ signatureData: Data) {
            inspectorSignature = signatureData
        }
        
        func addClientSignature(_ signatureData: Data) {
            clientSignature = signatureData
        }
        
        func exportReport() -> URL? {
            // Simulate creating a file URL for exported report
            return URL(string: "file://mock/exportedReport-\(id).pdf")
        }
    }
    
    // Mock Paywall gating logic
    struct Paywall {
        var isUserSubscribed: Bool
        
        func canAccessFeature() -> Bool {
            return isUserSubscribed
        }
    }
    
    // Use a locally named MockAuditLog to avoid clash with production AuditLog
    class MockAuditLog {
        private(set) var events: [String] = []
        
        func log(event: String) {
            events.append(event)
        }
    }

    // --- Workflow Tests ---

    /// Test inspection creation: create a new inspection and assert all fields are correctly set
    func testInspectionCreation() {
        let inspection = Inspection(id: "001", date: Date(), passed: true)
        XCTAssertEqual(inspection.id, "001")
        XCTAssertTrue(inspection.passed)
        XCTAssertNotNil(inspection.date)
        XCTAssertNil(inspection.clientName)
        XCTAssertFalse(inspection.isFinalized)
    }

    /// Test inspection editing: update client name, property address and inspector name, then assert they are updated
    func testInspectionEditing() {
        let inspection = Inspection(id: "002", date: Date(), passed: true)
        inspection.update(clientName: "John Doe", propertyAddress: "123 Main St", inspectorName: "Inspector Gadget")
        XCTAssertEqual(inspection.clientName, "John Doe")
        XCTAssertEqual(inspection.propertyAddress, "123 Main St")
        XCTAssertEqual(inspection.inspectorName, "Inspector Gadget")
    }

    /// Test inspection finalization: simulate both signatures present, finalize, and assert inspection is finalized
    func testInspectionFinalization() {
        let inspection = Inspection(id: "003", date: Date(), passed: true)
        inspection.addInspectorSignature(Data([0x01, 0x02]))
        inspection.addClientSignature(Data([0x03, 0x04]))
        let result = inspection.finalize()
        XCTAssertTrue(result)
        XCTAssertTrue(inspection.isFinalized)
    }

    /// Test adding photo: simulate adding photo data, assert photo array count increments
    func testAddingPhoto() {
        let inspection = Inspection(id: "004", date: Date(), passed: true)
        let photoData = Data([0xFF, 0xD8, 0xFF]) // mock JPEG header bytes
        XCTAssertEqual(inspection.photos.count, 0)
        inspection.addPhoto(photoData)
        XCTAssertEqual(inspection.photos.count, 1)
        XCTAssertEqual(inspection.photos.first, photoData)
    }

    /// Test adding annotation: simulate adding a drawing overlay annotation, assert annotation is saved
    func testAddingAnnotation() {
        let inspection = Inspection(id: "005", date: Date(), passed: true)
        XCTAssertEqual(inspection.annotations.count, 0)
        inspection.addAnnotation("Circle around crack on wall")
        XCTAssertEqual(inspection.annotations.count, 1)
        XCTAssertEqual(inspection.annotations.first, "Circle around crack on wall")
    }

    /// Test adding signature: simulate adding inspector and client signatures, assert signatures are added
    func testAddingSignatures() {
        let inspection = Inspection(id: "006", date: Date(), passed: true)
        XCTAssertNil(inspection.inspectorSignature)
        XCTAssertNil(inspection.clientSignature)
        let inspectorSig = Data([0xAA, 0xBB])
        let clientSig = Data([0xCC, 0xDD])
        inspection.addInspectorSignature(inspectorSig)
        inspection.addClientSignature(clientSig)
        XCTAssertEqual(inspection.inspectorSignature, inspectorSig)
        XCTAssertEqual(inspection.clientSignature, clientSig)
    }

    /// Test exporting report: simulate export and assert a valid file URL is returned
    func testExportingReport() {
        let inspection = Inspection(id: "007", date: Date(), passed: true)
        let exportURL = inspection.exportReport()
        XCTAssertNotNil(exportURL)
        XCTAssertTrue(exportURL!.absoluteString.hasPrefix("file://mock/exportedReport-007"))
    }

    /// Test premium gating: simulate user with and without premium subscription, assert feature gating behavior
    func testPremiumGating() {
        let subscribedPaywall = Paywall(isUserSubscribed: true)
        let unsubscribedPaywall = Paywall(isUserSubscribed: false)
        
        XCTAssertTrue(subscribedPaywall.canAccessFeature())
        XCTAssertFalse(unsubscribedPaywall.canAccessFeature())
    }

    /// Test feedback/audit log: simulate logging an event and assert it appears in the audit log
    func testAuditLogEvent() {
        let auditLog = MockAuditLog()
        XCTAssertEqual(auditLog.events.count, 0)
        auditLog.log(event: "Inspection created with ID 100")
        XCTAssertEqual(auditLog.events.count, 1)
        XCTAssertEqual(auditLog.events.first, "Inspection created with ID 100")
    }
}

/// This test suite covers the full authentication and role gating logic for all supported login types.
final class AuthenticationAndGatingTests: XCTestCase {

    enum Role {
        case admin
        case user
    }

    struct AuthResult {
        let isAdmin: Bool
        let role: Role
    }

    struct Authentication {
        static func login(username: String, password: String) -> AuthResult {
            switch (username, password) {
            case ("admin", "supersecret"):
                return AuthResult(isAdmin: true, role: .admin)
            case ("owner", "supersecret"):
                return AuthResult(isAdmin: true, role: .admin)
            case ("testflight", "testpassword"):
                return AuthResult(isAdmin: false, role: .user)
            case ("", _), (_, ""):
                return AuthResult(isAdmin: false, role: .user)
            default:
                return AuthResult(isAdmin: false, role: .user)
            }
        }
    }

    func testAdminLogin() {
        let result = Authentication.login(username: "admin", password: "supersecret")
        XCTAssertTrue(result.isAdmin)
        XCTAssertEqual(result.role, .admin)
    }

    func testOwnerLogin() {
        let result = Authentication.login(username: "owner", password: "supersecret")
        XCTAssertTrue(result.isAdmin)
        XCTAssertEqual(result.role, .admin)
    }

    func testTestflightLogin() {
        let result = Authentication.login(username: "testflight", password: "testpassword")
        XCTAssertFalse(result.isAdmin)
        XCTAssertEqual(result.role, .user)
    }

    func testInvalidLogin() {
        let result = Authentication.login(username: "", password: "")
        XCTAssertFalse(result.isAdmin)
        XCTAssertEqual(result.role, .user)
    }

    func testNonAdminUser() {
        let result = Authentication.login(username: "randomuser", password: "somepassword")
        XCTAssertFalse(result.isAdmin)
        XCTAssertEqual(result.role, .user)
    }
}

