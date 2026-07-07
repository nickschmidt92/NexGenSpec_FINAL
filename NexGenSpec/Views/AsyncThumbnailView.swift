//
//  AsyncThumbnailView.swift
//  NexGenSpec
//
//  Lazy async thumbnail for inspection photos. No main-thread disk I/O.
//

import SwiftUI

/// Displays a thumbnail loaded asynchronously via PhotoLoadService. Use in grids/lists for 300+ photos.
struct AsyncThumbnailView: View {
    var jobId: UUID
    var photo: InspectionPhoto
    var size: CGSize = CGSize(width: 80, height: 80)

    @State private var image: UIImage?
    @State private var loadTask: Task<Void, Never>?
    @State private var reloadToken: UUID = UUID()
    @State private var didFinishLoading = false

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if didFinishLoading {
                // Loaded but no image: the full-resolution original isn't on this
                // device (it stays on the device that captured it — only the record,
                // report, thumbnail, and floor plans sync). Show a neutral placeholder
                // instead of an infinite spinner.
                Rectangle()
                    .fill(Color(.systemGray6))
                    .overlay(
                        Image(systemName: "photo.on.rectangle.angled")
                            .foregroundStyle(.secondary)
                    )
            } else {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .overlay(ProgressView())
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .cornerRadius(6)
        .task(id: "\(jobId)-\(photo.id)-\(reloadToken)") {
            let img = await PhotoLoadService.shared.loadThumbnail(jobId: jobId, photo: photo)
            await MainActor.run {
                image = img
                didFinishLoading = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailDidUpdate)) { notification in
            if let updatedId = notification.userInfo?["photoId"] as? UUID, updatedId == photo.id {
                didFinishLoading = false   // reset to loading before the reload
                reloadToken = UUID()
            }
        }
    }
}
