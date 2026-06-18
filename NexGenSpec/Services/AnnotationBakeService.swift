//
//  AnnotationBakeService.swift
//  NexGenSpec
//
//  Composites annotation overlay onto photo for report export. Run on background.
//

import Foundation
import UIKit
import PencilKit

enum AnnotationBakeService {

    /// Max longest-side pixel dimension for any photo embedded in a PDF.
    /// Camera photos default to ~4032×3024 (12 MP). Even at JPEG quality
    /// 0.6 each one was ~1.2 MB. Scaling the longest side to 1600 drops
    /// every photo to ~150-300 KB while staying easily readable on a
    /// printed PDF page (~8 inches at 200 DPI). Beta feedback 2026-04-24:
    /// "main images are still massive."
    private static let maxReportSidePixels: CGFloat = 1000

    /// Returns JPEG data of photo with overlay drawn on top, resized for
    /// report use (long side capped at maxReportSidePixels). If no overlay,
    /// still resizes/recompresses the original to keep the report PDF
    /// reasonable. Returns nil only if the input data fails to decode.
    static func bakedImageData(jobId: UUID, photo: InspectionPhoto, photoData: Data?) -> Data? {
        guard let photoData = photoData, let base = UIImage(data: photoData) else { return photoData }
        let overlay = AnnotationStore.load(jobId: jobId, photoId: photo.id)
        let withOverlay = overlay.map { composite(overlay: $0, onto: base) } ?? base
        let resized = resizeForReport(withOverlay)
        return resized.jpegData(compressionQuality: 0.7)
    }

    /// Downscales the longest side of `image` to maxReportSidePixels when
    /// the source is larger; returns the original instance otherwise.
    private static func resizeForReport(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxReportSidePixels else { return image }
        let ratio = maxReportSidePixels / longest
        let target = CGSize(
            width: floor(image.size.width * ratio),
            height: floor(image.size.height * ratio)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Maps annotation-overlay coordinates onto the full-resolution image.
    ///
    /// Overlay shapes are recorded in the editor's *container* coordinate
    /// space (`PencilKitPhotoAnnotationView`'s GeometryReader), where the photo
    /// is shown `.scaledToFit` — i.e. uniformly scaled and letterboxed inside
    /// the container. The bake previously scaled overlay coords by separate
    /// `scaleX = imageW/canvasW` and `scaleY = imageH/canvasH`. Because the
    /// container aspect ratio differs from the photo's, those scales differ:
    /// circles baked as ellipses and every mark was offset by the (ignored)
    /// letterbox — in the client-facing PDF (B-0071).
    ///
    /// This reconstructs the letterboxed image rect from the stored container
    /// size and the real image aspect ratio, then maps with a SINGLE uniform
    /// scale plus the letterbox offset. Shared by both bake paths
    /// (`AnnotationBakeService` here and `PhotoLoadService`) so they cannot
    /// drift apart again.
    struct OverlayTransform {
        let scale: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
        /// Container-space point → image-pixel point.
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: (CGFloat(x) - offsetX) * scale, y: (CGFloat(y) - offsetY) * scale)
        }
        /// Stroke width scaled uniformly (base 3 pt in container space).
        var lineWidth: CGFloat { 3 * scale }
    }

    static func overlayTransform(overlay: AnnotationOverlay, imageSize: CGSize) -> OverlayTransform {
        let cw = CGFloat(overlay.canvasWidth ?? Double(imageSize.width))
        let ch = CGFloat(overlay.canvasHeight ?? Double(imageSize.height))
        guard cw > 0, ch > 0, imageSize.width > 0, imageSize.height > 0 else {
            return OverlayTransform(scale: 1, offsetX: 0, offsetY: 0)
        }
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = cw / ch
        let dispW: CGFloat
        let dispH: CGFloat
        if imageAspect > containerAspect {
            // Photo wider than container → spans full width, letterboxed top/bottom.
            dispW = cw
            dispH = cw / imageAspect
        } else {
            // Photo taller/narrower → spans full height, letterboxed left/right.
            dispH = ch
            dispW = ch * imageAspect
        }
        // Uniform: imageSize.width / dispW == imageSize.height / dispH.
        let scale = imageSize.width / dispW
        return OverlayTransform(scale: scale, offsetX: (cw - dispW) / 2, offsetY: (ch - dispH) / 2)
    }

    private static func composite(overlay: AnnotationOverlay, onto image: UIImage) -> UIImage {
        let t = overlayTransform(overlay: overlay, imageSize: image.size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1  // Use 1x scale for report images to prevent OOM on high-res photos
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { context in
            image.draw(at: .zero)
            let cg = context.cgContext
            if let data = overlay.drawingData, let drawing = try? PKDrawing(data: data) {
                cg.saveGState()
                // CTM applied to the PencilKit drawing (also in container space):
                // p ↦ scale * (p - offset). scaleBy then translateBy(-offset).
                cg.scaleBy(x: t.scale, y: t.scale)
                cg.translateBy(x: -t.offsetX, y: -t.offsetY)
                drawing.image(from: drawing.bounds, scale: 1).draw(at: drawing.bounds.origin)
                cg.restoreGState()
            }
            for arrow in overlay.arrows {
                let color = colorFrom(name: arrow.colorName)
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(t.lineWidth)
                cg.beginPath()
                cg.move(to: t.point(arrow.startX, arrow.startY))
                cg.addLine(to: t.point(arrow.endX, arrow.endY))
                cg.strokePath()
            }
            for circle in overlay.circles {
                let color = colorFrom(name: circle.colorName)
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(t.lineWidth)
                let c = t.point(circle.centerX, circle.centerY)
                let r = CGFloat(circle.radius) * t.scale
                cg.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
        }
    }

    private static func colorFrom(name: String) -> UIColor {
        switch name {
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        default: return .systemRed
        }
    }
}
