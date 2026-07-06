//
//  LiDARScanMeasurements.swift
//  NexGenSpec
//
//  RoomPlan adapter: extracts geometry from a CapturedRoom and feeds the
//  pure math in LiDARMeasurementMath. Also derives a fallback scan name
//  from RoomPlan's room classification.
//

import Foundation
import simd

#if canImport(RoomPlan)
import RoomPlan

@available(iOS 17.0, *)
enum LiDARScanMeasurements {

    /// Compute room measurements from a processed CapturedRoom. Units: feet /
    /// square feet — matches the floorplan PNG labels (FloorplanRenderer).
    static func compute(from room: CapturedRoom) -> [Measurement] {
        var measurements: [Measurement] = []

        // Same XZ projection as FloorplanRenderer.lineSegment(from:)
        let wallSegments: [LiDARMeasurementMath.Segment] = room.walls.map { surface in
            let m = surface.transform
            let center = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            let dirX = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
            let halfLen = surface.dimensions.x * 0.5
            let p0 = center - dirX * halfLen
            let p1 = center + dirX * halfLen
            return LiDARMeasurementMath.Segment(
                start: SIMD2<Double>(Double(p0.x), Double(p0.z)),
                end: SIMD2<Double>(Double(p1.x), Double(p1.z))
            )
        }
        if let extent = LiDARMeasurementMath.roomExtentFeet(wallSegments: wallSegments) {
            measurements.append(Measurement(type: Measurement.Kind.roomLength, value: extent.length, unit: Measurement.Unit.feet, label: "Room length"))
            measurements.append(Measurement(type: Measurement.Kind.roomWidth, value: extent.width, unit: Measurement.Unit.feet, label: "Room width"))
        }

        let wallHeights = room.walls.map { Double($0.dimensions.y) }
        if let ceiling = LiDARMeasurementMath.maxCeilingHeightFeet(wallHeightsMeters: wallHeights) {
            measurements.append(Measurement(type: Measurement.Kind.ceilingHeight, value: ceiling, unit: Measurement.Unit.feet, label: "Ceiling height"))
        }

        var totalArea = 0.0
        for surface in room.floors {
            if surface.polygonCorners.count >= 3 {
                // Polygon corners are surface-local; transform into world space
                // and project onto XZ (more accurate for non-rectangular rooms).
                let corners = surface.polygonCorners.map { corner -> SIMD2<Double> in
                    let p4 = surface.transform * SIMD4<Float>(corner, 1)
                    return SIMD2<Double>(Double(p4.x), Double(p4.z))
                }
                totalArea += LiDARMeasurementMath.polygonAreaSquareFeet(cornersMeters: corners) ?? 0
            } else {
                totalArea += LiDARMeasurementMath.rectAreaSquareFeet(
                    widthMeters: Double(surface.dimensions.x),
                    depthMeters: Double(surface.dimensions.z)
                )
            }
        }
        if totalArea > 0 {
            measurements.append(Measurement(type: Measurement.Kind.floorArea, value: totalArea, unit: Measurement.Unit.squareFeet, label: "Floor area"))
        }

        return measurements
    }

    /// Fallback scan name derived from RoomPlan's detected room sections
    /// (e.g. "Living Room"). nil when RoomPlan couldn't classify the room.
    static func autoName(from room: CapturedRoom) -> String? {
        for section in room.sections {
            switch section.label {
            case .bathroom: return "Bathroom"
            case .bedroom: return "Bedroom"
            case .diningRoom: return "Dining Room"
            case .kitchen: return "Kitchen"
            case .livingRoom: return "Living Room"
            case .unidentified: continue
            @unknown default: continue
            }
        }
        return nil
    }
}

#endif
