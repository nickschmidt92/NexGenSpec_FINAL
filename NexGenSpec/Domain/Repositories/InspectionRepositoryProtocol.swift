//
//  InspectionRepositoryProtocol.swift
//  NexGenSpec
//
//  Abstraction for inspection and version persistence. Implemented by Infrastructure.
//

import Foundation

/// Protocol for inspection and version persistence. All I/O is async.
///
/// **Bridge note:** Current app uses `InspectionVersion` (Models.swift) with `VersionStatus` and `locked`.
/// Implementations map that to `InspectionState` when building `VersionMetadata`. When Domain entities
/// are fully rebuilt, `InspectionVersion` will carry `state: InspectionState` directly.
public protocol InspectionRepositoryProtocol: Sendable {

    /// List all versions (metadata only). Used for dashboard.
    func loadVersionList() async throws -> [VersionMetadata]

    /// Load full version by ID. Returns nil if not found.
    func loadVersion(id: UUID) async throws -> InspectionVersion?

    /// Persist draft version. Only valid when version is editable (not locked).
    func saveDraft(_ version: InspectionVersion) async throws

    /// Write immutable snapshot and update index to finalized state. Called by FinalizationService only.
    func finalizeVersion(_ version: InspectionVersion, packageHash: String) async throws

    /// Create new draft version that is a revision of the given finalized version.
    func createRevision(fromVersionId: UUID) async throws -> InspectionVersion?

    /// Update version state (e.g. awaiting signatures). Still editable.
    func updateVersionState(versionId: UUID, state: InspectionState) async throws
}
