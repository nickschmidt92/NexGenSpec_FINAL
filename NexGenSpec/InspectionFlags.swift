//
//  InspectionFlags.swift
//  NexGenSpec
//
//  UserDefaults-backed soft flags for an inspection's lifecycle —
//  invoice sent, invoice paid, archived. Kept out of the persisted
//  Inspection JSON so existing TestFlight drafts don't need a
//  migration. Lost if the user reinstalls the app, which is the
//  same trade-off InvoiceAndSendView already accepts.
//

import Foundation
import SwiftUI

public enum InspectionFlags {

    // MARK: - Keys

    private static func sentAtKey(_ inspectionId: String) -> String {
        "invoice.sentAt.\(inspectionId)"
    }

    private static func paidAtKey(_ inspectionId: String) -> String {
        "invoice.paidAt.\(inspectionId)"
    }

    private static func archivedAtKey(_ inspectionId: String) -> String {
        "inspection.archivedAt.\(inspectionId)"
    }

    // MARK: - Reads

    public static func invoiceSentAt(inspectionId: String) -> Date? {
        UserDefaults.standard.object(forKey: sentAtKey(inspectionId)) as? Date
    }

    public static func invoicePaidAt(inspectionId: String) -> Date? {
        UserDefaults.standard.object(forKey: paidAtKey(inspectionId)) as? Date
    }

    public static func archivedAt(inspectionId: String) -> Date? {
        UserDefaults.standard.object(forKey: archivedAtKey(inspectionId)) as? Date
    }

    public static func isArchived(inspectionId: String) -> Bool {
        archivedAt(inspectionId: inspectionId) != nil
    }

    // MARK: - Writes

    public static func setArchived(_ archived: Bool, inspectionId: String) {
        let key = archivedAtKey(inspectionId)
        if archived {
            UserDefaults.standard.set(Date(), forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Bulk clear (account deletion)

    /// Removes every per-inspection soft flag from UserDefaults. Called during
    /// the Account Deletion wipe (App Store Guideline 5.1.1(v)): these keys live
    /// OUTSIDE `FilePaths.appRoot`, so the on-disk wipe alone leaves them behind
    /// and contradicts the "no copies retained" guarantee. Matches on the key
    /// prefixes rather than enumerating inspection IDs (which are gone once the
    /// files are deleted), so it also sweeps up any orphaned flags. (T-01412)
    ///
    /// Deliberately scoped to the `invoice.*` / `inspection.archivedAt.*` /
    /// `ngs.fallbackEmail.*` / `NexGenSpec.calendar.*` prefixes — it must NOT
    /// clear the `deletion-pending-wipe` retry flag, which has to survive the
    /// wipe until it actually completes. The `invoice.` prefix covers
    /// sentAt/paidAt as well as the persisted amounts (price/services/total)
    /// added in T-01440; the `ngs.fallbackEmail.` prefix is the inspector's
    /// recovery-email PII (T-01445); the `NexGenSpec.calendar.` prefix covers
    /// CalendarPreferences (default-calendar id + auto-add flag), whose keys are
    /// suffixed with the user's email — residual PII otherwise left behind on
    /// Delete Account.
    public static func clearAll() {
        let defaults = UserDefaults.standard
        // `nexgenspec.profile.` is the inspector's own identity (name / company /
        // license / phone / email) — auto-filled on inspections, CC'd on invoices,
        // printed on client reports. The normal delete path clears it via
        // InspectorProfile.clear(), but the force-quit recovery wipe doesn't, so
        // sweeping the prefix here makes every disk-wipe path self-contained and
        // closes the residual-PII gap regardless of which path runs (5.1.1(v)).
        let prefixes = ["invoice.", "inspection.archivedAt.", "ngs.fallbackEmail.", "NexGenSpec.calendar.", "nexgenspec.profile."]
        for key in defaults.dictionaryRepresentation().keys
        where prefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Badge state machine

/// Visual state shown on the Workspace home row. Derived from the
/// inspection's lifecycle (draft / locked) plus the soft invoice
/// flags. See InspectionFlags for the source of truth.
public enum InspectionBadge: String {
    case draft
    case finalized
    case invoiced
    case paid

    public var label: String {
        switch self {
        case .draft:     return "Draft"
        case .finalized: return "Finalized"
        case .invoiced:  return "Invoiced"
        case .paid:      return "Paid"
        }
    }

    public var systemImage: String {
        switch self {
        case .draft:     return "square.and.pencil"
        case .finalized: return "lock.fill"
        case .invoiced:  return "envelope.fill"
        case .paid:      return "checkmark.seal.fill"
        }
    }

    public var color: Color {
        switch self {
        case .draft:     return AppColor.warning
        case .finalized: return AppColor.brandBlue
        case .invoiced:  return Color.purple
        case .paid:      return AppColor.success
        }
    }
}

extension VersionMetadata {

    /// Single-state badge for the workspace row. Paid wins over
    /// invoiced wins over finalized wins over draft.
    public var badge: InspectionBadge {
        let id = inspectionId.uuidString
        if InspectionFlags.invoicePaidAt(inspectionId: id) != nil {
            return .paid
        }
        if InspectionFlags.invoiceSentAt(inspectionId: id) != nil {
            return .invoiced
        }
        if locked || status == .final {
            return .finalized
        }
        return .draft
    }

    public var isArchived: Bool {
        InspectionFlags.isArchived(inspectionId: inspectionId.uuidString)
    }
}
