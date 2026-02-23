//
//  AnnotationOverlay.swift
//  NexGenSpec
//
//  Vector overlay for photo annotations. Stored per photo; baked at export time.
//

import Foundation

/// Stored annotation overlay (PencilKit drawing + shapes). Non-destructive; original photo unchanged.
public struct AnnotationOverlay: Codable, Equatable {
    public var schemaVersion: Int
    public var drawingData: Data?
    public var arrows: [ArrowAnnotation]
    public var circles: [CircleAnnotation]
    /// View size when overlay was saved; used at bake time to scale to image size. Nil = assume 1:1.
    public var canvasWidth: Double?
    public var canvasHeight: Double?

    public init(schemaVersion: Int = 1, drawingData: Data? = nil, arrows: [ArrowAnnotation] = [], circles: [CircleAnnotation] = [], canvasWidth: Double? = nil, canvasHeight: Double? = nil) {
        self.schemaVersion = schemaVersion
        self.drawingData = drawingData
        self.arrows = arrows
        self.circles = circles
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }
}

public struct ArrowAnnotation: Codable, Equatable {
    public var startX: Double
    public var startY: Double
    public var endX: Double
    public var endY: Double
    public var colorName: String

    public init(startX: Double, startY: Double, endX: Double, endY: Double, colorName: String) {
        self.startX = startX
        self.startY = startY
        self.endX = endX
        self.endY = endY
        self.colorName = colorName
    }
}

public struct CircleAnnotation: Codable, Equatable {
    public var centerX: Double
    public var centerY: Double
    public var radius: Double
    public var colorName: String

    public init(centerX: Double, centerY: Double, radius: Double, colorName: String) {
        self.centerX = centerX
        self.centerY = centerY
        self.radius = radius
        self.colorName = colorName
    }
}
