import SwiftUI

/// Displays a grid of images (and optionally video thumbnails) efficiently.
/// Use init(jobId:photos:...) for inspection photos (PhotoLoadService thumbnails); use init(mediaURLs:...) for URLs.
struct LazyMediaGrid: View {
    var mediaURLs: [URL] = []
    var jobId: UUID?
    var photos: [InspectionPhoto] = []
    var showsVideoIndicator: Bool = true
    var columns: [GridItem] = [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 8)]
    var onItemTap: ((URL) -> Void)?
    var onPhotoTap: ((InspectionPhoto) -> Void)?

    init(mediaURLs: [URL], showsVideoIndicator: Bool = true, columns: [GridItem] = [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 8)], onItemTap: ((URL) -> Void)? = nil) {
        self.mediaURLs = mediaURLs
        self.jobId = nil
        self.photos = []
        self.showsVideoIndicator = showsVideoIndicator
        self.columns = columns
        self.onItemTap = onItemTap
        self.onPhotoTap = nil
    }

    init(jobId: UUID, photos: [InspectionPhoto], columns: [GridItem] = [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 8)], onPhotoTap: ((InspectionPhoto) -> Void)? = nil) {
        self.mediaURLs = []
        self.jobId = jobId
        self.photos = photos
        self.showsVideoIndicator = false
        self.columns = columns
        self.onItemTap = nil
        self.onPhotoTap = onPhotoTap
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                if let jobId = jobId, !photos.isEmpty {
                    ForEach(photos) { photo in
                        AsyncThumbnailView(jobId: jobId, photo: photo, size: CGSize(width: 120, height: 120))
                            .onTapGesture { onPhotoTap?(photo) }
                            .accessibilityLabel(photo.caption.isEmpty ? "Photo" : photo.caption)
                    }
                } else {
                    ForEach(mediaURLs, id: \.self) { url in
                    ZStack(alignment: .center) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            case .failure:
                                Image(systemName: "photo")
                                    .resizable()
                                    .scaledToFit()
                                    .foregroundColor(.secondary)
                                    .padding(24)
                            @unknown default:
                                AppColor.surface
                            }
                        }
                        .frame(width: 120, height: 120)
                        .background(AppColor.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(Text(url.lastPathComponent))
                        .onTapGesture {
                            onItemTap?(url)
                        }
                        if showsVideoIndicator && url.pathExtension.lowercased().contains("mp4") {
                            Image(systemName: "play.circle.fill")
                                .resizable()
                                .frame(width: 40, height: 40)
                                .foregroundColor(.white)
                                .shadow(radius: 4)
                        }
                    }
                }
                }
            }
            .padding()
        }
    }
}

#Preview {
    // Demo URLs (replace with real photo/video URLs in app)
    let imageURLs = (1...16).map { _ in URL(string: "https://picsum.photos/200")! }
    let videoURLs = [URL(string: "https://samplelib.com/mp4/sample-5s.mp4")!]
    let sampleMedia = imageURLs + videoURLs
    LazyMediaGrid(mediaURLs: sampleMedia)
}
