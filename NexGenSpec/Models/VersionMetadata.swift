//
//  VersionMetadata.swift
//  NexGenSpec
//
//  Lightweight version entry for list. Full version loaded on demand from disk.
//

import Foundation

/// Metadata for dashboard list. Full InspectionVersion loaded via store.loadFullVersion(id).
public struct VersionMetadata: Identifiable, Codable, Equatable {
    public var id: UUID
    public var inspectionId: UUID
    public var versionNumber: Int
    public var status: VersionStatus
    public var finalizedAt: Date?
    public var locked: Bool
    public var clientName: String
    public var propertyAddress: String
    public var inspectionDate: Date

    public init(id: UUID, inspectionId: UUID, versionNumber: Int, status: VersionStatus, finalizedAt: Date?, locked: Bool, clientName: String, propertyAddress: String, inspectionDate: Date) {
        self.id = id
        self.inspectionId = inspectionId
        self.versionNumber = versionNumber
        self.status = status
        self.finalizedAt = finalizedAt
        self.locked = locked
        self.clientName = clientName
        self.propertyAddress = propertyAddress
        self.inspectionDate = inspectionDate
    }

    public init(from version: InspectionVersion) {
        self.id = version.id
        self.inspectionId = UUID(uuidString: version.inspection.inspectionId) ?? version.id
        self.versionNumber = version.versionNumber
        self.status = version.status
        self.finalizedAt = version.finalizedAt
        self.locked = version.locked
        self.clientName = version.inspection.clientName
        self.propertyAddress = version.inspection.propertyAddress
        self.inspectionDate = version.inspection.inspectionDate
    }

    /// Lifecycle state derived from status + locked (for state machine checks).
    public var state: InspectionState {
        if locked { return .finalized(versionId: id) }
        switch status {
        case .draft: return .draft
        case .final: return .finalized(versionId: id)
        }
    }

    public var isEditable: Bool { state.isEditable }
}
