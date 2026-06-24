//
//  LiDARScanStore.swift
//  NexGenSpec
//
//  Persists LiDAR scan metadata and file paths. USDZ/PNG written by capture pipeline.
//

import Foundation

/// Saves scan metadata to inspection lidar folder. Call after writing USDZ and optional floorplan PNG.
enum LiDARScanStore {

    /// Persists scan metadata. Returns true only if the bytes reached disk — a
    /// swallowed write meant a just-captured (iPad-only) LiDAR scan never appeared
    /// in loadScans, with no feedback (mirrors SignatureStore).
    @discardableResult
    static func save(_ scan: LiDARScan, jobId: UUID) -> Bool {
        let url = FilePaths.lidarFolder(jobId: jobId).appendingPathComponent("\(scan.id.uuidString).json")
        do {
            try FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
            let data = try JSONEncoder().encode(scan)
            try FileSecurity.writeProtected(data, to: url)
            return true
        } catch {
            Diagnostics.logError(context: "LiDAR scan save failed", error: error)
            return false
        }
    }

    static func loadScans(jobId: UUID) -> [LiDARScan] {
        let dir = FilePaths.lidarFolder(jobId: jobId)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return [] }
        return contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> LiDARScan? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(LiDARScan.self, from: data)
            }
    }
}
