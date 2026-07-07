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
    /// Full CapturedRoom encoded as JSON alongside the USDZ. Optional for
    /// backwards compatibility; enables whole-home merging (StructureBuilder).
    public var roomJSONFileName: String?
    /// User-entered label (e.g. "Living Room"). Optional for backwards compatibility
    /// with scans saved before naming was added.
    public var name: String?
    /// InspectionSection.id this scan is linked to (report placement).
    /// Section ids are deterministic per inspection (StableUUID), so the link
    /// is stable across revisions and survives cross-device sync.
    public var sectionId: UUID?
    public var measurements: [Measurement]
    public var capturedAt: Date

    public init(id: UUID = UUID(), versionId: UUID, usdzFileName: String, floorplanPNGFileName: String? = nil, roomJSONFileName: String? = nil, name: String? = nil, sectionId: UUID? = nil, measurements: [Measurement] = [], capturedAt: Date = Date()) {
        self.id = id
        self.versionId = versionId
        self.usdzFileName = usdzFileName
        self.floorplanPNGFileName = floorplanPNGFileName
        self.roomJSONFileName = roomJSONFileName
        self.name = name
        self.sectionId = sectionId
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

    /// One-line dimensions summary, e.g. "12.4 ft × 10.2 ft · 8.0 ft ceiling · ~126 sq ft".
    /// nil when no recognized measurements exist (legacy scans). Partial data
    /// renders whichever components are available, joined by " · ".
    public var measurementsSummary: String? {
        func value(_ kind: String) -> Double? {
            measurements.first(where: { $0.type == kind })?.value
        }
        var parts: [String] = []
        if let l = value(Measurement.Kind.roomLength), let w = value(Measurement.Kind.roomWidth) {
            parts.append(String(format: "%.1f ft × %.1f ft", l, w))
        }
        if let c = value(Measurement.Kind.ceilingHeight) {
            parts.append(String(format: "%.1f ft ceiling", c))
        }
        if let a = value(Measurement.Kind.floorArea) {
            parts.append("~\(Int(a.rounded())) sq ft")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

public extension Measurement {
    /// Stable `type` strings for scan-derived measurements.
    enum Kind {
        public static let roomWidth = "room_width"       // feet
        public static let roomLength = "room_length"     // feet
        public static let ceilingHeight = "ceiling_height" // feet
        public static let floorArea = "floor_area"       // square feet
    }
    enum Unit {
        public static let feet = "ft"
        public static let squareFeet = "sq_ft"
    }
}
