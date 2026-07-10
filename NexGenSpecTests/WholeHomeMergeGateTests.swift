//
//  WholeHomeMergeGateTests.swift
//  NexGenSpecTests
//
//  Covers the whole-home merge coherence gate. A coherent plan must satisfy
//  BOTH halves: no pair of room footprints overlaps beyond the tolerance
//  (misregistered rooms stack through each other), and the footprints form
//  one connected component under near-adjacency (rooms adrift from the rest
//  mean session origins landed apart — arbitrary wrong arrangements, not a
//  home layout). Build-29 device smoke finding, 2026-07-09.
//

import XCTest
@testable import NexGenSpec

final class WholeHomeMergeGateTests: XCTestCase {

    func testEmptyAndSingleFootprintAreCoherent() {
        XCTAssertTrue(WholeHomeMergeGate.isCoherent(footprints: []))
        XCTAssertTrue(WholeHomeMergeGate.isCoherent(footprints: [CGRect(x: 0, y: 0, width: 4, height: 3)]))
    }

    func testAdjacentRoomsAreCoherent() {
        // Three rooms with small (< maxNeighborGap) gaps — a normal layout.
        let kitchen = CGRect(x: 0, y: 0, width: 4, height: 3)
        let living = CGRect(x: 4.2, y: 0, width: 5, height: 4)
        let bedroom = CGRect(x: 0, y: 3.3, width: 4, height: 4)
        XCTAssertTrue(WholeHomeMergeGate.isCoherent(footprints: [kitchen, living, bedroom]))
    }

    func testSharedWallSliverIsCoherent() {
        // Adjacent rooms overlapping by ~0.15 m of wall thickness:
        // 0.15 × 3 = 0.45 m² against a 12 m² smaller room = 3.75%.
        let a = CGRect(x: 0, y: 0, width: 4, height: 3)
        let b = CGRect(x: 3.85, y: 0, width: 5, height: 3)
        XCTAssertTrue(WholeHomeMergeGate.isCoherent(footprints: [a, b]))
    }

    func testHeavyOverlapIsIncoherent() {
        // Half of the smaller room inside the bigger one.
        let a = CGRect(x: 0, y: 0, width: 4, height: 3)
        let b = CGRect(x: 2, y: 0, width: 6, height: 5)
        XCTAssertFalse(WholeHomeMergeGate.isCoherent(footprints: [a, b]))
    }

    func testDuplicateRoomStackedIsIncoherent() {
        // Same physical room scanned twice, landing on the same spot.
        let scan1 = CGRect(x: 0, y: 0, width: 4, height: 3)
        let scan2 = CGRect(x: 0.1, y: -0.1, width: 4, height: 3)
        XCTAssertFalse(WholeHomeMergeGate.isCoherent(footprints: [scan1, scan2]))
    }

    func testCrossSessionOriginClusterIsIncoherent() {
        // Cross-session frames: every room centered near its own session
        // origin, so all footprints pile around (0,0) at various extents —
        // the crisscross case from the smoke.
        let rooms = [
            CGRect(x: -2, y: -1.5, width: 4, height: 3),
            CGRect(x: -2.5, y: -2, width: 5, height: 4),
            CGRect(x: -1.5, y: -2.5, width: 3, height: 5),
            CGRect(x: -3, y: -1, width: 6, height: 2.5),
        ]
        XCTAssertFalse(WholeHomeMergeGate.isCoherent(footprints: rooms))
    }

    func testDisjointIslandsAreIncoherent() {
        // Non-overlapping is not enough: session origins that landed apart
        // produce rooms scattered in arbitrary wrong arrangements. Two rooms
        // metres from each other are not one home plan.
        let a = CGRect(x: 0, y: 0, width: 4, height: 3)
        let b = CGRect(x: 9, y: 7, width: 5, height: 4)
        XCTAssertFalse(WholeHomeMergeGate.isCoherent(footprints: [a, b]))

        // Two internally-connected clusters that are islands to each other
        // must also fail (connectivity is transitive, not per-room).
        let c = CGRect(x: 0, y: 0, width: 4, height: 3)
        let d = CGRect(x: 4.2, y: 0, width: 4, height: 3)
        let e = CGRect(x: 20, y: 20, width: 4, height: 3)
        let f = CGRect(x: 24.2, y: 20, width: 4, height: 3)
        XCTAssertFalse(WholeHomeMergeGate.isCoherent(footprints: [c, d, e, f]))
    }

    func testNeighborGapBoundary() {
        // Gap 0.4 m (< 0.5 tolerance) connects; gap 0.6 m does not.
        let base = CGRect(x: 0, y: 0, width: 4, height: 3)
        let near = CGRect(x: 4.4, y: 0, width: 4, height: 3)
        XCTAssertTrue(WholeHomeMergeGate.isCoherent(footprints: [base, near]))
        let far = CGRect(x: 4.6, y: 0, width: 4, height: 3)
        XCTAssertFalse(WholeHomeMergeGate.isCoherent(footprints: [base, far]))
    }

    func testOverlapThresholdBoundary() {
        // Overlap exactly at the 25% tolerance passes (gate uses strictly
        // greater-than); just past it fails. Overlapping rooms are connected.
        let base = CGRect(x: 0, y: 0, width: 4, height: 3)        // 12 m²
        let atLimit = CGRect(x: 3, y: 0, width: 4, height: 3)     // 1×3 = 3 m² = 25%
        XCTAssertTrue(WholeHomeMergeGate.isCoherent(footprints: [base, atLimit]))
        let pastLimit = CGRect(x: 2.8, y: 0, width: 4, height: 3) // 1.2×3 = 3.6 m² = 30%
        XCTAssertFalse(WholeHomeMergeGate.isCoherent(footprints: [base, pastLimit]))
    }

    func testZeroAreaFootprintIsIgnored() {
        // A degenerate (zero-area) footprint can't overlap or anchor
        // adjacency — it must neither trip the gate nor break connectivity.
        let a = CGRect(x: 0, y: 0, width: 4, height: 3)
        let degenerate = CGRect(x: 1, y: 1, width: 0, height: 2)
        XCTAssertTrue(WholeHomeMergeGate.isCoherent(footprints: [a, degenerate]))
        let b = CGRect(x: 4.2, y: 0, width: 4, height: 3)
        XCTAssertTrue(WholeHomeMergeGate.isCoherent(footprints: [a, degenerate, b]))
    }
}
