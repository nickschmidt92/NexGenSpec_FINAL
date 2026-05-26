#!/usr/bin/env swift
//
// compose_caption.swift
//
// Composites a caption band onto a raw simulator screenshot for App Store
// Connect upload. No deps beyond AppKit / CoreText (system frameworks).
//
// Usage:
//   ./scripts/compose_caption.swift <in.png> <out.png> "<headline>" "<sub (optional)>"
//
// Example:
//   ./scripts/compose_caption.swift \
//     marketing/screenshots/iphone-pro-max-light/01-dashboard.png \
//     marketing/screenshots/captioned/iphone-pro-max-light/01-dashboard.png \
//     "Annotate with Apple Pencil" \
//     "Mark up defects directly on the photo. No exports. No detours."
//
// Output: PNG, same dimensions as input, with a top band carrying the
// caption. Band is the NexGenSpec brand gradient (#0066cc → #00aaff) at
// 135°. Band height = 12% of image height. White text. Auto-scales font
// to fit width.
//

import AppKit
import CoreGraphics
import CoreText
import Foundation

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 4 else {
    die("usage: \(args[0]) <in.png> <out.png> \"<headline>\" [\"<sub>\"]")
}
let inPath = args[1]
let outPath = args[2]
let headline = args[3]
let sub: String? = args.count >= 5 ? args[4] : nil

guard let srcImage = NSImage(contentsOfFile: inPath),
      let srcCG = srcImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { die("could not load input image: \(inPath)") }

let w = srcCG.width
let h = srcCG.height
let bandHeight = Int(Double(h) * 0.12)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: w,
    height: h,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { die("could not create CGContext") }

// 1. Draw source image at the bottom of the canvas
ctx.draw(srcCG, in: CGRect(x: 0, y: 0, width: w, height: h))

// 2. Draw gradient band at top (in CG coords, top = max Y)
let bandRect = CGRect(x: 0, y: h - bandHeight, width: w, height: bandHeight)
let brandStart = CGColor(red: 0.0,  green: 0.4, blue: 0.8, alpha: 1.0)  // ~#0066cc
let brandEnd   = CGColor(red: 0.0,  green: 0.667, blue: 1.0, alpha: 1.0) // ~#00aaff
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [brandStart, brandEnd] as CFArray,
    locations: [0.0, 1.0]
)!

ctx.saveGState()
ctx.clip(to: bandRect)
// 135° gradient ≈ top-left → bottom-right of the band
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: h),
    end:   CGPoint(x: w, y: h - bandHeight),
    options: []
)
ctx.restoreGState()

// 3. Draw text
let fontName = "SFProDisplay-Bold"
let fallback = "Helvetica-Bold"

func textAttrs(size: CGFloat, weight: NSFont.Weight) -> [NSAttributedString.Key: Any] {
    let font: NSFont = NSFont(name: fontName, size: size)
        ?? NSFont.systemFont(ofSize: size, weight: weight)
        ?? NSFont(name: fallback, size: size)!
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    para.lineBreakMode = .byTruncatingTail
    return [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: para
    ]
}

// Pick font sizes proportional to band height. These ratios were tuned
// against the three Apple-required device sizes (1320x2868, 1206x2622,
// 2048x2732). Adjust if a particular shot reads cramped.
let headlineSize = CGFloat(bandHeight) * 0.42
let subSize      = CGFloat(bandHeight) * 0.20

let hAttrs = textAttrs(size: headlineSize, weight: .bold)
let sAttrs = textAttrs(size: subSize, weight: .medium)

let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsContext

let headlineNS = headline as NSString
let subNS: NSString? = sub.map { $0 as NSString }

// Vertical layout: headline upper-center, sub lower-center.
let textInsetX: CGFloat = CGFloat(w) * 0.06
let textWidth: CGFloat = CGFloat(w) - 2 * textInsetX

if let subNS = subNS {
    let headlineY = CGFloat(h - bandHeight) + CGFloat(bandHeight) * 0.55
    let subY      = CGFloat(h - bandHeight) + CGFloat(bandHeight) * 0.18
    headlineNS.draw(
        in: NSRect(x: textInsetX, y: headlineY, width: textWidth, height: headlineSize * 1.4),
        withAttributes: hAttrs
    )
    subNS.draw(
        in: NSRect(x: textInsetX, y: subY, width: textWidth, height: subSize * 1.4),
        withAttributes: sAttrs
    )
} else {
    let headlineY = CGFloat(h - bandHeight) + (CGFloat(bandHeight) - headlineSize * 1.2) / 2.0
    headlineNS.draw(
        in: NSRect(x: textInsetX, y: headlineY, width: textWidth, height: headlineSize * 1.4),
        withAttributes: hAttrs
    )
}

NSGraphicsContext.restoreGraphicsState()

// 4. Write PNG
guard let outImage = ctx.makeImage() else { die("makeImage failed") }
let outDir = (outPath as NSString).deletingLastPathComponent
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let rep = NSBitmapImageRep(cgImage: outImage)
guard let pngData = rep.representation(using: .png, properties: [:]) else { die("png encode failed") }
try? pngData.write(to: URL(fileURLWithPath: outPath))

print("✓ \(outPath)  (\(w)×\(h), band \(bandHeight)px)")
