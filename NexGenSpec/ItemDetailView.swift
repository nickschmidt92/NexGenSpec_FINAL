//
//  ItemDetailView.swift
//  NexGenSpec
//
//  Full item edit: status, defect, location, observed, implication, recommendation,
//  inspector comments, contractor, and photo attach/edit/annotate.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ItemDetailView: View {
    @Binding var item: InspectionItem
    var jobId: UUID
    var isLocked: Bool

    @State private var selectedImages: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var photoToAnnotate: InspectionPhoto?
    @State private var pendingAnnotationPhoto: InspectionPhoto?
    @State private var photoToDelete: InspectionPhoto?
    @State private var showDeleteConfirmation = false
    @State private var draggedPhoto: InspectionPhoto?
    @State private var importingCount = 0
    @State private var importedSoFar = 0

    // AI defect detection state
    @State private var suggestedDefectTags: [String] = []
    @State private var detectingPhotoId: UUID?
    // The photo the current suggestions belong to, so an accepted tag lands on
    // the analyzed photo rather than whatever happens to be last in the array.
    @State private var suggestedDefectPhotoId: UUID?
    // Number of photos that failed to import in the last library pick, surfaced
    // so a partial import isn't silently reported as a full "N/N" success.
    @State private var importFailureCount = 0
    @State private var showImportError = false

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
            // Editable title — required for custom items (which start as
            // "New Item") and useful for template items the inspector
            // wants to rename. Beta feedback 2026-04-24:
            // "you can't update the title — needs an editable field."
            // Locked once the inspection is finalized.
            Section {
                TextField("Item title", text: bind(\.title))
                    .font(.headline)
                    .disabled(isLocked)
                    .submitLabel(.done)
            } header: {
                Text("Title")
            }

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
                    .accessibilityIdentifier("observedEditor")   // UI-test hook (autosave E2E)
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
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.sm) {
                            ForEach(item.photos) { photo in
                                VStack(spacing: 4) {
                                    AsyncThumbnailView(jobId: jobId, photo: photo, size: CGSize(width: 100, height: 100))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(alignment: .topTrailing) {
                                            // Always-visible trash button (not just
                                            // in the long-press context menu).
                                            // Original UX hid delete behind a
                                            // long-press → testers thought it
                                            // couldn't be done at all.
                                            if !isLocked {
                                                Button {
                                                    photoToDelete = photo
                                                    showDeleteConfirmation = true
                                                } label: {
                                                    Image(systemName: "trash.circle.fill")
                                                        .font(.title3)
                                                        .foregroundStyle(.white, .red)
                                                        .shadow(radius: 1)
                                                }
                                                .padding(4)
                                                .accessibilityLabel("Delete photo")
                                            }
                                        }
                                        .onTapGesture {
                                            guard !isLocked else { return }
                                            photoToAnnotate = photo
                                        }
                                    if !isLocked {
                                        Text("Tap to annotate")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contextMenu {
                                    if !isLocked {
                                        Button(role: .destructive) {
                                            photoToDelete = photo
                                            showDeleteConfirmation = true
                                        } label: {
                                            Label("Delete Photo", systemImage: "trash")
                                        }
                                    }
                                }
                                .onDrag {
                                    draggedPhoto = photo
                                    return NSItemProvider(object: photo.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: PhotoDropDelegate(
                                    targetPhoto: photo,
                                    draggedPhoto: $draggedPhoto,
                                    photos: Binding(
                                        get: { item.photos },
                                        set: { newPhotos in
                                            var copy = item
                                            copy.photos = newPhotos
                                            item = copy
                                        }
                                    )
                                ))
                            }
                            if !isLocked {
                                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                    Button {
                                        showCamera = true
                                    } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: "camera.fill")
                                                .font(.system(size: 44))
                                                .foregroundStyle(AppColor.accent)
                                            Text("Capture photo")
                                                .font(.caption)
                                        }
                                        .frame(width: 100, height: 100)
                                        .background(AppColor.surface)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain).hoverEffect(.lift)
                                    .accessibilityLabel("Capture photo with camera")
                                }
                                PhotosPicker(selection: $selectedImages, maxSelectionCount: 20, matching: .images) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "photo.on.rectangle.angled")
                                            .font(.system(size: 44))
                                            .foregroundStyle(AppColor.accent)
                                        Text("Import from Library")
                                            .font(.caption)
                                    }
                                    .frame(width: 100, height: 100)
                                    .background(AppColor.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .onChange(of: selectedImages) { _, newItems in
                                    guard !newItems.isEmpty else { return }
                                    importingCount = newItems.count
                                    importedSoFar = 0
                                    Task { @MainActor in
                                        var failures = 0
                                        for pickerItem in newItems {
                                            if let data = try? await pickerItem.loadTransferable(type: Data.self),
                                               let saved = await saveImportedPhoto(from: data) {
                                                let photo = InspectionPhoto(fileName: saved.fileName, sortOrder: item.photos.count)
                                                var copy = item
                                                copy.photos.append(photo)
                                                item = copy
                                                PhotoLoadService.shared.generateThumbnailIfNeeded(jobId: jobId, fileName: saved.fileName)
                                                runDefectDetection(image: saved.image, photoId: photo.id)
                                            } else {
                                                // Decode/transfer/write failed — count it so the
                                                // user is told, instead of the progress hitting
                                                // "N/N" as if every photo imported (silent drop).
                                                failures += 1
                                            }
                                            importedSoFar += 1
                                        }
                                        selectedImages = []
                                        importingCount = 0
                                        importedSoFar = 0
                                        if failures > 0 {
                                            importFailureCount = failures
                                            showImportError = true
                                        }
                                    }
                                }
                                if importingCount > 0 {
                                    VStack(spacing: 4) {
                                        ProgressView(value: Double(importedSoFar), total: Double(importingCount))
                                            .frame(width: 80)
                                        Text("\(importedSoFar)/\(importingCount)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(width: 100, height: 100)
                                    .background(AppColor.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
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

            // AI Defect Detection suggestions
            if !isLocked && (!suggestedDefectTags.isEmpty || detectingPhotoId != nil) {
                Section {
                    if detectingPhotoId != nil {
                        HStack(spacing: Spacing.sm) {
                            ProgressView()
                            Text("Analyzing photo for defects...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !suggestedDefectTags.isEmpty {
                        Text("AI-suggested defect tags — tap to accept:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: 8) {
                            ForEach(suggestedDefectTags, id: \.self) { tag in
                                Button {
                                    acceptDefectTag(tag)
                                } label: {
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(AppColor.accentSoft)
                                        .foregroundStyle(AppColor.accent)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain).hoverEffect(.lift)
                            }
                        }
                        Button(role: .cancel) {
                            suggestedDefectTags = []
                            suggestedDefectPhotoId = nil
                        } label: {
                            Text("Dismiss All")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Defect Detection")
                }
            }

            // Show accepted defect tags on photos
            if item.photos.contains(where: { !$0.defectTags.isEmpty }) {
                Section {
                    ForEach(item.photos.filter({ !$0.defectTags.isEmpty })) { photo in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(photo.fileName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            FlowLayout(spacing: 6) {
                                ForEach(photo.defectTags, id: \.self) { tag in
                                    HStack(spacing: 4) {
                                        Text(tag)
                                            .font(.caption2)
                                        if !isLocked {
                                            Button {
                                                removeDefectTag(tag, from: photo)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.caption2)
                                            }
                                            .buttonStyle(.plain).hoverEffect(.lift)
                                            .accessibilityLabel("Remove defect tag \(tag)")
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.1))
                                    .foregroundStyle(.blue)
                                    .clipShape(Capsule())
                                }
                            }
                        }
                    }
                } header: {
                    Text("Accepted Defect Tags")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $photoToAnnotate) { photo in
            AsyncPhotoAnnotationSheet(jobId: jobId, photo: photo, onSaveOverlay: { overlay in
                AnnotationStore.save(overlay, jobId: jobId, photoId: photo.id)
                PhotoLoadService.shared.regenerateAnnotatedThumbnail(jobId: jobId, photo: photo)
            })
        }
        .alert("Delete Photo", isPresented: $showDeleteConfirmation, presenting: photoToDelete) { photo in
            Button("Delete", role: .destructive) {
                deletePhoto(photo)
            }
            Button("Cancel", role: .cancel) {
                photoToDelete = nil
            }
        } message: { _ in
            Text("Are you sure you want to delete this photo? This action cannot be undone.")
        }
        .alert("Some Photos Didn't Import", isPresented: $showImportError) {
            Button("OK") { showImportError = false }
        } message: {
            Text("\(importFailureCount) photo\(importFailureCount == 1 ? "" : "s") couldn't be imported — they may be in an unsupported format or corrupted. The rest were added.")
        }
        .sheet(isPresented: $showCamera, onDismiss: {
            if let photo = pendingAnnotationPhoto {
                pendingAnnotationPhoto = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    photoToAnnotate = photo
                }
            }
        }) {
            CameraCaptureView(
                onCapture: { image in
                    showCamera = false
                    Task { @MainActor in
                        if let fileName = await savePhoto(image) {
                            let photo = InspectionPhoto(fileName: fileName, sortOrder: item.photos.count)
                            var copy = item
                            copy.photos.append(photo)
                            item = copy
                            PhotoLoadService.shared.generateThumbnailIfNeeded(jobId: jobId, fileName: fileName)
                            pendingAnnotationPhoto = photo
                            runDefectDetection(image: image, photoId: photo.id)
                        }
                    }
                },
                onCancel: { showCamera = false }
            )
        }
    }

    /// Downscales + JPEG-encodes + writes a captured photo OFF the main thread,
    /// returning the saved filename. Full-res lossless PNG on the main actor was
    /// a watchdog (0x8badf00d) + OOM risk for 48MP photos; the report only needs
    /// a reasonable resolution. Mirrors the cover-photo path (T-01441).
    private func savePhoto(_ image: UIImage) async -> String? {
        let name = UUID().uuidString + ".jpg"
        let url = FilePaths.photosFolder(jobId: jobId).appendingPathComponent(name)
        let data: Data? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let resized = image.resizedKeepingAspect(maxSide: 3024)
                continuation.resume(returning: resized.jpegData(compressionQuality: 0.85))
            }
        }
        return writePhotoData(data, to: url, name: name)
    }

    /// Library-import variant: decodes the picked data, downscales, JPEG-encodes
    /// and writes — ALL off the main thread — so a 20-photo import never decodes
    /// or encodes a full-res image on the main actor. Returns the filename and
    /// the downscaled image (for thumbnail / defect detection) (T-01441).
    private func saveImportedPhoto(from data: Data) async -> (fileName: String, image: UIImage)? {
        let name = UUID().uuidString + ".jpg"
        let url = FilePaths.photosFolder(jobId: jobId).appendingPathComponent(name)
        let result: (Data, UIImage)? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let image = UIImage(data: data) else { continuation.resume(returning: nil); return }
                let resized = image.resizedKeepingAspect(maxSide: 3024)
                guard let jpeg = resized.jpegData(compressionQuality: 0.85) else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: (jpeg, resized))
            }
        }
        guard let (jpeg, resized) = result, writePhotoData(jpeg, to: url, name: name) != nil else { return nil }
        return (name, resized)
    }

    /// Writes already-encoded photo data with file protection. Returns the name
    /// on success, nil on failure (logged).
    private func writePhotoData(_ data: Data?, to url: URL, name: String) -> String? {
        guard let data else { return nil }
        do {
            try FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
            try FileSecurity.writeProtected(data, to: url, options: [.atomic])
            return name
        } catch {
            Diagnostics.logError(context: "savePhoto write failed", error: error)
            return nil
        }
    }

    private func deletePhoto(_ photo: InspectionPhoto) {
        // Remove the photo file from disk
        let photoURL = FilePaths.photosFolder(jobId: jobId).appendingPathComponent(photo.fileName)
        try? FileManager.default.removeItem(at: photoURL)
        // Remove the thumbnail from disk
        let thumbURL = FilePaths.thumbnailsFolder(jobId: jobId).appendingPathComponent(photo.fileName)
        try? FileManager.default.removeItem(at: thumbURL)
        // Propagate the thumbnail deletion to CloudKit (D-0203). The full-res photo
        // removal above is NOT emitted — photos don't sync.
        SyncCoordinator.noteMediaDeleted(
            jobId: jobId,
            relativePath: "Inspections/\(jobId.uuidString)/thumbnails/\(photo.fileName)")
        // Remove annotation if any
        let annotationURL = FilePaths.annotationFile(jobId: jobId, photoId: photo.id)
        try? FileManager.default.removeItem(at: annotationURL)
        // Remove from model
        var copy = item
        copy.photos.removeAll { $0.id == photo.id }
        // Re-number sortOrder
        for i in copy.photos.indices {
            copy.photos[i].sortOrder = i
        }
        item = copy
        photoToDelete = nil
    }

    // MARK: - AI Defect Detection

    /// Runs Vision-based defect detection on the given image in the background.
    /// When results arrive, populates suggestedDefectTags for the inspector to review.
    private func runDefectDetection(image: UIImage, photoId: UUID) {
        detectingPhotoId = photoId
        Task {
            let tags = await DefectDetectionService.shared.detectDefects(in: image)
            await MainActor.run {
                detectingPhotoId = nil
                if !tags.isEmpty {
                    // Only show tags not already accepted on this photo
                    let existingTags = Set(item.photos.first(where: { $0.id == photoId })?.defectTags ?? [])
                    let newTags = tags.filter { !existingTags.contains($0) }
                    if !newTags.isEmpty {
                        suggestedDefectTags = newTags
                        suggestedDefectPhotoId = photoId
                    }
                }
            }
        }
    }

    /// Accept a suggested defect tag and attach it to the photo the suggestions
    /// were generated from (not whatever is currently last in the array — the
    /// analyzed photo isn't necessarily the most recent one).
    private func acceptDefectTag(_ tag: String) {
        guard let targetId = suggestedDefectPhotoId,
              let idx = item.photos.firstIndex(where: { $0.id == targetId }) else {
            // Target photo is gone (e.g. deleted) — drop the stale suggestions.
            suggestedDefectTags.removeAll { $0 == tag }
            if suggestedDefectTags.isEmpty { suggestedDefectPhotoId = nil }
            return
        }
        var copy = item
        if !copy.photos[idx].defectTags.contains(tag) {
            copy.photos[idx].defectTags.append(tag)
        }
        item = copy
        suggestedDefectTags.removeAll { $0 == tag }
        if suggestedDefectTags.isEmpty { suggestedDefectPhotoId = nil }
    }

    /// Remove a defect tag from a specific photo.
    private func removeDefectTag(_ tag: String, from photo: InspectionPhoto) {
        var copy = item
        if let idx = copy.photos.firstIndex(where: { $0.id == photo.id }) {
            copy.photos[idx].defectTags.removeAll { $0 == tag }
        }
        item = copy
    }
}

/// Drag-and-drop delegate for reordering photos in the horizontal scroll.
private struct PhotoDropDelegate: DropDelegate {
    let targetPhoto: InspectionPhoto
    @Binding var draggedPhoto: InspectionPhoto?
    @Binding var photos: [InspectionPhoto]

    func performDrop(info: DropInfo) -> Bool {
        draggedPhoto = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedPhoto,
              dragged.id != targetPhoto.id,
              let fromIndex = photos.firstIndex(where: { $0.id == dragged.id }),
              let toIndex = photos.firstIndex(where: { $0.id == targetPhoto.id }) else { return }
        withAnimation(.default) {
            photos.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
            // Update sortOrder to persist ordering
            for i in photos.indices {
                photos[i].sortOrder = i
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
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
                    .foregroundStyle(.secondary)
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

// MARK: - FlowLayout (wrapping horizontal layout for tags)

/// A simple wrapping layout that places subviews left-to-right, wrapping to a
/// new line when the available width is exceeded.  Uses the iOS 16+ Layout protocol.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentY += lineHeight + spacing
                currentX = 0
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, currentX - spacing)
        }
        totalHeight = currentY + lineHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentY += lineHeight + spacing
                currentX = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
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
