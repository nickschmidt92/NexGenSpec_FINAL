//
//  WholeHomeMergeGate.swift
//  NexGenSpec
//
//  Coherence gate for the merged whole-home floor plan. Each room scan is
//  captured in its own AR session with an arbitrary origin and yaw, but
//  StructureBuilder assumes all input rooms share one coordinate space — so a
//  merge can "succeed" while placing rooms through each other (build-29 device
//  smoke, 2026-07-09). Rooms whose XZ wall footprints overlap heavily are
//  geometrically incoherent; the service then skips caching so the report
//  omits the whole-home page instead of shipping crisscross walls to a client.
//  The proper fix (v1.1) is session continuity / relocalization at capture
//  time so the shared-space precondition actually holds.
//

import Foundation
import CoreGraphics

// TODO(v1.1): this AABB heuristic is a 1.0 stopgap and must NOT survive into
// the v1.1 multi-room capture work unchanged. Once capture-time relocalization
// makes the shared-space precondition real, correctly registered plans with
// L/U-shaped rooms (whose bounding boxes legitimately contain neighbors) and
// stacked multi-story rooms (XZ-only footprints) would be wrongly suppressed
// by this gate — replace it with polygon-level checks or drop it entirely.
enum WholeHomeMergeGate {

    /// Max tolerated pairwise overlap as a fraction of the smaller room's
    /// footprint area. Adjacent rooms legitimately overlap by wall thickness
    /// and door reveals (thin slivers); misregistered rooms overlap massively.
    static let maxOverlapFraction: CGFloat = 0.25

    /// Max gap (meters) between a room and its nearest neighbor for the set
    /// to read as one connected home. Rooms adrift from the rest mean the
    /// session origins landed apart — wrong relative placement, not layout.
    static let maxNeighborGap: CGFloat = 0.5

    /// True when no pair of footprints overlaps beyond the tolerance AND the
    /// footprints form one connected component under near-adjacency. Both
    /// halves matter: heavy overlap = rooms stacked through each other;
    /// disjoint islands = rooms scattered in arbitrary wrong arrangements.
    /// Fewer than two footprints is trivially coherent.
    static func isCoherent(footprints: [CGRect]) -> Bool {
        // Zero-area footprints (a room reduced to collinear walls) can't
        // meaningfully overlap or anchor adjacency — ignore them for gating.
        let solid = footprints.filter { $0.width > 0 && $0.height > 0 }
        guard solid.count >= 2 else { return true }
        for i in 0..<(solid.count - 1) {
            for j in (i + 1)..<solid.count {
                let inter = solid[i].intersection(solid[j])
                guard !inter.isNull, !inter.isEmpty else { continue }
                let smaller = min(area(solid[i]), area(solid[j]))
                guard smaller > 0 else { continue }
                if area(inter) / smaller > maxOverlapFraction { return false }
            }
        }
        // Connectivity: BFS over near-adjacency (expanded-rect intersection).
        var visited: Set<Int> = [0]
        var queue = [0]
        while let i = queue.popLast() {
            let reach = solid[i].insetBy(dx: -maxNeighborGap, dy: -maxNeighborGap)
            for j in solid.indices where !visited.contains(j) && reach.intersects(solid[j]) {
                visited.insert(j)
                queue.append(j)
            }
        }
        return visited.count == solid.count
    }

    private static func area(_ r: CGRect) -> CGFloat { r.width * r.height }
}
