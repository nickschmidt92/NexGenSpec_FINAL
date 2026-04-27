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
    private static let maxReportSidePixels: CGFloat = 1600

    /// Returns JPEG data of photo with overlay drawn on top, resized for
    /// report use (long side capped at maxReportSidePixels). If no overlay,
    /// still resizes/recompresses the original to keep the report PDF
    /// reasonable. Returns nil only if the input data fails to decode.
    static func bakedImageData(jobId: UUID, photo: InspectionPhoto, photoData: Data?) -> Data? {
        guard let photoData = photoData, let base = UIImage(data: photoData) else { return photoData }
        let overlay = AnnotationStore.load(jobId: jobId, photoId: photo.id)
        let withOverlay = overlay.map { composite(overlay: $0, onto: base, canvasSize: base.size) } ?? base
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

    private static func composite(overlay: AnnotationOverlay, onto image: UIImage, canvasSize: CGSize) -> UIImage {
        let cw = overlay.canvasWidth ?? canvasSize.width
        let ch = overlay.canvasHeight ?? canvasSize.height
        let scaleX = cw > 0 ? image.size.width / cw : 1
        let scaleY = ch > 0 ? image.size.height / ch : 1
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1  // Use 1x scale for report images to prevent OOM on high-res photos
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { context in
            image.draw(at: .zero)
            let cg = context.cgContext
            if let data = overlay.drawingData, let drawing = try? PKDrawing(data: data) {
                cg.saveGState()
                cg.scaleBy(x: scaleX, y: scaleY)
                drawing.image(from: drawing.bounds, scale: 1).draw(at: drawing.bounds.origin)
                cg.restoreGState()
            }
            for arrow in overlay.arrows {
                let color = colorFrom(name: arrow.colorName)
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(3 * max(scaleX, scaleY))
                cg.beginPath()
                cg.move(to: CGPoint(x: arrow.startX * scaleX, y: arrow.startY * scaleY))
                cg.addLine(to: CGPoint(x: arrow.endX * scaleX, y: arrow.endY * scaleY))
                cg.strokePath()
            }
            for circle in overlay.circles {
                let color = colorFrom(name: circle.colorName)
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(3 * max(scaleX, scaleY))
                let r = CGRect(x: (circle.centerX - circle.radius) * scaleX, y: (circle.centerY - circle.radius) * scaleY, width: circle.radius * 2 * scaleX, height: circle.radius * 2 * scaleY)
                cg.strokeEllipse(in: r)
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
