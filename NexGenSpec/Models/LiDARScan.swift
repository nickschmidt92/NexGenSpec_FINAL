//
//  LiDARScan.swift
//  NexGenSpec
//
//  LiDAR/RoomPlan scan model. Feature-gated for LiDAR-capable devices.
//

import Foundation

/// A single LiDAR scan attached to an inspection version.
public struct LiDARScan: Identifiable, Codable, Equatable {
    public var id: UUID
    public var versionId: UUID
    public var usdzFileName: String
    public var floorplanPNGFileName: String?
    /// User-entered label (e.g. "Living Room"). Optional for backwards compatibility
    /// with scans saved before naming was added.
    public var name: String?
    public var measurements: [Measurement]
    public var capturedAt: Date

    public init(id: UUID = UUID(), versionId: UUID, usdzFileName: String, floorplanPNGFileName: String? = nil, name: String? = nil, measurements: [Measurement] = [], capturedAt: Date = Date()) {
        self.id = id
        self.versionId = versionId
        self.usdzFileName = usdzFileName
        self.floorplanPNGFileName = floorplanPNGFileName
        self.name = name
        self.measurements = measurements
        self.capturedAt = capturedAt
    }

    /// Label to show in UI / reports. Falls back to the USDZ filename for legacy scans.
    public var displayName: String {
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            return n
        }
        return usdzFileName
    }
}

/// Normalized measurement from a scan (length, area, etc.).
public struct Measurement: Codable, Equatable {
    public var id: UUID
    public var type: String
    public var value: Double
    public var unit: String
    public var label: String?

    public init(id: UUID = UUID(), type: String, value: Double, unit: String, label: String? = nil) {
        self.id = id
        self.type = type
        self.value = value
        self.unit = unit
        self.label = label
    }
}
