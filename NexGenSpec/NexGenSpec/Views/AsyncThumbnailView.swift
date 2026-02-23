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

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .overlay(ProgressView())
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .cornerRadius(6)
        .task(id: "\(jobId)-\(photo.id)") {
            let img = await PhotoLoadService.shared.loadThumbnail(jobId: jobId, photo: photo)
            await MainActor.run { image = img }
        }
    }
}
