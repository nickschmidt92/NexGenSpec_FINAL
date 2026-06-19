//
//  PencilKitPhotoAnnotationView.swift
//  NexGenSpec
//
//  PencilKit-based annotation: vector overlay stored; bake at export time.
//

import SwiftUI
import PencilKit

/// Annotation view using PencilKit for drawing (pressure-sensitive). Stores vector overlay; does not overwrite photo.
struct PencilKitPhotoAnnotationView: View {
    var baseImage: UIImage
    var initialOverlay: AnnotationOverlay?
    var onSave: (AnnotationOverlay) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var canvasDrawing: PKDrawing = PKDrawing()
    @State private var currentTool: AnnotationTool = .freehand
    @State private var selectedColor: PencilInkColor = .red
    @State private var arrows: [ArrowShape] = []
    @State private var circles: [CircleShape] = []
    @State private var tempShapeStart: CGPoint?
    @State private var tempShapeEnd: CGPoint?
    @State private var canvasSize: CGSize = .zero
    // Unified undo/redo history. Each entry is a full snapshot of the
    // annotation state (PencilKit drawing + arrow/circle shapes). Freehand
    // strokes, arrows, and circles all push a snapshot before mutating, so
    // Undo/Redo work uniformly across every tool. The previous undoManager-only
    // path undid freehand strokes but silently ignored the shape arrays, so
    // a placed arrow/circle could never be undone.
    @State private var undoStack: [AnnotationSnapshot] = []
    @State private var redoStack: [AnnotationSnapshot] = []

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Image(uiImage: baseImage)
                        .resizable()
                        .scaledToFit()
                    PencilKitCanvasView(
                        drawing: $canvasDrawing,
                        inkColor: selectedColor.uiColor,
                        onBeganStroke: { pushUndoSnapshot() }
                    )
                    .allowsHitTesting(currentTool == .freehand)
                    shapesOverlay(size: geo.size)
                }
                .onAppear { canvasSize = geo.size }
            }
            toolBar
        }
        .navigationTitle("Annotate")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadInitialOverlay() }
    }

    private func loadInitialOverlay() {
        guard let o = initialOverlay else { return }
        if let data = o.drawingData, let drawing = try? PKDrawing(data: data) {
            canvasDrawing = drawing
        }
        arrows = o.arrows.map { ArrowShape(start: CGPoint(x: $0.startX, y: $0.startY), end: CGPoint(x: $0.endX, y: $0.endY), colorName: $0.colorName) }
        circles = o.circles.map { CircleShape(center: CGPoint(x: $0.centerX, y: $0.centerY), radius: $0.radius, colorName: $0.colorName) }
    }

    // MARK: - Undo / Redo history

    private func currentSnapshot() -> AnnotationSnapshot {
        AnnotationSnapshot(drawing: canvasDrawing, arrows: arrows, circles: circles)
    }

    /// Snapshot the current state before a mutation. Called by every tool —
    /// freehand stroke begin, arrow add, circle add — so all are undoable.
    /// Pushing here (not after) means Undo restores the exact pre-edit state.
    private func pushUndoSnapshot() {
        undoStack.append(currentSnapshot())
        redoStack.removeAll()
        // Bound memory: PKDrawing snapshots can be sizable on long edit sessions.
        if undoStack.count > 50 { undoStack.removeFirst(undoStack.count - 50) }
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        apply(previous)
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        apply(next)
    }

    private func apply(_ snapshot: AnnotationSnapshot) {
        canvasDrawing = snapshot.drawing
        arrows = snapshot.arrows
        circles = snapshot.circles
    }

    @ViewBuilder
    private func shapesOverlay(size: CGSize) -> some View {
        Canvas { context, size in
            for arrow in arrows {
                var path = Path()
                path.move(to: arrow.start)
                path.addLine(to: arrow.end)
                context.stroke(path, with: .color(PencilInkColor(name: arrow.colorName).color), lineWidth: 3)
            }
            for circle in circles {
                let r = CGRect(x: circle.center.x - circle.radius, y: circle.center.y - circle.radius, width: circle.radius * 2, height: circle.radius * 2)
                context.stroke(Path(ellipseIn: r), with: .color(PencilInkColor(name: circle.colorName).color), lineWidth: 3)
            }
            if let s = tempShapeStart, let e = tempShapeEnd {
                switch currentTool {
                case .arrow:
                    var path = Path()
                    path.move(to: s)
                    path.addLine(to: e)
                    context.stroke(path, with: .color(selectedColor.color), lineWidth: 3)
                case .circle:
                    let dx = e.x - s.x, dy = e.y - s.y
                    let radius = sqrt(dx*dx + dy*dy)
                    let r = CGRect(x: s.x - radius, y: s.y - radius, width: radius * 2, height: radius * 2)
                    context.stroke(Path(ellipseIn: r), with: .color(selectedColor.color), lineWidth: 3)
                case .freehand:
                    break
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0.1)
                .onChanged { v in
                    guard currentTool != .freehand else { return }
                    if tempShapeStart == nil { tempShapeStart = v.startLocation }
                    tempShapeEnd = v.location
                }
                .onEnded { v in
                    guard currentTool != .freehand else { return }
                    if let s = tempShapeStart, let e = tempShapeEnd {
                        switch currentTool {
                        case .arrow:
                            pushUndoSnapshot()
                            arrows.append(ArrowShape(start: s, end: e, colorName: selectedColor.rawValue))
                        case .circle:
                            pushUndoSnapshot()
                            let dx = e.x - s.x, dy = e.y - s.y
                            circles.append(CircleShape(center: s, radius: sqrt(dx*dx + dy*dy), colorName: selectedColor.rawValue))
                        case .freehand:
                            break
                        }
                    }
                    tempShapeStart = nil
                    tempShapeEnd = nil
                }
        )
        .allowsHitTesting(currentTool != .freehand)
    }

    private var toolBar: some View {
        VStack(spacing: 12) {
            HStack {
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .accessibilityLabel("Undo")
                    .disabled(undoStack.isEmpty)
                Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .accessibilityLabel("Redo")
                    .disabled(redoStack.isEmpty)
                ToolBtn(icon: "pencil", isSelected: currentTool == .freehand) { currentTool = .freehand }
                ToolBtn(icon: "arrow.up.right", isSelected: currentTool == .arrow) { currentTool = .arrow }
                ToolBtn(icon: "circle", isSelected: currentTool == .circle) { currentTool = .circle }
                Spacer()
                ForEach([PencilInkColor.red, .yellow, .green], id: \.rawValue) { c in
                    Circle()
                        .fill(c.color)
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(selectedColor == c ? Color.primary : Color.clear, lineWidth: 2))
                        .onTapGesture { selectedColor = c }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") {
                    let overlay = AnnotationOverlay(
                        drawingData: canvasDrawing.dataRepresentation(),
                        arrows: arrows.map { ArrowAnnotation(startX: Double($0.start.x), startY: Double($0.start.y), endX: Double($0.end.x), endY: Double($0.end.y), colorName: $0.colorName) },
                        circles: circles.map { CircleAnnotation(centerX: Double($0.center.x), centerY: Double($0.center.y), radius: Double($0.radius), colorName: $0.colorName) },
                        canvasWidth: canvasSize.width > 0 ? Double(canvasSize.width) : nil,
                        canvasHeight: canvasSize.height > 0 ? Double(canvasSize.height) : nil
                    )
                    onSave(overlay)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

// MARK: - PencilKit wrapper
private struct PencilKitCanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var inkColor: UIColor
    /// Fired when the user begins a freehand stroke, so the host can snapshot
    /// the pre-stroke state for undo. (Shapes snapshot themselves on add.)
    var onBeganStroke: () -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.drawing = drawing
        v.delegate = context.coordinator
        v.backgroundColor = .clear
        v.isOpaque = false
        v.drawingPolicy = .anyInput
        v.tool = PKInkingTool(.pen, color: inkColor, width: 3)
        context.coordinator.canvasView = v
        return v
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.tool = PKInkingTool(.pen, color: inkColor, width: 3)
        // Sync external drawing changes (undo/redo history restores) back into
        // the canvas. Compare stroke counts rather than the drawings directly
        // since PKDrawing isn't Equatable; every undo/redo of a freehand stroke
        // changes the count, and shape-only history steps leave the drawing
        // untouched so no resync is needed.
        if uiView.drawing.strokes.count != drawing.strokes.count {
            uiView.drawing = drawing
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing, onBeganStroke: onBeganStroke)
    }

    class Coordinator: NSObject, PKCanvasViewDelegate {
        var drawing: Binding<PKDrawing>
        let onBeganStroke: () -> Void
        weak var canvasView: PKCanvasView?
        init(drawing: Binding<PKDrawing>, onBeganStroke: @escaping () -> Void) {
            self.drawing = drawing
            self.onBeganStroke = onBeganStroke
        }
        // Fires once when the user starts a stroke — capture the pre-stroke
        // state for undo before the new stroke lands in the drawing.
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            onBeganStroke()
        }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing.wrappedValue = canvasView.drawing
        }
    }
}

// MARK: - Internal shapes
private enum AnnotationTool { case freehand, arrow, circle }

/// Full snapshot of the annotation state for one undo/redo step. PKDrawing and
/// the shape arrays are value types, so each snapshot is an independent copy.
private struct AnnotationSnapshot {
    var drawing: PKDrawing
    var arrows: [ArrowShape]
    var circles: [CircleShape]
}

private enum PencilInkColor: String, CaseIterable {
    case red, yellow, green
    var color: Color {
        switch self {
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        }
    }
    var uiColor: UIColor {
        switch self {
        case .red: return .systemRed
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        }
    }
    init(name: String) {
        switch name {
        case "yellow": self = .yellow
        case "green": self = .green
        default: self = .red
        }
    }
}

private struct ArrowShape {
    var start: CGPoint
    var end: CGPoint
    var colorName: String
}

private struct CircleShape {
    var center: CGPoint
    var radius: CGFloat
    var colorName: String
}

private struct ToolBtn: View {
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundColor(isSelected ? .accentColor : .primary)
                .padding(6)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                .clipShape(Circle())
        }
    }
}
