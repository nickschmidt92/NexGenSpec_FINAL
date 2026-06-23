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
    /// Cover photo filename relative to the inspection folder, mirrored from
    /// `Inspection.coverPhotoFileName`. Mirrored here so the dashboard list
    /// can render a thumbnail without paying the cost of loading every full
    /// `Inspection` JSON. Refreshed every time `VersionMetadata(from:)` runs
    /// after a save.
    public var coverPhotoFileName: String?
    /// Last local-edit time, mirrored from `InspectionVersion.updatedAt` — the
    /// last-writer-wins clock carried into the CloudKit record so a pull can
    /// arbitrate draft conflicts by edit time (build 22, slice 4c). Optional +
    /// additive: nil for legacy rows / versions written before build 22.
    public var updatedAt: Date?

    public init(
        id: UUID,
        inspectionId: UUID,
        versionNumber: Int,
        status: VersionStatus,
        finalizedAt: Date?,
        locked: Bool,
        clientName: String,
        propertyAddress: String,
        inspectionDate: Date,
        coverPhotoFileName: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.inspectionId = inspectionId
        self.versionNumber = versionNumber
        self.status = status
        self.finalizedAt = finalizedAt
        self.locked = locked
        self.clientName = clientName
        self.propertyAddress = propertyAddress
        self.inspectionDate = inspectionDate
        self.coverPhotoFileName = coverPhotoFileName
        self.updatedAt = updatedAt
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
        self.coverPhotoFileName = version.inspection.coverPhotoFileName
        self.updatedAt = version.updatedAt
    }

    // MARK: - Codable (backward-compat for older inspections.json)

    enum CodingKeys: String, CodingKey {
        case id, inspectionId, versionNumber, status, finalizedAt, locked
        case clientName, propertyAddress, inspectionDate
        case coverPhotoFileName
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        inspectionId = try c.decode(UUID.self, forKey: .inspectionId)
        versionNumber = try c.decode(Int.self, forKey: .versionNumber)
        status = try c.decode(VersionStatus.self, forKey: .status)
        finalizedAt = try c.decodeIfPresent(Date.self, forKey: .finalizedAt)
        locked = try c.decode(Bool.self, forKey: .locked)
        clientName = try c.decode(String.self, forKey: .clientName)
        propertyAddress = try c.decode(String.self, forKey: .propertyAddress)
        inspectionDate = try c.decode(Date.self, forKey: .inspectionDate)
        coverPhotoFileName = try c.decodeIfPresent(String.self, forKey: .coverPhotoFileName)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(inspectionId, forKey: .inspectionId)
        try c.encode(versionNumber, forKey: .versionNumber)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(finalizedAt, forKey: .finalizedAt)
        try c.encode(locked, forKey: .locked)
        try c.encode(clientName, forKey: .clientName)
        try c.encode(propertyAddress, forKey: .propertyAddress)
        try c.encode(inspectionDate, forKey: .inspectionDate)
        try c.encodeIfPresent(coverPhotoFileName, forKey: .coverPhotoFileName)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
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
