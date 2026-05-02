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
