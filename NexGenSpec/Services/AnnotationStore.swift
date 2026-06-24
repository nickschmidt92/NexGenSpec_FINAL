//
//  AnnotationStore.swift
//  NexGenSpec
//
//  Load/save annotation overlays to disk. One file per photo.
//

import Foundation

enum AnnotationStore {

    static func load(jobId: UUID, photoId: UUID) -> AnnotationOverlay? {
        let url = FilePaths.annotationFile(jobId: jobId, photoId: photoId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AnnotationOverlay.self, from: data)
    }

    /// Writes the annotation overlay to protected storage. Returns true only if
    /// the bytes reached disk — a swallowed write silently lost the inspector's
    /// markup while the sheet dismissed as if saved (mirrors SignatureStore).
    @discardableResult
    static func save(_ overlay: AnnotationOverlay, jobId: UUID, photoId: UUID) -> Bool {
        let url = FilePaths.annotationFile(jobId: jobId, photoId: photoId)
        do {
            try FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
            let data = try JSONEncoder().encode(overlay)
            try FileSecurity.writeProtected(data, to: url)
            return true
        } catch {
            Diagnostics.logError(context: "Annotation overlay save failed", error: error)
            return false
        }
    }
}

