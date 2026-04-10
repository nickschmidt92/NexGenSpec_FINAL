//
//  ItemDetailView.swift
//  NexGenSpec
//
//  Full item edit: status, defect, location, observed, implication, recommendation,
//  inspector comments, contractor, and photo attach/edit/annotate.
//

import SwiftUI
import PhotosUI

struct ItemDetailView: View {
    @Binding var item: InspectionItem
    var jobId: UUID
    var isLocked: Bool

    @State private var selectedImages: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var photoToAnnotate: InspectionPhoto?

    private func bind<T>(_ keyPath: WritableKeyPath<InspectionItem, T>) -> Binding<T> {
        Binding(
            get: { item[keyPath: keyPath] },
            set: { newValue in
                var copy = item
                copy[keyPath: keyPath] = newValue
                item = copy
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Status", selection: bind(\.status)) {
                    ForEach(ItemStatus.allCases, id: \.self) { status in
                        Text(status.displayName).tag(status)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isLocked)
                Toggle("Include in Report", isOn: bind(\.includeInReport))
                    .disabled(isLocked)
            } header: {
                Text("Status")
            }

            if item.status == .inspected {
                Section {
                    Picker("Defect Severity", selection: bind(\.defectSeverity)) {
                        Text("None").tag(Severity?.none)
                        ForEach(Severity.allCases, id: \.self) { s in
                            Text(s.displayName).tag(Severity?.some(s))
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isLocked)
                } header: {
                    Text("Defect Severity")
                }
            }

            Section {
                TextField("Location in property", text: bind(\.location))
                    .textContentType(.location)
                    .disabled(isLocked)
            } header: {
                Text("Location")
            }

            Section {
                TextEditor(text: bind(\.observed))
                    .frame(minHeight: 88)
                    .overlay(alignment: .topLeading) {
                        if item.observed.isEmpty && !isLocked {
                            Text("Describe what you observed (e.g. crack, leak, wear).")
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(isLocked)
            } header: {
                Text("Observed")
            } footer: {
                Text("What you observed at this item.")
            }

            Section {
                TextEditor(text: bind(\.implication))
                    .frame(minHeight: 88)
                    .overlay(alignment: .topLeading) {
                        if item.implication.isEmpty && !isLocked {
                            Text("What this finding means for the client.")
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(isLocked)
            } header: {
                Text("Implication")
            } footer: {
                Text("What this finding means.")
            }

            Section {
                TextEditor(text: bind(\.recommendation))
                    .frame(minHeight: 88)
                    .overlay(alignment: .topLeading) {
                        if item.recommendation.isEmpty && !isLocked {
                            Text("Recommended action (e.g. repair, monitor, replace).")
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(isLocked)
            } header: {
                Text("Recommendation")
            } footer: {
                Text("Recommended action.")
            }

            Section {
                TextEditor(text: bind(\.inspectorComments))
                    .frame(minHeight: 72)
                    .overlay(alignment: .topLeading) {
                        if item.inspectorComments.isEmpty && !isLocked {
                            Text("Additional notes or context.")
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(isLocked)
            } header: {
                Text("Inspector Comments")
            } footer: {
                Text("Additional notes or context.")
            }

            Section {
                TextField("Contractor or trade", text: bind(\.contractorTag))
                    .textContentType(.organizationName)
                    .disabled(isLocked)
            } header: {
                Text("Contractor")
            }

            Section {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Tap a photo to annotate; capture or add from library.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.sm) {
                            ForEach(item.photos) { photo in
                                VStack(spacing: 4) {
                                    AsyncThumbnailView(jobId: jobId, photo: photo, size: CGSize(width: 100, height: 100))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .onTapGesture {
                                            guard !isLocked else { return }
                                            photoToAnnotate = photo
                                        }
                                    if !isLocked {
                                        Text("Tap to annotate")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            if !isLocked {
                                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                    Button {
                                        showCamera = true
                                    } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: "camera.fill")
                                                .font(.system(size: 44))
                                                .foregroundColor(.accentColor)
                                            Text("Capture photo")
                                                .font(.caption)
                                        }
                                        .frame(width: 100, height: 100)
                                        .background(Color(.systemGray6))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Capture photo with camera")
                                }
                                PhotosPicker(selection: $selectedImages, maxSelectionCount: 1, matching: .images) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "photo.on.rectangle.angled")
                                            .font(.system(size: 44))
                                            .foregroundColor(.accentColor)
                                        Text("Add from library")
                                            .font(.caption)
                                    }
                                    .frame(width: 100, height: 100)
                                    .background(Color(.systemGray6))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .onChange(of: selectedImages) { _, newItems in
                                    Task { @MainActor in
                                        for pickerItem in newItems {
                                            if let data = try? await pickerItem.loadTransferable(type: Data.self),
                                               let uiImage = UIImage(data: data),
                                               let fileName = savePhoto(uiImage) {
                                                let photo = InspectionPhoto(fileName: fileName, sortOrder: item.photos.count)
                                                var copy = item
                                                copy.photos.append(photo)
                                                item = copy
                                                PhotoLoadService.shared.generateThumbnailIfNeeded(jobId: jobId, fileName: fileName)
                                            }
                                        }
                                        selectedImages = []
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md))
            } header: {
                Text("Photos")
            } footer: {
                Text("\(item.photos.count) photo(s). Capture with camera or add from library; tap to draw or mark up.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $photoToAnnotate) { photo in
            AsyncPhotoAnnotationSheet(jobId: jobId, photo: photo, onSaveOverlay: { overlay in
                AnnotationStore.save(overlay, jobId: jobId, photoId: photo.id)
            })
        }
        .sheet(isPresented: $showCamera) {
            CameraCaptureView(
                onCapture: { image in
                    if let fileName = savePhoto(image) {
                        let photo = InspectionPhoto(fileName: fileName, sortOrder: item.photos.count)
                        var copy = item
                        copy.photos.append(photo)
                        item = copy
                        PhotoLoadService.shared.generateThumbnailIfNeeded(jobId: jobId, fileName: fileName)
                    }
                    showCamera = false
                },
                onCancel: { showCamera = false }
            )
        }
    }

    private func savePhoto(_ image: UIImage, fileName: String? = nil) -> String? {
        let name = fileName ?? UUID().uuidString + ".png"
        let url = FilePaths.photosFolder(jobId: jobId).appendingPathComponent(name)
        do {
            try FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
            if let data = image.pngData() {
                try FileSecurity.writeProtected(data, to: url, options: [.atomic])
                return name
            }
        } catch {
            Diagnostics.logError(context: "savePhoto failed", error: error)
        }
        return nil
    }
}

/// Loads full image off main thread then presents PencilKit annotation (vector overlay). Saves overlay only; bake at export.
private struct AsyncPhotoAnnotationSheet: View {
    var jobId: UUID
    var photo: InspectionPhoto
    var onSaveOverlay: (AnnotationOverlay) -> Void

    @State private var fullImage: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let img = fullImage {
                PencilKitPhotoAnnotationView(
                    baseImage: img,
                    initialOverlay: AnnotationStore.load(jobId: jobId, photoId: photo.id),
                    onSave: onSaveOverlay
                )
            } else if failed {
                Text("Could not load photo.")
                    .foregroundColor(.secondary)
            } else {
                ProgressView("Loading…")
            }
        }
        .task {
            let img = await PhotoLoadService.shared.loadFullImage(jobId: jobId, photo: photo)
            await MainActor.run {
                fullImage = img
                if img == nil { failed = true }
            }
        }
    }
}

#if DEBUG
struct ItemDetailView_Previews: PreviewProvider {
    static var previews: some View {
        let item = InspectionItem(
            templateItemId: "preview",
            title: "Cracked Foundation",
            status: .inspected,
            defectSeverity: .major,
            location: "Basement",
            observed: "Crack along north wall",
            implication: "Structural instability",
            recommendation: "Consult structural engineer",
            contractorTag: "Foundation Contractor",
            photos: []
        )
        ItemDetailView(item: .constant(item), jobId: UUID(), isLocked: false)
    }
}
#endif
