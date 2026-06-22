//
//  Platform.swift
//  NexGenSpec
//
//  Runtime platform detection. Build 22 slice 5 ships the app on Mac as a
//  "Designed for iPad" app — a finalize/review station where hardware capture
//  (camera / LiDAR) is hidden. `isMac` is true ONLY when this iOS app is running
//  on macOS via SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD; it is NOT a Mac Catalyst
//  build. On a real iPhone/iPad it is false, so iOS behavior is unchanged.
//

import Foundation

enum Platform {
    /// True when this iOS app is running on a Mac (Designed for iPad).
    static var isMac: Bool { ProcessInfo.processInfo.isiOSAppOnMac }
}
