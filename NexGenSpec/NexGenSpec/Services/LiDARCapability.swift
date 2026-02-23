//
//  LiDARCapability.swift
//  NexGenSpec
//
//  Feature gate for LiDAR / RoomPlan. Hide capture UI on non-LiDAR devices.
//

import Foundation

#if canImport(ARKit)
import ARKit
#endif

enum LiDARCapability {

    /// True when device supports scene reconstruction (LiDAR). Use to show/hide RoomPlan capture.
    static var isSupported: Bool {
        #if canImport(ARKit)
        return ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        #else
        return false
        #endif
    }
}
