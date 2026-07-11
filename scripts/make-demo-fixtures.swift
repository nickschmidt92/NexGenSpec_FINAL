#!/usr/bin/env swift
//
//  make-demo-fixtures.swift
//  Regenerates the two non-photo screenshot fixtures in marketing/screenshot-assets/:
//    summit-logo.png        — neutral "Summit Home Inspections" logo for demo branding
//    living-room-scan.usdz  — plain white room mesh in the style of a RoomPlan export,
//                             15.2 ft × 13.1 ft × 8.0 ft (matches the seeded LiDARScan
//                             measurements in DemoModeFixture).
//  Run from the repo root:  swift scripts/make-demo-fixtures.swift
//

import AppKit
import SceneKit

let assetsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("marketing/screenshot-assets")

// MARK: - Summit logo -------------------------------------------------------

func makeLogo() {
    let size = NSSize(width: 512, height: 512)
    let image = NSImage(size: size)
    image.lockFocus()

    let navy = NSColor(calibratedRed: 0.11, green: 0.17, blue: 0.29, alpha: 1)
    let slate = NSColor(calibratedRed: 0.33, green: 0.42, blue: 0.55, alpha: 1)
    let teal = NSColor(calibratedRed: 0.15, green: 0.62, blue: 0.64, alpha: 1)

    // Back peak (slate)
    let back = NSBezierPath()
    back.move(to: NSPoint(x: 96, y: 208))
    back.line(to: NSPoint(x: 236, y: 420))
    back.line(to: NSPoint(x: 376, y: 208))
    back.close()
    slate.setFill()
    back.fill()

    // Front peak (navy)
    let front = NSBezierPath()
    front.move(to: NSPoint(x: 176, y: 208))
    front.line(to: NSPoint(x: 320, y: 404))
    front.line(to: NSPoint(x: 464, y: 208))
    front.close()
    navy.setFill()
    front.fill()

    // Snow cap on the front peak (teal accent)
    let cap = NSBezierPath()
    cap.move(to: NSPoint(x: 282, y: 352))
    cap.line(to: NSPoint(x: 320, y: 404))
    cap.line(to: NSPoint(x: 358, y: 352))
    cap.line(to: NSPoint(x: 338, y: 352))
    cap.line(to: NSPoint(x: 320, y: 374))
    cap.line(to: NSPoint(x: 302, y: 352))
    cap.close()
    teal.setFill()
    cap.fill()

    // Baseline rule
    navy.setFill()
    NSRect(x: 96, y: 196, width: 368, height: 8).fill()

    // Wordmark
    let title = NSAttributedString(
        string: "SUMMIT",
        attributes: [
            .font: NSFont.systemFont(ofSize: 78, weight: .heavy),
            .foregroundColor: navy,
            .kern: 6,
        ])
    let titleSize = title.size()
    title.draw(at: NSPoint(x: (size.width - titleSize.width) / 2, y: 106))

    let sub = NSAttributedString(
        string: "HOME INSPECTIONS",
        attributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .semibold),
            .foregroundColor: slate,
            .kern: 7.5,
        ])
    let subSize = sub.size()
    sub.draw(at: NSPoint(x: (size.width - subSize.width) / 2, y: 62))

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { fatalError("logo render failed") }
    let out = assetsDir.appendingPathComponent("summit-logo.png")
    try! png.write(to: out)
    print("wrote \(out.path) (\(png.count) bytes)")
}

// MARK: - Living-room USDZ --------------------------------------------------

// Room interior: 4.633 m × 3.993 m (15.2 ft × 13.1 ft), 2.438 m (8.0 ft) ceiling.
// RoomPlan exports untextured light-gray parametric surfaces; mimic that look.

func makeRoom() {
    let scene = SCNScene()
    let root = scene.rootNode

    let wallMat = SCNMaterial()
    wallMat.diffuse.contents = NSColor(calibratedWhite: 0.92, alpha: 1)
    wallMat.lightingModel = .physicallyBased
    wallMat.roughness.contents = 0.9

    let floorMat = SCNMaterial()
    floorMat.diffuse.contents = NSColor(calibratedWhite: 0.82, alpha: 1)
    floorMat.lightingModel = .physicallyBased
    floorMat.roughness.contents = 0.9

    let furnMat = SCNMaterial()
    furnMat.diffuse.contents = NSColor(calibratedWhite: 0.7, alpha: 1)
    furnMat.lightingModel = .physicallyBased
    furnMat.roughness.contents = 0.85

    let W: CGFloat = 4.633   // x
    let D: CGFloat = 3.993   // z
    let H: CGFloat = 2.438   // y
    let T: CGFloat = 0.09    // wall thickness

    func box(_ w: CGFloat, _ h: CGFloat, _ d: CGFloat, _ x: CGFloat, _ y: CGFloat, _ z: CGFloat, _ mat: SCNMaterial) {
        let g = SCNBox(width: w, height: h, length: d, chamferRadius: 0.005)
        g.materials = [mat]
        let n = SCNNode(geometry: g)
        n.position = SCNVector3(x, y, z)
        root.addChildNode(n)
    }

    // Floor slab
    box(W + T, 0.06, D + T, 0, -0.03, 0, floorMat)

    // North wall (full)
    box(W + T, H, T, 0, H / 2, -D / 2, wallMat)
    // East wall (full)
    box(T, H, D + T, W / 2, H / 2, 0, wallMat)
    // West wall (full)
    box(T, H, D + T, -W / 2, H / 2, 0, wallMat)
    // South wall with a 0.91 m door gap, offset right of center
    // Segments: [-W/2 .. 0.6] and [1.51 .. W/2]
    let gapL: CGFloat = 0.6, gapR: CGFloat = 1.51
    let segAw = gapL - (-W / 2)
    box(segAw, H, T, (-W / 2 + gapL) / 2, H / 2, D / 2, wallMat)
    let segBw = W / 2 - gapR
    box(segBw, H, T, (gapR + W / 2) / 2, H / 2, D / 2, wallMat)
    // Header above the door gap
    box(gapR - gapL, H - 2.03, T, (gapL + gapR) / 2, 2.03 + (H - 2.03) / 2, D / 2, wallMat)

    // Furniture, RoomPlan-box style:
    // Sofa along the west wall
    box(0.85, 0.75, 1.9, -W / 2 + 0.55, 0.375, -0.2, furnMat)
    // Coffee table
    box(0.6, 0.42, 1.1, -0.55, 0.21, -0.2, furnMat)
    // Media console along the east wall
    box(0.45, 0.55, 1.6, W / 2 - 0.35, 0.275, -0.3, furnMat)
    // TV panel on the east wall
    box(0.06, 0.75, 1.3, W / 2 - 0.12, 1.3, -0.3, furnMat)
    // Side chair near the south-west corner
    box(0.7, 0.8, 0.7, -W / 2 + 0.6, 0.4, D / 2 - 0.75, furnMat)

    let out = assetsDir.appendingPathComponent("living-room-scan.usdz")
    try? FileManager.default.removeItem(at: out)
    let ok = scene.write(to: out, options: nil, delegate: nil, progressHandler: nil)
    guard ok else { fatalError("usdz export failed") }
    let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
    print("wrote \(out.path) (\(bytes) bytes)")
}

makeLogo()
makeRoom()
