//
//  InspectionVersionSyncContent.swift
//  NexGenSpec
//
//  Sync-content equality for the phantom-edit-echo fix (B-0122 round 3).
//

import Foundation

extension InspectionVersion {

    /// Full value equality EXCEPT the device-bookkeeping fields that
    /// InspectionView mutates as a side effect of merely OPENING an
    /// inspection. Used by the teardown flush to decide whether a close is a
    /// genuine local edit (re-stamp the LWW clock, publish, push) or a
    /// bookkeeping-only close (persist file-only; never claim authorship).
    ///
    /// Why these fields — and ONLY these — are exempt (B-0122 round 3):
    /// every editable open runs `startTimer()` on appear and `pauseTimer()`
    /// on disappear/background, and may auto-fetch weather. Those paths
    /// mutate exactly three model fields; each mutation made the build-38
    /// dirty check (`draft != lastPersistedDraft`) pass on EVERY open→close,
    /// so simply viewing an inspection did a full `update()` → fresh
    /// `updatedAt` → push, echoing a possibly-stale copy over the zone with
    /// a NEWER last-writer-wins clock and overwriting the real editor's work
    /// on every other device ("whoever closes last wins").
    ///
    ///  - `inspection.timerStartDate` — seeded by `startTimer()` on first
    ///    open (`if nil { = Date() }`).
    ///  - `inspection.timerElapsedSeconds` — `pauseTimer()` folds the live
    ///    session into it on every disappear/background/finalize.
    ///  - `inspection.weather` — auto-fetched and seeded on open when nil.
    ///    Exempted as the WHOLE `WeatherData?` optional (all members), not
    ///    per-member: any weather value is bookkeeping.
    ///  - `updatedAt` — the version-level LWW clock itself: pure bookkeeping
    ///    by definition (it is stamped BY writes, it is not content), and a
    ///    future path that re-seeds `lastPersistedDraft` from a store-reloaded
    ///    copy would otherwise compare unequal with zero user edits.
    ///
    /// (`timerSessionStart`, the only other thing startTimer/pauseTimer
    /// touch, is view `@State` — not part of this model.) Everything else —
    /// every piece of report content — participates in the comparison: any
    /// diff there is a real edit and the LWW re-stamp is the correct behavior.
    public func syncContentEquals(_ other: InspectionVersion) -> Bool {
        var a = self
        var b = other
        // Normalize the exempt bookkeeping fields to fixed values on both
        // copies, then compare with full synthesized equality — so a newly
        // added model field is automatically CONTENT (compared), never
        // silently exempt.
        a.inspection.timerStartDate = nil
        b.inspection.timerStartDate = nil
        a.inspection.timerElapsedSeconds = 0
        b.inspection.timerElapsedSeconds = 0
        a.inspection.weather = nil
        b.inspection.weather = nil
        a.updatedAt = nil
        b.updatedAt = nil
        return a == b
    }
}
