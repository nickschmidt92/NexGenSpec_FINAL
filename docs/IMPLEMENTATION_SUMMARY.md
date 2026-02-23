# NexGenSpec — Evolution Implementation Summary

Surgical, upgrade-in-place changes applied. All phases implemented.

---

## Phase 1 — Architectural Audit

- **Created:** `docs/PHASE1_ARCHITECTURAL_AUDIT.md`  
- Documents: current MV-like pattern, business logic in views, loose state (booleans), large data in ViewModels, main-thread media load, re-render risks with file references.

---

## Phase 2 — Strict Inspection State Machine

- **`Domain/ValueTypes/InspectionState.swift`** — Enum: `draft`, `awaitingCustomerSignature`, `awaitingInspectorSignature`, `finalized(versionId)`, `revised(previousVersionId)` with `isEditable`, `isFinalized`, `displayName`.
- **`Application/Services/InspectionStateMachine.swift`** — `transitionToFinalized`, `canCreateRevision`, `allowsEdit`.
- **`InspectionVersion+State.swift`** — Computed `state: InspectionState` and `isEditable` from existing `VersionStatus` + `locked` (no JSON change).
- **`InspectionStore.swift`** — `finalize`, `createRevision`, `update` now go through state machine; no direct status/locked mutation.
- **`FinalizeView.swift`** — No longer mutates version; calls `onFinalize(version)` so the store performs the transition.
- **`InspectionOverviewView.swift`** — Status badge uses `version.state.displayName` and state-based styling.

---

## Phase 3 — Media Performance Hardening

- **`Services/PhotoLoadService.swift`** — Async thumbnail and full-image load on a background queue; generates thumbnails on first access and after add.
- **`Views/AsyncThumbnailView.swift`** — SwiftUI view that loads thumbnails via `PhotoLoadService` in a `.task`.
- **`ItemDetailView.swift`** — Photo strip uses `AsyncThumbnailView`; annotation sheet uses `AsyncPhotoAnnotationSheet` which loads full image async; new photos trigger `generateThumbnailIfNeeded`. No sync `Data(contentsOf:)` on main.

---

## Phase 4 — Apple Pencil Annotation Engine

- **`Models/AnnotationOverlay.swift`** — Codable overlay: `drawingData` (PencilKit), `arrows`, `circles` with color names.
- **`Services/AnnotationStore.swift`** — Load/save overlay per photo at `FilePaths.annotationFile(jobId:photoId:)`.
- **`Views/PencilKitPhotoAnnotationView.swift`** — PencilKit canvas (pressure-sensitive) + arrow/circle tools; green/yellow/red; saves `AnnotationOverlay` only (no photo overwrite).
- **`ItemDetailView.swift`** — Annotation sheet uses `PencilKitPhotoAnnotationView` with `initialOverlay` from `AnnotationStore` and `onSaveOverlay` writing to `AnnotationStore`. No baked image save; bake at export (report engine can be extended).

---

## Phase 5 — LiDAR Integration

- **`Models/LiDARScan.swift`** — `LiDARScan` (id, versionId, usdzFileName, floorplanPNGFileName, measurements, capturedAt) and `Measurement`.
- **`Services/LiDARCapability.swift`** — `isSupported` via `ARWorldTrackingConfiguration.supportsSceneReconstruction` (feature gate).
- **`Services/LiDARScanStore.swift`** — Save/load scan metadata under `FilePaths.lidarFolder(jobId:)`.  
- **`FilePaths.swift`** — Already had `lidarFolder`; `ensureAppStructure` creates it.  
- RoomPlan capture UI and USDZ/floorplan generation can be added on top of this.

---

## Phase 6 — Finalization + Hash System

- **`FilePaths.swift`** — `versionsFolder(jobId:)`, `versionSnapshotFile(jobId:versionId:)`. `ensureAppStructure` creates `versions` folder.
- **`Services/FinalizationService.swift`** — `writeSnapshot(_ version)` encodes version (sorted keys), computes SHA256, writes `FinalizedVersionSnapshot` (version + reportHash + finalizedAt) atomically; `loadReportHash(jobId:versionId)` for report footer.
- **`InspectionStore.finalize`** — After state transition, calls `FinalizationService.writeSnapshot(versions[idx])`.

---

## Phase 7 — Report Engine Upgrade

- **`HTMLReportRenderer.swift`** — Reworked: card layout, summary badges, section cards, draft watermark when `version.state.isEditable`, report hash in footer when finalized (via `FinalizationService.loadReportHash`), responsive/dark-mode-friendly CSS, lazy-loading for images.  
- Export still uses existing `PDFReportRenderer`; for 300+ photos run HTML generation on a background queue before PDF.

---

## Phase 8 — Visual System Upgrade

- **`Design/DesignSystem.swift`** — `Spacing` (xxs–xl), `AppColor`, `TouchTarget.minHeight`, `CardStyle` modifier, `.inspectionCard()`.

---

## Phase 9 — Legal Hardening

- **`TermsAndConditionsView.swift`** — NexGenSpec disclaimer at top (reporting software only; separate from D.I.A.); optional logo; `AuditLog.log(event: "Terms and Conditions accepted")` on Accept.
- **`Models.swift`** — `InspectionSignature` extended with `deviceId: String?`.
- **`SignatureView.swift`** — Saves `deviceId = UIDevice.current.identifierForVendor?.uuidString` with each signature.
- Draft watermark in report (Phase 7). Audit log export already available via existing `AuditLog.read()` and share in T&C view.

---

## Phase 10 — Future Scalability

- **`Application/AppCapabilities.swift`** — `SubscriptionTier`, `SyncContext`, `AppCapabilities` (currentTier, syncContext, canUseLiDAR, canUseAISummary) as extension points for cloud sync, teams, AI, subscriptions.

---

## New Files (add to Xcode if not using folder sync)

- `Domain/ValueTypes/InspectionState.swift`
- `Domain/Repositories/InspectionRepositoryProtocol.swift` (optional; for future repo abstraction)
- `Application/Services/InspectionStateMachine.swift`
- `Application/AppCapabilities.swift`
- `InspectionVersion+State.swift`
- `Services/PhotoLoadService.swift`
- `Services/AnnotationStore.swift`
- `Services/LiDARCapability.swift`
- `Services/LiDARScanStore.swift`
- `Services/FinalizationService.swift`
- `Models/AnnotationOverlay.swift`
- `Models/LiDARScan.swift`
- `Views/AsyncThumbnailView.swift`
- `Views/PencilKitPhotoAnnotationView.swift`
- `Design/DesignSystem.swift`

---

## Xcode Checklist

1. **PencilKit** — Link the PencilKit framework (Target → General → Frameworks).
2. **CryptoKit** — Used by `FinalizationService` (part of Apple SDK).
3. **ARKit** — Used by `LiDARCapability` (optional; gate with `#if canImport(ARKit)`).
4. If the project uses a **synchronized root group** for the app folder, new files under `NexGenSpec/` are picked up automatically.

---

## Optional Next Steps

- **Report annotation baking:** When generating HTML/PDF, for each photo with an `AnnotationOverlay`, load photo + overlay, composite (e.g. render PKDrawing + shapes onto image), and embed the result. `AnnotationStore.load` + custom compositor.
- **RoomPlan capture:** Implement capture flow using RoomPlan API; write USDZ to `lidar/`, optional floorplan PNG; save metadata via `LiDARScanStore`.
- **Export on background:** Call `HTMLReportRenderer.renderHTML` and `PDFReportRenderer.generatePDF` from a background queue and show a progress indicator so UI never blocks.
