//
//  InspectionState.swift
//  NexGenSpec
//
//  Strict inspection lifecycle state. All transitions enforced in Application layer.
//

import Foundation

/// Inspection version lifecycle. No view or store may mutate this; only InspectionStateMachine/Use Cases.
public enum InspectionState: Equatable, Codable, Sendable {

    /// Editable; signatures not yet required.
    case draft

    /// Signatures being collected; optional substep.
    case awaitingCustomerSignature

    /// Signatures being collected; optional substep.
    case awaitingInspectorSignature

    /// Locked; this version is the finalized report. versionId is this version's ID.
    case finalized(versionId: UUID)

    /// This version is a revision of a previous finalized version. previousVersionId links back.
    case revised(previousVersionId: UUID)

    // MARK: - Helpers

    public var isEditable: Bool {
        switch self {
        case .draft, .awaitingCustomerSignature, .awaitingInspectorSignature:
            return true
        case .finalized, .revised:
            return false
        }
    }

    public var isFinalized: Bool {
        switch self {
        case .finalized, .revised:
            return true
        case .draft, .awaitingCustomerSignature, .awaitingInspectorSignature:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .draft: return "Draft"
        case .awaitingCustomerSignature: return "Awaiting Customer Signature"
        case .awaitingInspectorSignature: return "Awaiting Inspector Signature"
        case .finalized: return "Finalized"
        case .revised: return "Revised"
        }
    }
}
