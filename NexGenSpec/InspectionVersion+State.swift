//
//  InspectionVersion+State.swift
//  NexGenSpec
//
//  Bridges VersionStatus + locked to InspectionState. Persisted JSON unchanged.
//

import Foundation

extension InspectionVersion {

    /// Single source of truth for lifecycle. Derived from status + locked for backward compatibility.
    public var state: InspectionState {
        if locked {
            return .finalized(versionId: inspectionVersionId)
        }
        switch status {
        case .draft:
            return .draft
        case .final:
            return .finalized(versionId: inspectionVersionId)
        }
    }

    /// Whether this version can be edited (items, photos, signatures).
    public var isEditable: Bool {
        state.isEditable
    }
}
