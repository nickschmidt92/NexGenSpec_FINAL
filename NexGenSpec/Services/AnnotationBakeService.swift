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

    /// Returns PNG data of photo with overlay drawn on top. If no overlay, returns original photo data.
    static func bakedImageData(jobId: UUID, photo: InspectionPhoto, photoData: Data?) -> Data? {
        guard let photoData = photoData, let base = UIImage(data: photoData) else { return photoData }
        guard let overlay = AnnotationStore.load(jobId: jobId, photoId: photo.id) else { return photoData }
        let composited = composite(overlay: overlay, onto: base, canvasSize: base.size)
        return composited.pngData()
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
