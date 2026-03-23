//
//  InspectionStateMachine.swift
//  NexGenSpec
//
//  Enforces valid inspection state transitions. Used by FinalizeInspectionUseCase and CreateRevisionUseCase only.
//

import Foundation

/// Result of attempting a state transition.
public enum StateTransitionResult {
    case success(InspectionState)
    case failure(reason: String)
}

/// Valid transitions for inspection version state. All mutation of version state must go through this.
public struct InspectionStateMachine {

    /// Validates and returns the next state for "finalize" action.
    /// - Parameters:
    ///   - current: Current state
    ///   - hasRequiredSignatures: Both inspector and client signatures present
    ///   - versionId: This version's UUID (used for .finalized)
    /// - Returns: .success(.finalized(versionId)) or .failure
    public static func transitionToFinalized(
        from current: InspectionState,
        hasRequiredSignatures: Bool,
        versionId: UUID
    ) -> StateTransitionResult {
        switch current {
        case .draft, .awaitingCustomerSignature, .awaitingInspectorSignature:
            guard hasRequiredSignatures else {
                return .failure(reason: "Both inspector and client signatures are required.")
            }
            return .success(.finalized(versionId: versionId))
        case .finalized, .revised:
            return .failure(reason: "Version is already finalized.")
        }
    }

    /// Validates and returns the new state for "create revision" action.
    /// The new version will be in .draft; this returns the state for the *existing* finalized version (unchanged).
    /// - Parameter current: Current state of the version being revised
    /// - Returns: .success(current) if revision is allowed (caller creates new draft with previousVersionId)
    public static func canCreateRevision(from current: InspectionState) -> StateTransitionResult {
        switch current {
        case .finalized, .revised:
            return .success(current)
        case .draft, .awaitingCustomerSignature, .awaitingInspectorSignature:
            return .failure(reason: "Only finalized versions can be revised.")
        }
    }

    /// Whether the given state allows editing (item/photo/signature updates).
    public static func allowsEdit(_ state: InspectionState) -> Bool {
        state.isEditable
    }
}
