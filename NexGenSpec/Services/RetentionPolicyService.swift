import Foundation

public enum RetentionPolicyService {
    public struct PurgeResult {
        public var deletedInspectionIDs: [UUID]
        public var skippedInspectionIDs: [UUID]

        public init(deletedInspectionIDs: [UUID], skippedInspectionIDs: [UUID]) {
            self.deletedInspectionIDs = deletedInspectionIDs
            self.skippedInspectionIDs = skippedInspectionIDs
        }
    }

    public static func purgeExpiredInspections(
        metadata: [VersionMetadata],
        now: Date = Date(),
        retentionYears: Int = 5,
        isAdmin: Bool,
        actorId: String?
    ) -> PurgeResult {
        guard isAdmin else {
            Diagnostics.logError(context: "Retention purge denied (non-admin)")
            return PurgeResult(deletedInspectionIDs: [], skippedInspectionIDs: metadata.map(\.id))
        }

        let cutoff = Calendar.current.date(byAdding: .year, value: -retentionYears, to: now) ?? now
        var deleted: [UUID] = []
        var skipped: [UUID] = []

        for m in metadata {
            guard let finalizedAt = m.finalizedAt, finalizedAt < cutoff else {
                skipped.append(m.id)
                continue
            }
            let folder = FilePaths.inspectionFolder(jobId: m.inspectionId)
            do {
                if FileManager.default.fileExists(atPath: folder.path) {
                    try FileManager.default.removeItem(at: folder)
                }
                deleted.append(m.id)
                AuditLog.log(event: "Retention purge deleted inspection", user: actorId, versionId: m.id, inspectionId: m.inspectionId)
            } catch {
                Diagnostics.logError(context: "Retention purge failed for \(m.id.uuidString)", error: error)
                skipped.append(m.id)
            }
        }

        return PurgeResult(deletedInspectionIDs: deleted, skippedInspectionIDs: skipped)
    }
}
