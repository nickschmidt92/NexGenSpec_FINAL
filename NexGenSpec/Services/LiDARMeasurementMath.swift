//
//  LiDARMeasurementMath.swift
//  NexGenSpec
//
//  Pure geometry math for scan measurements. Separated from RoomPlan so it is
//  unit-testable: CapturedRoom has no public initializer.
//

import Foundation
import simd

enum LiDARMeasurementMath {
    static let feetPerMeter = 3.28084
    static let squareFeetPerSquareMeter = 10.7639

    /// A wall endpoint pair on the XZ plane, meters. (Same projection as
    /// FloorplanRenderer.lineSegment.) Component `y` holds the Z coordinate.
    struct Segment: Equatable {
        var start: SIMD2<Double>   // (x, z)
        var end: SIMD2<Double>
    }

    /// Bounding box of all wall endpoints on the XZ plane, in FEET.
    /// length = larger extent, width = smaller. nil when no segments.
    static func roomExtentFeet(wallSegments: [Segment]) -> (length: Double, width: Double)? {
        let points = wallSegments.flatMap { [$0.start, $0.end] }
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minZ = points.map(\.y).min(),
              let maxZ = points.map(\.y).max()
        else { return nil }
        let extentA = (maxX - minX) * feetPerMeter
        let extentB = (maxZ - minZ) * feetPerMeter
        return (length: max(extentA, extentB), width: min(extentA, extentB))
    }

    /// Max wall height in FEET. nil when input is empty.
    static func maxCeilingHeightFeet(wallHeightsMeters: [Double]) -> Double? {
        guard let maxMeters = wallHeightsMeters.max() else { return nil }
        return maxMeters * feetPerMeter
    }

    /// Shoelace area of one floor polygon (XZ corners, meters) in SQUARE FEET.
    /// nil when fewer than 3 corners. Returns abs value (winding-independent).
    static func polygonAreaSquareFeet(cornersMeters: [SIMD2<Double>]) -> Double? {
        guard cornersMeters.count >= 3 else { return nil }
        var sum = 0.0
        for i in cornersMeters.indices {
            let p = cornersMeters[i]
            let q = cornersMeters[(i + 1) % cornersMeters.count]
            sum += p.x * q.y - q.x * p.y
        }
        return 0.5 * abs(sum) * squareFeetPerSquareMeter
    }

    /// Fallback rectangular floor area (dimensions.x * dimensions.z) in SQ FT.
    static func rectAreaSquareFeet(widthMeters: Double, depthMeters: Double) -> Double {
        widthMeters * depthMeters * squareFeetPerSquareMeter
    }
}
