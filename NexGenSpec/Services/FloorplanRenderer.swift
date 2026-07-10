//
//  FloorplanRenderer.swift
//  NexGenSpec
//
//  Renders a top-down 2D floor plan PNG from a RoomPlan CapturedRoom.
//  Walls = black lines, doors = orange gaps, windows = cyan segments,
//  openings = dashed gray. Wall lengths are labeled in feet.
//

import Foundation
import UIKit
import simd

#if canImport(RoomPlan)
import RoomPlan

@available(iOS 16.0, *)
enum FloorplanRenderer {

    /// Render a top-down floor plan PNG of the captured room.
    /// Returns the PNG data, or nil if the room had no walls.
    static func renderPNG(
        from room: CapturedRoom,
        size: CGSize = CGSize(width: 1600, height: 1200),
        margin: CGFloat = 80
    ) -> Data? {
        renderPNG(from: [room], size: size, margin: margin)
    }

    /// Render a combined top-down floor plan from one or more rooms whose
    /// surface transforms share a coordinate space (a single CapturedRoom, or
    /// CapturedStructure.rooms after a StructureBuilder merge).
    static func renderPNG(
        from rooms: [CapturedRoom],
        size: CGSize = CGSize(width: 1600, height: 1200),
        margin: CGFloat = 80
    ) -> Data? {
        let wallLines = rooms.flatMap { $0.walls.map(lineSegment(from:)) }
        guard !wallLines.isEmpty else { return nil }

        let doorLines = rooms.flatMap { $0.doors.map(lineSegment(from:)) }
        let windowLines = rooms.flatMap { $0.windows.map(lineSegment(from:)) }
        let openingLines = rooms.flatMap { $0.openings.map(lineSegment(from:)) }

        // Bounding box of everything that will be drawn (XZ plane).
        let allPoints = (wallLines + doorLines + windowLines + openingLines)
            .flatMap { [$0.start, $0.end] }
        guard let minX = allPoints.map(\.x).min(),
              let maxX = allPoints.map(\.x).max(),
              let minY = allPoints.map(\.y).min(),
              let maxY = allPoints.map(\.y).max()
        else { return nil }

        let roomW = max(CGFloat(maxX - minX), 0.01)
        let roomH = max(CGFloat(maxY - minY), 0.01)
        let availW = size.width - margin * 2
        let availH = size.height - margin * 2
        let scale = min(availW / roomW, availH / roomH)
        let offsetX = (size.width - roomW * scale) / 2 - CGFloat(minX) * scale
        let offsetY = (size.height - roomH * scale) / 2 - CGFloat(minY) * scale

        func project(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * scale + offsetX, y: p.y * scale + offsetY)
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let c = ctx.cgContext

            UIColor.white.setFill()
            c.fill(CGRect(origin: .zero, size: size))

            // Walls — thick black lines
            c.setLineCap(.round)
            c.setLineJoin(.round)
            UIColor.black.setStroke()
            c.setLineWidth(5)
            for seg in wallLines {
                c.move(to: project(seg.start))
                c.addLine(to: project(seg.end))
            }
            c.strokePath()

            // Openings — dashed gray
            UIColor(white: 0.55, alpha: 1).setStroke()
            c.setLineWidth(4)
            c.setLineDash(phase: 0, lengths: [10, 8])
            for seg in openingLines {
                c.move(to: project(seg.start))
                c.addLine(to: project(seg.end))
            }
            c.strokePath()
            c.setLineDash(phase: 0, lengths: [])

            // Doors — orange
            UIColor.systemOrange.setStroke()
            c.setLineWidth(7)
            for seg in doorLines {
                c.move(to: project(seg.start))
                c.addLine(to: project(seg.end))
            }
            c.strokePath()

            // Windows — cyan
            UIColor.systemTeal.setStroke()
            c.setLineWidth(7)
            for seg in windowLines {
                c.move(to: project(seg.start))
                c.addLine(to: project(seg.end))
            }
            c.strokePath()

            // Wall length labels (feet)
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: UIColor.darkGray
            ]
            for seg in wallLines {
                let meters = hypot(seg.end.x - seg.start.x, seg.end.y - seg.start.y)
                let feet = Double(meters) * 3.28084
                guard feet >= 0.5 else { continue }
                let label = String(format: "%.1f′", feet)
                let pStart = project(seg.start)
                let pEnd = project(seg.end)
                let mid = CGPoint(x: (pStart.x + pEnd.x) / 2, y: (pStart.y + pEnd.y) / 2)

                // Offset the label slightly perpendicular to the wall so it
                // doesn't sit directly on the line.
                let dx = pEnd.x - pStart.x
                let dy = pEnd.y - pStart.y
                let len = max(hypot(dx, dy), 0.001)
                let nx = -dy / len
                let ny = dx / len
                let offset: CGFloat = 14
                let textPoint = CGPoint(x: mid.x + nx * offset, y: mid.y + ny * offset)

                let attr = NSAttributedString(string: label, attributes: labelAttrs)
                let textSize = attr.size()
                let rect = CGRect(
                    x: textPoint.x - textSize.width / 2,
                    y: textPoint.y - textSize.height / 2,
                    width: textSize.width,
                    height: textSize.height
                )
                // Small white pill behind label for readability.
                UIColor(white: 1, alpha: 0.85).setFill()
                let pill = rect.insetBy(dx: -4, dy: -2)
                UIBezierPath(roundedRect: pill, cornerRadius: 4).fill()
                attr.draw(in: rect)
            }

            // Legend — bottom-left
            drawLegend(in: c, size: size)
        }

        return image.pngData()
    }

    // MARK: - Geometry

    private struct Segment {
        var start: CGPoint  // XZ-plane CGPoint: (x, z)
        var end: CGPoint
    }

    /// Axis-aligned XZ bounding box of the room's wall segments, in the same
    /// plane renderPNG draws. Nil when the room has no walls. Used by the
    /// whole-home coherence gate to detect misregistered (overlapping) rooms.
    static func wallFootprint(of room: CapturedRoom) -> CGRect? {
        let pts = room.walls.map(lineSegment(from:)).flatMap { [$0.start, $0.end] }
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
              let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max()
        else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Extract the two wall endpoints on the XZ plane from a Surface.
    private static func lineSegment(from surface: CapturedRoom.Surface) -> Segment {
        let m = surface.transform
        let center = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let dirX = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let halfLen = surface.dimensions.x * 0.5
        let p0 = center - dirX * halfLen
        let p1 = center + dirX * halfLen
        return Segment(
            start: CGPoint(x: CGFloat(p0.x), y: CGFloat(p0.z)),
            end:   CGPoint(x: CGFloat(p1.x), y: CGFloat(p1.z))
        )
    }

    // MARK: - Legend

    private static func drawLegend(in c: CGContext, size: CGSize) {
        let x: CGFloat = 24
        let y: CGFloat = size.height - 96
        let rowH: CGFloat = 22
        let swatchW: CGFloat = 28

        let items: [(String, UIColor, Bool)] = [
            ("Wall", .black, false),
            ("Door", .systemOrange, false),
            ("Window", .systemTeal, false),
            ("Opening", UIColor(white: 0.55, alpha: 1), true)
        ]
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: UIColor.darkGray
        ]
        for (i, item) in items.enumerated() {
            let rowY = y + CGFloat(i) * rowH
            item.1.setStroke()
            c.setLineWidth(4)
            if item.2 { c.setLineDash(phase: 0, lengths: [6, 4]) }
            c.move(to: CGPoint(x: x, y: rowY + rowH / 2))
            c.addLine(to: CGPoint(x: x + swatchW, y: rowY + rowH / 2))
            c.strokePath()
            c.setLineDash(phase: 0, lengths: [])
            let label = NSAttributedString(string: item.0, attributes: titleAttrs)
            label.draw(at: CGPoint(x: x + swatchW + 8, y: rowY + 2))
        }
    }
}
#endif
