//
//  LiDARScanStore.swift
//  NexGenSpec
//
//  Persists LiDAR scan metadata and file paths. USDZ/PNG written by capture pipeline.
//

import Foundation

/// Saves scan metadata to inspection lidar folder. Call after writing USDZ and optional floorplan PNG.
enum LiDARScanStore {

    static func save(_ scan: LiDARScan, jobId: UUID) {
        let url = FilePaths.lidarFolder(jobId: jobId).appendingPathComponent("\(scan.id.uuidString).json")
        try? FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
        guard let data = try? JSONEncoder().encode(scan) else { return }
        try? FileSecurity.writeProtected(data, to: url)
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
