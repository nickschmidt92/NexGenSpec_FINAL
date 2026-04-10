//
//  PhotoAnnotationView.swift
//  NexGenSpec
//
//  Created by ChatGPT on 2/5/26.
//

import SwiftUI

/// A rich annotation view allowing freehand, arrow and circle annotations over an image.
struct PhotoAnnotationView: View {
    var baseImage: UIImage
    var onSave: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    // MARK: Annotation state
    @State private var currentTool: AnnotationTool = .freehand
    @State private var selectedColor: Color = .red

    @State private var currentFreehand: FreehandDrawing = FreehandDrawing()
    @State private var freehandDrawings: [FreehandDrawing] = []
    @State private var arrows: [ArrowShape] = []
    @State private var circles: [CircleShape] = []

    @State private var tempShapeStart: CGPoint?
    @State private var tempShapeEnd: CGPoint?
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        VStack {
            GeometryReader { geo in
                ZStack {
                    Image(uiImage: baseImage)
                        .resizable()
                        .scaledToFit()
                    // Annotation layer
                    Canvas { context, size in
                        if canvasSize != size { canvasSize = size }
                        // Draw completed freehand strokes
                        for drawing in freehandDrawings {
                            guard let first = drawing.points.first else { continue }
                            var path = Path()
                            path.move(to: first)
                            for point in drawing.points.dropFirst() {
                                path.addLine(to: point)
                            }
                            context.stroke(path, with: .color(drawing.color), lineWidth: 3)
                        }
                        // Draw current freehand stroke
                        if currentTool == .freehand {
                            if let first = currentFreehand.points.first {
                                var path = Path()
                                path.move(to: first)
                                for point in currentFreehand.points.dropFirst() {
                                    path.addLine(to: point)
                                }
                                context.stroke(path, with: .color(currentFreehand.color), lineWidth: 3)
                            }
                        }
                        // Draw finished arrows
                        for arrow in arrows {
                            var path = Path()
                            path.move(to: arrow.start)
                            path.addLine(to: arrow.end)
                            context.stroke(path, with: .color(arrow.color), lineWidth: 3)
                            // Draw arrowhead
                            let dx = arrow.end.x - arrow.start.x
                            let dy = arrow.end.y - arrow.start.y
                            let length = max(sqrt(dx * dx + dy * dy), 0.0001)
                            let ux = dx / length
                            let uy = dy / length
                            let arrowHeadLength: CGFloat = 12
                            // let arrowHeadWidth: CGFloat = 6  <-- removed this line
                            // Two wing points rotated ±135°
                            let leftX = arrow.end.x - arrowHeadLength * (ux * cos(.pi * 3/4) - uy * sin(.pi * 3/4))
                            let leftY = arrow.end.y - arrowHeadLength * (ux * sin(.pi * 3/4) + uy * cos(.pi * 3/4))
                            let rightX = arrow.end.x - arrowHeadLength * (ux * cos(-.pi * 3/4) - uy * sin(-.pi * 3/4))
                            let rightY = arrow.end.y - arrowHeadLength * (ux * sin(-.pi * 3/4) + uy * cos(-.pi * 3/4))
                            var arrowHeadPath = Path()
                            arrowHeadPath.move(to: arrow.end)
                            arrowHeadPath.addLine(to: CGPoint(x: leftX, y: leftY))
                            arrowHeadPath.move(to: arrow.end)
                            arrowHeadPath.addLine(to: CGPoint(x: rightX, y: rightY))
                            context.stroke(arrowHeadPath, with: .color(arrow.color), lineWidth: 3)
                        }
                        // Draw finished circles
                        for circle in circles {
                            let rect = CGRect(x: circle.center.x - circle.radius, y: circle.center.y - circle.radius, width: circle.radius * 2, height: circle.radius * 2)
                            context.stroke(Path(ellipseIn: rect), with: .color(circle.color), lineWidth: 3)
                        }
                        // Draw temporary arrow or circle while dragging
                        if let start = tempShapeStart, let end = tempShapeEnd {
                            switch currentTool {
                            case .arrow:
                                var path = Path()
                                path.move(to: start)
                                path.addLine(to: end)
                                context.stroke(path, with: .color(selectedColor), lineWidth: 3)
                            case .circle:
                                let dx = end.x - start.x
                                let dy = end.y - start.y
                                let radius = sqrt(dx*dx + dy*dy)
                                let rect = CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)
                                context.stroke(Path(ellipseIn: rect), with: .color(selectedColor), lineWidth: 3)
                            default:
                                break
                            }
                        }
                    }
                    // Gesture overlay
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0.1)
                        .onChanged { value in
                            let point = value.location
                            switch currentTool {
                            case .freehand:
                                currentFreehand.points.append(point)
                                currentFreehand.color = selectedColor
                            case .arrow, .circle:
                                if tempShapeStart == nil {
                                    tempShapeStart = point
                                }
                                tempShapeEnd = point
                            }
                        }
                        .onEnded { _ in
                            switch currentTool {
                            case .freehand:
                                if !currentFreehand.points.isEmpty {
                                    freehandDrawings.append(currentFreehand)
                                    currentFreehand = FreehandDrawing()
                                }
                            case .arrow:
                                if let start = tempShapeStart, let end = tempShapeEnd {
                                    arrows.append(ArrowShape(start: start, end: end, color: selectedColor))
                                }
                                tempShapeStart = nil
                                tempShapeEnd = nil
                            case .circle:
                                if let start = tempShapeStart, let end = tempShapeEnd {
                                    let dx = end.x - start.x
                                    let dy = end.y - start.y
                                    let radius = sqrt(dx*dx + dy*dy)
                                    circles.append(CircleShape(center: start, radius: radius, color: selectedColor))
                                }
                                tempShapeStart = nil
                                tempShapeEnd = nil
                            }
                        }
                    )
                }
            }
            // Tool and color selection bar
            VStack(spacing: 12) {
                HStack {
                    ToolButton(icon: "pencil", tool: .freehand, currentTool: $currentTool)
                    ToolButton(icon: "arrow.up.right", tool: .arrow, currentTool: $currentTool)
                    ToolButton(icon: "circle", tool: .circle, currentTool: $currentTool)
                    Spacer()
                    ColorButton(color: .red, selectedColor: $selectedColor)
                    ColorButton(color: .yellow, selectedColor: $selectedColor)
                    ColorButton(color: .green, selectedColor: $selectedColor)
                }
                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Save") {
                        let annotated = renderAnnotatedImage()
                        onSave(annotated)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .navigationTitle("Annotate")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Rendering
    /// Renders the image with all drawings and shapes applied.
    private func renderAnnotatedImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        let renderer = UIGraphicsImageRenderer(size: baseImage.size, format: format)
        return renderer.image { context in
            // Draw original image
            baseImage.draw(in: CGRect(origin: .zero, size: baseImage.size))
            // Compute scale relative to the device screen width and height used during drawing
            let drawWidth = max(canvasSize.width, 1)
            let drawHeight = max(canvasSize.height, 1)
            let scaleX = baseImage.size.width / drawWidth
            let scaleY = baseImage.size.height / drawHeight
            // Draw freehand lines
            for drawing in freehandDrawings {
                guard let first = drawing.points.first else { continue }
                context.cgContext.setStrokeColor(UIColor(drawing.color).cgColor)
                context.cgContext.setLineWidth(3)
                context.cgContext.beginPath()
                context.cgContext.move(to: CGPoint(x: first.x * scaleX, y: first.y * scaleY))
                for point in drawing.points.dropFirst() {
                    context.cgContext.addLine(to: CGPoint(x: point.x * scaleX, y: point.y * scaleY))
                }
                context.cgContext.strokePath()
            }
            // Draw arrows
            for arrow in arrows {
                context.cgContext.setStrokeColor(UIColor(arrow.color).cgColor)
                context.cgContext.setLineWidth(3)
                context.cgContext.beginPath()
                context.cgContext.move(to: CGPoint(x: arrow.start.x * scaleX, y: arrow.start.y * scaleY))
                context.cgContext.addLine(to: CGPoint(x: arrow.end.x * scaleX, y: arrow.end.y * scaleY))
                context.cgContext.strokePath()
                // Arrowhead
                let dx = (arrow.end.x - arrow.start.x)
                let dy = (arrow.end.y - arrow.start.y)
                let length = max(sqrt(dx*dx + dy*dy), 0.0001)
                let ux = dx / length
                let uy = dy / length
                let headLength: CGFloat = 12
                let leftX = arrow.end.x - headLength * (ux * cos(.pi * 3/4) - uy * sin(.pi * 3/4))
                let leftY = arrow.end.y - headLength * (ux * sin(.pi * 3/4) + uy * cos(.pi * 3/4))
                let rightX = arrow.end.x - headLength * (ux * cos(-.pi * 3/4) - uy * sin(-.pi * 3/4))
                let rightY = arrow.end.y - headLength * (ux * sin(-.pi * 3/4) + uy * cos(-.pi * 3/4))
                context.cgContext.beginPath()
                context.cgContext.move(to: CGPoint(x: arrow.end.x * scaleX, y: arrow.end.y * scaleY))
                context.cgContext.addLine(to: CGPoint(x: leftX * scaleX, y: leftY * scaleY))
                context.cgContext.move(to: CGPoint(x: arrow.end.x * scaleX, y: arrow.end.y * scaleY))
                context.cgContext.addLine(to: CGPoint(x: rightX * scaleX, y: rightY * scaleY))
                context.cgContext.strokePath()
            }
            // Draw circles
            for circle in circles {
                let scaledRect = CGRect(
                    x: (circle.center.x - circle.radius) * scaleX,
                    y: (circle.center.y - circle.radius) * scaleY,
                    width: circle.radius * 2 * scaleX,
                    height: circle.radius * 2 * scaleY
                )
                context.cgContext.setStrokeColor(UIColor(circle.color).cgColor)
                context.cgContext.setLineWidth(3)
                context.cgContext.strokeEllipse(in: scaledRect)
            }
        }
    }
}

// MARK: Helper Types
private enum AnnotationTool {
    case freehand, arrow, circle
}

/// Represents a freehand drawing as a sequence of points with a colour.
private struct FreehandDrawing {
    var points: [CGPoint] = []
    var color: Color = .red
}

/// Represents a straight arrow between a start and end point with an associated colour.
private struct ArrowShape {
    var start: CGPoint
    var end: CGPoint
    var color: Color
}

/// Represents a circle defined by a centre, radius and colour.
private struct CircleShape {
    var center: CGPoint
    var radius: CGFloat
    var color: Color
}

/// Button to select a drawing tool.
private struct ToolButton: View {
    let icon: String
    let tool: AnnotationTool
    @Binding var currentTool: AnnotationTool
    var body: some View {
        Button(action: { currentTool = tool }) {
            Image(systemName: icon)
                .foregroundColor(currentTool == tool ? .accentColor : .primary)
                .padding(6)
                .background(currentTool == tool ? Color.accentColor.opacity(0.2) : Color.clear)
                .clipShape(Circle())
        }
    }
}

/// A small circular button used to pick a colour.
private struct ColorButton: View {
    let color: Color
    @Binding var selectedColor: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 30, height: 30)
            .overlay(
                Circle()
                    .stroke(selectedColor == color ? Color.primary : Color.clear, lineWidth: 2)
            )
            .onTapGesture {
                selectedColor = color
            }
    }
}
