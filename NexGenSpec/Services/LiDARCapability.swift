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
        // On Mac (Designed for iPad, build 22 slice 5) there is no LiDAR and the app
        // is a review/finalize station — hide capture explicitly, before touching
        // ARKit. A real iPhone/iPad is unaffected (Platform.isMac == false).
        if Platform.isMac { return false }
        #if canImport(ARKit)
        return ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        #else
        return false
        #endif
    }
}
