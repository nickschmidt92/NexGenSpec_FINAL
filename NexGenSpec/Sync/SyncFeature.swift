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

    /// Master switch. Hard OFF in Release — sync ships dark. In DEBUG builds ONLY,
    /// an in-app dev toggle (`devEnabledKey`, surfaced in Settings) can flip it on
    /// to exercise sync against the Development CloudKit environment on real
    /// devices without shipping it. Release/TestFlight is compiled hard-OFF.
    static var isEnabled: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: devEnabledKey)
        #else
        return false
        #endif
    }

    /// DEBUG-only key backing the in-app dev sync toggle (compiled out of Release).
    static let devEnabledKey = "ngs.sync.devEnabled"

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
