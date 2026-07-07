//
//  WholeHomeFloorplanService.swift
//  NexGenSpec
//
//  Builds and caches the merged whole-home floor plan for an inspection.
//  Cache: <lidar>/whole_home_<key>.png where key = SHA-256 over the sorted
//  ids of scans that have room JSON — any add/delete of a mergeable scan
//  changes the key, so stale caches are never served.
//

import Foundation
import CryptoKit
#if canImport(RoomPlan)
import RoomPlan
#endif

enum WholeHomeFloorplanService {

    static let cacheFilePrefix = "whole_home_"

    /// Current cache key, or nil when fewer than 2 scans have room JSON.
    static func cacheKey(for scans: [LiDARScan]) -> String? {
        let ids = scans.compactMap { $0.roomJSONFileName != nil ? $0.id.uuidString : nil }.sorted()
        guard ids.count >= 2 else { return nil }
        let digest = SHA256.hash(data: Data(ids.joined(separator: ",").utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }

    /// Synchronous, main-actor-free cache read for renderHTML (which is sync
    /// and runs off-main). Returns nil unless a cache matching the CURRENT
    /// scan set exists — never serves a stale merge.
    static func cachedPNG(jobId: UUID) -> Data? {
        let scans = LiDARScanStore.loadScans(jobId: jobId)
        guard let key = cacheKey(for: scans) else { return nil }
        let url = FilePaths.lidarFolder(jobId: jobId).appendingPathComponent("\(cacheFilePrefix)\(key).png")
        return try? Data(contentsOf: url)
    }

    /// Serializes regenerateIfNeeded per inspection so removeAllCaches + write is
    /// never interleaved with another regen for the same jobId, and concurrent
    /// export pipelines coalesce onto one run instead of racing.
    private actor RegenGate {
        static let shared = RegenGate()
        private var inFlight: [UUID: Task<Void, Never>] = [:]
        func run(_ jobId: UUID, _ work: @escaping @Sendable () async -> Void) async {
            if let existing = inFlight[jobId] { await existing.value; return }
            let task = Task { await work() }
            inFlight[jobId] = task
            await task.value
            inFlight[jobId] = nil
        }
    }

    /// Regenerate the merged plan if the scan set changed. Degrades silently:
    /// any failure (decode, merge, render, write) logs and leaves no cache,
    /// so the report simply skips the page. Call before rendering a report.
    static func regenerateIfNeeded(jobId: UUID) async {
        await RegenGate.shared.run(jobId) { await performRegenerate(jobId: jobId) }
    }

    private static func performRegenerate(jobId: UUID) async {
        #if canImport(RoomPlan)
        guard #available(iOS 17.0, *) else { return }
        let scans = LiDARScanStore.loadScans(jobId: jobId)
        let lidarDir = FilePaths.lidarFolder(jobId: jobId)
        guard let key = cacheKey(for: scans) else {
            removeAllCaches(in: lidarDir)   // scan set shrank below 2 — drop stale merge
            return
        }
        let cacheURL = lidarDir.appendingPathComponent("\(cacheFilePrefix)\(key).png")
        guard !FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        // Decode every persisted CapturedRoom; skip unreadable ones.
        var rooms: [CapturedRoom] = []
        for scan in scans {
            guard let fileName = scan.roomJSONFileName,
                  let data = try? Data(contentsOf: lidarDir.appendingPathComponent(fileName)),
                  let room = try? JSONDecoder().decode(CapturedRoom.self, from: data) else { continue }
            rooms.append(room)
        }
        guard rooms.count >= 2 else { return }
        do {
            let builder = StructureBuilder(options: [.beautifyObjects])
            let structure = try await builder.capturedStructure(from: rooms)
            guard let png = FloorplanRenderer.renderPNG(
                from: structure.rooms,
                size: CGSize(width: 2000, height: 1500),
                margin: 80
            ) else { return }
            removeAllCaches(in: lidarDir)   // clear stale keys before writing the new one
            try png.write(to: cacheURL, options: .atomic)
        } catch {
            Diagnostics.logError(context: "WholeHomeFloorplan merge failed", error: error)
        }
        #endif
    }

    private static func removeAllCaches(in dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix(cacheFilePrefix) { try? fm.removeItem(at: f) }
    }
}
