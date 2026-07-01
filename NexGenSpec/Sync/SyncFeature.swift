//
//  SyncFeature.swift
//  NexGenSpec
//
//  Master gate for CloudKit sync. DEFAULT ON in Release (cross-device iCloud
//  sync across the user's own devices); users opt OUT via Local-Only mode.
//
//  When `effectiveSyncAllowed` is false (Local-Only mode on, signed out, or a
//  DEBUG build with the dev toggle off) the app constructs a `NoopSyncPort`
//  everywhere — no CloudKit code runs and no identity binding is read or written.
//  This is the single switch the implementation slices build behind (see
//  docs/design/build-22-cloudkit-sync.md §6).
//

import Foundation

enum SyncFeature {

    /// Master switch. DEFAULT ON in Release — cross-device iCloud sync ships live;
    /// users opt out via Local-Only mode (see `effectiveSyncAllowed`). In DEBUG
    /// builds the in-app dev toggle (`devEnabledKey`, surfaced in Settings) gates
    /// it so sync can be exercised against the Development CloudKit environment
    /// deliberately.
    static var isEnabled: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: devEnabledKey)
        #else
        return true
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

    // MARK: - In-app "multi-device" copy (flag-aware)
    //
    // The binary itself tells the user whether inspections sync between devices.
    // The "no sync" copy becomes FALSE the moment sync is on, so each string is
    // gated on the master switch here to stay truthful in every flag state (build
    // 22 slice 5; design §18). In Release sync is DEFAULT ON, so the iCloud-sync
    // copy is what users normally see; the "no sync" branch only shows in a DEBUG
    // build with the dev toggle off. AUTHORITATIVE legal wording is the B-0118
    // website + attorney track; these strings are the in-app mirror only.

    /// Privacy-policy "Multi-Device" clause.
    static var multiDeviceLegalClause: String {
        isEnabled
        ? "When you turn on iCloud Sync, your inspections sync across your own devices through your private iCloud account (Apple's CloudKit). They go only to your iCloud — NexGenSpec never receives or stores them. With iCloud Sync off, or in Local-Only mode, inspections stay on the device they were created on; use the Files-app export to move them between your devices intentionally."
        : "NexGenSpec stores inspections on the device they were created on. Inspections do NOT sync between devices. Use the Files-app export feature to move inspections between your own devices intentionally."
    }

    /// Backup-status "on this device" row subtitle.
    static var multiDeviceBackupSubtitle: String {
        isEnabled
        ? "With iCloud Sync on, your inspections sync across your own devices through your private iCloud account. With it off, each device holds its own independent set — use the Files-app export to move records between your devices."
        : "Inspections do NOT sync between devices. Each iPad you use holds its own independent set. Use the Files-app export inside an inspection to move records between your own devices."
    }

    /// Terms-of-Use "Multi-device note" — the Terms counterpart of the privacy
    /// clause above; gated in lockstep so the two screens never contradict.
    static var multiDeviceTermsClause: String {
        isEnabled
        ? "Multi-device note. With iCloud Sync on, your inspections sync across your own devices through your private iCloud account; NexGenSpec never receives or stores them. With sync off or in Local-Only mode, inspections stay on the device they were created on — use the export-to-Files feature to move records intentionally."
        : "Multi-device note. NexGenSpec inspections live on the device they were created on and do NOT sync between devices. Treat each device as an independent silo. Use the export-to-Files feature to move records intentionally."
    }

    /// Backup-status "Local-First" banner. With sync on, iCloud provides a
    /// cross-device copy (still your private iCloud, not our servers), so the
    /// flat "device only / cannot recover" claim no longer holds.
    static var localFirstBannerText: String {
        isEnabled
        ? "Your inspections, photos, signatures, and reports stay under your control. With iCloud Sync on, they sync across your own devices through your private iCloud account; NexGenSpec never keeps server-side copies. Sync is not a backup — keep your own backups, as deletions sync between your devices."
        : "All inspections, photos, signatures, and reports are stored on this device only. NexGenSpec does NOT keep server-side copies and cannot recover lost data."
    }

    /// One-sentence "where your data lives" for the in-app Settings/Terms, flag-aware so
    /// it never contradicts the sync state. (Authoritative legal wording is the B-0118
    /// attorney track; this is the in-app mirror.)
    static var dataLocationClause: String {
        isEnabled
        ? "NexGenSpec syncs your inspections across your own Apple devices through your private iCloud account; NexGenSpec keeps no server-side copy. Turn on Local-Only mode to keep inspections on the device that created them."
        : "NexGenSpec is a local-first application. Inspection data lives ONLY on the device that created it. NexGenSpec does not maintain server-side copies of any inspection content."
    }
}
