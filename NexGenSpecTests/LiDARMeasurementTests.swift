//
//  LiDARMeasurementTests.swift
//  NexGenSpecTests
//
//  Covers LiDARMeasurementMath (pure geometry), LiDARScan.measurementsSummary
//  formatting, and LiDARScan Codable backward compatibility.
//

import XCTest
import simd
@testable import NexGenSpec

final class LiDARMeasurementTests: XCTestCase {

    // MARK: - LiDARMeasurementMath

    func testRoomExtentFeet_rectangularRoom() throws {
        // 4 m x 3 m rectangle on the XZ plane.
        let segments: [LiDARMeasurementMath.Segment] = [
            .init(start: SIMD2(0, 0), end: SIMD2(4, 0)),
            .init(start: SIMD2(4, 0), end: SIMD2(4, 3)),
            .init(start: SIMD2(4, 3), end: SIMD2(0, 3)),
            .init(start: SIMD2(0, 3), end: SIMD2(0, 0))
        ]
        let extent = try XCTUnwrap(LiDARMeasurementMath.roomExtentFeet(wallSegments: segments))
        XCTAssertEqual(extent.length, 4 * 3.28084, accuracy: 0.001)
        XCTAssertEqual(extent.width, 3 * 3.28084, accuracy: 0.001)
    }

    func testRoomExtentFeet_empty_returnsNil() {
        XCTAssertNil(LiDARMeasurementMath.roomExtentFeet(wallSegments: []))
    }

    func testMaxCeilingHeightFeet() throws {
        let feet = try XCTUnwrap(LiDARMeasurementMath.maxCeilingHeightFeet(wallHeightsMeters: [2.4, 2.7, 2.55]))
        XCTAssertEqual(feet, 2.7 * 3.28084, accuracy: 0.001)
        XCTAssertNil(LiDARMeasurementMath.maxCeilingHeightFeet(wallHeightsMeters: []))
    }

    func testPolygonAreaSquareFeet_unitSquare() throws {
        let corners: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        let area = try XCTUnwrap(LiDARMeasurementMath.polygonAreaSquareFeet(cornersMeters: corners))
        XCTAssertEqual(area, 10.7639, accuracy: 0.001)

        // Reversed winding — abs makes area winding-independent.
        let reversed = try XCTUnwrap(LiDARMeasurementMath.polygonAreaSquareFeet(cornersMeters: corners.reversed()))
        XCTAssertEqual(reversed, 10.7639, accuracy: 0.001)

        XCTAssertNil(LiDARMeasurementMath.polygonAreaSquareFeet(cornersMeters: [SIMD2(0, 0), SIMD2(1, 0)]))
    }

    func testPolygonAreaSquareFeet_LShape() throws {
        // L-shape = 10 m² (4x2 bottom + 2x1 upper-left) — proves polygon
        // beats bounding rect (4 x 3 = 12 m²).
        let corners: [SIMD2<Double>] = [
            SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 2), SIMD2(2, 2), SIMD2(2, 3), SIMD2(0, 3)
        ]
        let area = try XCTUnwrap(LiDARMeasurementMath.polygonAreaSquareFeet(cornersMeters: corners))
        XCTAssertEqual(area, 10 * 10.7639, accuracy: 0.01)
    }

    func testRectAreaSquareFeet() {
        XCTAssertEqual(LiDARMeasurementMath.rectAreaSquareFeet(widthMeters: 4, depthMeters: 3), 12 * 10.7639, accuracy: 0.001)
    }

    // MARK: - measurementsSummary

    func testMeasurementsSummary_full() {
        let scan = LiDARScan(
            versionId: UUID(),
            usdzFileName: "a.usdz",
            measurements: [
                Measurement(type: Measurement.Kind.roomLength, value: 13.1, unit: Measurement.Unit.feet),
                Measurement(type: Measurement.Kind.roomWidth, value: 9.8, unit: Measurement.Unit.feet),
                Measurement(type: Measurement.Kind.ceilingHeight, value: 8.9, unit: Measurement.Unit.feet),
                Measurement(type: Measurement.Kind.floorArea, value: 128.9, unit: Measurement.Unit.squareFeet)
            ]
        )
        XCTAssertEqual(scan.measurementsSummary, "13.1 ft × 9.8 ft · 8.9 ft ceiling · ~129 sq ft")
    }

    func testMeasurementsSummary_legacyEmpty_returnsNil() {
        let scan = LiDARScan(versionId: UUID(), usdzFileName: "a.usdz", measurements: [])
        XCTAssertNil(scan.measurementsSummary)
    }

    func testMeasurementsSummary_partial() {
        let scan = LiDARScan(
            versionId: UUID(),
            usdzFileName: "a.usdz",
            measurements: [Measurement(type: Measurement.Kind.ceilingHeight, value: 8.0, unit: Measurement.Unit.feet)]
        )
        XCTAssertEqual(scan.measurementsSummary, "8.0 ft ceiling")
    }

    // MARK: - Codable backward compatibility

    func testLegacyScanJSONDecodes() throws {
        // Legacy on-disk record (pre roomJSONFileName/sectionId). Plain
        // JSONDecoder matches LiDARScanStore (default .deferredToDate).
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","versionId":"22222222-2222-2222-2222-222222222222","usdzFileName":"a.usdz","measurements":[],"capturedAt":700000000}
        """
        let scan = try JSONDecoder().decode(LiDARScan.self, from: Data(json.utf8))
        XCTAssertNil(scan.roomJSONFileName)
        XCTAssertNil(scan.sectionId)
        XCTAssertNil(scan.floorplanPNGFileName)
        XCTAssertNil(scan.name)
    }

    func testNewFieldsRoundTrip() throws {
        let scan = LiDARScan(
            versionId: UUID(),
            usdzFileName: "b.usdz",
            floorplanPNGFileName: "b_floorplan.png",
            roomJSONFileName: "b_room.json",
            name: "Kitchen",
            sectionId: UUID(),
            measurements: [
                Measurement(type: Measurement.Kind.roomLength, value: 12.4, unit: Measurement.Unit.feet, label: "Room length"),
                Measurement(type: Measurement.Kind.floorArea, value: 126.2, unit: Measurement.Unit.squareFeet, label: "Floor area")
            ]
        )
        let data = try JSONEncoder().encode(scan)
        let decoded = try JSONDecoder().decode(LiDARScan.self, from: data)
        XCTAssertEqual(decoded, scan)
    }
}
