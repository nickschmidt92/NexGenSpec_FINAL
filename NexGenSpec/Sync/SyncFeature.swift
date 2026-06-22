//
//  SyncFeature.swift
//  NexGenSpec
//
//  Master gate for CloudKit sync (build 22). OFF by default.
//
//  While `isEnabled` is false the app constructs a `NoopSyncPort` everywhere and
//  behaves EXACTLY like build 21 — no CloudKit code runs, no identity binding is
//  read or written. Flipping sync on is a deliberate, reversible act: it is the
//  single switch the implementation slices build behind (see
//  docs/design/build-22-cloudkit-sync.md §6).
//

import Foundation

enum SyncFeature {

    /// Master switch. Hard OFF for slice 1 (scaffold only). Later slices flip this
    /// (or back it with a build config / remote flag) once the real CloudKit port
    /// exists and the schema is deployed. Computed (not a stored `let`) so callers
    /// that branch on it don't trip "will never be executed" dead-code warnings as
    /// the wiring lands in later slices.
    static var isEnabled: Bool { false }

    /// UserDefaults key for the user-facing "Local only" privacy mode. When set,
    /// sync is force-disabled even if `isEnabled` is true and iCloud is available
    /// — for NDA / privacy users. Fail-closed: local-only wins.
    static let localOnlyModeKey = "ngs.sync.localOnlyMode"

    /// Whether the user has opted into local-only mode. Default false (no opt-in
    /// surfaced yet in slice 1; the key simply reads false until a settings toggle
    /// writes it).
    static var isLocalOnlyMode: Bool {
        UserDefaults.standard.bool(forKey: localOnlyModeKey)
    }

    /// The only condition under which any sync may run on this device. Combines the
    /// master switch with local-only mode. CKAccountStatus + a valid binding are
    /// checked separately by the live port (later slices); this is the static gate.
    static var effectiveSyncAllowed: Bool {
        isEnabled && !isLocalOnlyMode
    }
}
