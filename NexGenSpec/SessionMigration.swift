//
//  SessionMigration.swift
//  NexGenSpec
//
//  One-time migration of pre-B-0096 un-namespaced local data into the active
//  user's per-UID namespace.
//
//  Before B-0096 the working store lived directly under
//  `Application Support/NexGenSpec/`. After the fix each account stores under
//  `…/NexGenSpec/Users/<uid>/`. Existing TestFlight users (build ≤17) have data
//  at the old location; this moves it into the CURRENT signed-in user's
//  namespace so the upgrade is lossless. There is only ever one blob of
//  un-namespaced data on a device (every pre-fix account shared it), and the
//  signed-in user at upgrade time is its owner, so attributing it to the current
//  user is the correct call.
//

import Foundation

enum SessionMigration {

    /// Marker file written inside a user's namespace once migration has run, so
    /// it never runs twice for the same user.
    static let markerName = ".b0096-migrated"

    /// Moves every entry directly under the legacy shared root (except the
    /// `Users/` container itself) into the active user's namespace, exactly once.
    /// No-op when signed out, when there is no legacy data, or when this user's
    /// namespace already has a live index. Retry-safe: never clobbers an existing
    /// destination file, and only writes the completion marker once every movable
    /// entry has actually left the source, so a partial migration resumes on the
    /// next launch.
    ///
    /// Must run AFTER Firebase is configured and BEFORE the store loads.
    @discardableResult
    static func runIfNeeded() -> Bool {
        guard let uid = SessionScope.activeUID else { return false }
        let fm = FileManager.default
        let dest = FilePaths.userRoot(uid: uid)
        let marker = dest.appendingPathComponent(markerName, isDirectory: false)

        // Already migrated for this user.
        if fm.fileExists(atPath: marker.path) { return false }

        // This user already has a live store (created post-fix, or a prior
        // migration completed without the marker surviving): never overwrite it.
        let destIndex = dest.appendingPathComponent("inspections.json", isDirectory: false)
        if fm.fileExists(atPath: destIndex.path) {
            writeMarker(marker, dest: dest)
            return false
        }

        let legacyRoot = FilePaths.legacySharedRoot
        // Snapshot the legacy entries BEFORE creating `dest` (which creates the
        // `Users/` intermediate inside `legacyRoot`), then drop the container.
        guard let entries = try? fm.contentsOfDirectory(
            at: legacyRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            // No legacy root at all → clean install → nothing to migrate.
            writeMarker(marker, dest: dest)
            return false
        }
        let movable = entries.filter { $0.lastPathComponent != FilePaths.usersContainerName }
        if movable.isEmpty {
            writeMarker(marker, dest: dest)
            return false
        }

        do {
            try FileSecurity.ensureProtectedDirectory(dest)
        } catch {
            Diagnostics.logError(
                context: "B-0096 migration: could not create user namespace for \(uid)",
                error: error,
                persistToDisk: false
            )
            return false
        }

        var movedCount = 0
        for src in movable {
            let target = dest.appendingPathComponent(src.lastPathComponent)
            // Don't clobber anything already present in the destination.
            if fm.fileExists(atPath: target.path) { continue }
            do {
                try fm.moveItem(at: src, to: target)
                movedCount += 1
            } catch {
                Diagnostics.logError(
                    context: "B-0096 migration: move failed for \(src.lastPathComponent)",
                    error: error,
                    persistToDisk: false
                )
            }
        }

        // Only mark complete when nothing movable is left at the source — a failed
        // move leaves the entry behind and we retry next launch (already-moved
        // entries are skipped via the fileExists check above).
        let remaining = movable.contains { fm.fileExists(atPath: $0.path) }
        if !remaining {
            writeMarker(marker, dest: dest)
        }
        Diagnostics.logInfo("B-0096 migration moved \(movedCount) legacy entries into Users/\(uid) (remaining: \(remaining))")
        return movedCount > 0
    }

    private static func writeMarker(_ marker: URL, dest: URL) {
        try? FileSecurity.ensureProtectedDirectory(dest)
        try? Data().write(to: marker)
    }

    /// Removes every entry directly under the legacy shared root EXCEPT the
    /// `Users/` container — i.e. all pre-B-0096 un-namespaced data. Used only to
    /// finish an account deletion that was interrupted on a PRE-fix build: the
    /// orphaned data is un-namespaced, so the per-UID wipe (which targets a
    /// `Users/<uid>` namespace) would never reach it, leaving residual PII past
    /// Account Deletion (5.1.1(v)). Never touches any user's namespace.
    static func wipeLegacyUnnamespacedData() {
        let fm = FileManager.default
        let legacyRoot = FilePaths.legacySharedRoot
        guard let entries = try? fm.contentsOfDirectory(
            at: legacyRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for entry in entries where entry.lastPathComponent != FilePaths.usersContainerName {
            try? fm.removeItem(at: entry)
        }
    }
}
