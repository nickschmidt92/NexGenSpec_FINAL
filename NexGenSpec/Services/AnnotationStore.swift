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

    static func save(_ overlay: AnnotationOverlay, jobId: UUID, photoId: UUID) {
        let url = FilePaths.annotationFile(jobId: jobId, photoId: photoId)
        try? FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
        guard let data = try? JSONEncoder().encode(overlay) else { return }
        try? FileSecurity.writeProtected(data, to: url)
    }
}

