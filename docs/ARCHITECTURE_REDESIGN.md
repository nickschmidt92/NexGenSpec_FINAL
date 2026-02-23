# NexGenSpec — Full System Architecture Redesign

**Document version:** 1.0  
**Date:** 2026-02-17  
**Scope:** iPadOS-primary, LiDAR-capable, offline-first home inspection reporting platform. Reporting software only; legally separate from D.I.A. Inspections.

---

## Executive Summary

This document defines a **complete architectural rebuild** of NexGenSpec from the current monolithic SwiftUI + single JSON-index design into a **modular Clean Architecture** system capable of 300+ photos, LiDAR, Apple Pencil annotations, cryptographic finalization, and future SaaS/cloud sync. All recommendations reference **actual files** in the current codebase and are implementable in phases.

---

## 1. COMPLETE ARCHITECTURE REDESIGN

### 1.1 Current State (Problems)

| Area | Current Implementation | Issue |
|------|------------------------|--------|
| **Persistence** | `InspectionStore.swift` — single `inspections.json`, load/save on init/mutate | No batching; main-thread I/O; entire version array in memory |
| **State** | `InspectionViewModel` + `@State var version` + `store.update(version)` | State duplicated (draft in view, canonical in store); no single source of truth |
| **Finalization** | `FinalizeView` mutates `version.status/locked/finalizedAt` then calls `onFinalize` | **State transition in view layer** — violates application-layer ownership |
| **Revisions** | `InspectionStore.createRevision(from:)` | No immutable snapshot; copy of inspection, no version chain |
| **Concurrency** | Synchronous `load()`/`save()` in Store; `loadImage()` in `ItemDetailView` sync `Data(contentsOf:)` | Main-thread disk I/O; no async boundaries |

**Files:** `InspectionStore.swift` (lines 30–54, 116–122, 144–147), `FinalizeView.swift` (59–65), `ItemDetailView.swift` (119–123).

### 1.2 Target: Clean Architecture Layers

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  PRESENTATION (SwiftUI)                                                      │
│  Dashboard • InspectionRoot • SectionSidebar • ItemDetail • Finalize • etc.  │
│  Views only: bind to ViewModels; no business logic, no direct Store use    │
└─────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  APPLICATION (Use Cases / Application Services)                              │
│  CreateInspection • UpdateItem • AddPhoto • FinalizeInspection • ExportReport│
│  InspectionStateMachine • FinalizationService • ReportExportOrchestrator    │
│  All state transitions and commands live here                                │
└─────────────────────────────────────────────────────────────────────────────┘
                                        │
                    ┌───────────────────┼───────────────────┐
                    ▼                   ▼                   ▼
┌──────────────────────┐  ┌──────────────────────┐  ┌──────────────────────┐
│  DOMAIN               │  │  DOMAIN               │  │  DOMAIN               │
│  Entities (pure)      │  │  Repository protocols │  │  Domain events        │
│  Inspection, Section, │  │  InspectionRepo       │  │  InspectionFinalized  │
│  Item, MediaAsset,    │  │  MediaAssetRepo      │  │  RevisionCreated      │
│  InspectionState      │  │  AuditEventRepo      │  │  PhotoAdded           │
└──────────────────────┘  └──────────────────────┘  └──────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  INFRASTRUCTURE                                                              │
│  FileSystemInspectionRepo • FileSystemMediaStore • DiskThumbnailCache       │
│  RoomPlanLiDARService • PencilKitAnnotationStore • AuditLogAppender          │
│  HTMLReportGenerator • PDFRenderPipeline                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 Folder Structure (Opinionated)

```
NexGenSpec/
├── App/
│   ├── NexGenSpecApp.swift
│   └── RootView.swift
├── Domain/
│   ├── Entities/
│   │   ├── Inspection.swift
│   │   ├── InspectionVersion.swift
│   │   ├── Section.swift
│   │   ├── Item.swift
│   │   ├── MediaAsset.swift
│   │   ├── AnnotationOverlay.swift
│   │   ├── LiDARScan.swift
│   │   ├── Measurement.swift
│   │   ├── Signature.swift
│   │   ├── AuditEvent.swift
│   │   └── ReportPackage.swift
│   ├── ValueTypes/
│   │   ├── InspectionState.swift
│   │   ├── Severity.swift
│   │   └── ItemStatus.swift
│   ├── Repositories/
│   │   ├── InspectionRepositoryProtocol.swift
│   │   ├── MediaAssetRepositoryProtocol.swift
│   │   ├── AuditEventRepositoryProtocol.swift
│   │   └── TemplateRepositoryProtocol.swift
│   └── Events/
│       └── InspectionDomainEvents.swift
├── Application/
│   ├── UseCases/
│   │   ├── CreateInspectionUseCase.swift
│   │   ├── UpdateItemUseCase.swift
│   │   ├── AddPhotoUseCase.swift
│   │   ├── FinalizeInspectionUseCase.swift
│   │   ├── CreateRevisionUseCase.swift
│   │   └── ExportReportUseCase.swift
│   ├── Services/
│   │   ├── InspectionStateMachine.swift
│   │   ├── FinalizationService.swift
│   │   └── ReportExportOrchestrator.swift
│   └── DI/
│       └── AppContainer.swift
├── Infrastructure/
│   ├── Persistence/
│   │   ├── FileSystemInspectionRepository.swift
│   │   ├── InspectionIndexStore.swift
│   │   └── VersionSnapshotStore.swift
│   ├── Media/
│   │   ├── FileSystemMediaStore.swift
│   │   ├── ThumbnailCacheEngine.swift
│   │   └── PhotoCompressionPipeline.swift
│   ├── LiDAR/
│   │   └── RoomPlanCaptureService.swift
│   ├── Annotations/
│   │   └── PencilKitAnnotationStore.swift
│   ├── Audit/
│   │   └── FileSystemAuditAppender.swift
│   └── Export/
│       ├── HTMLReportGenerator.swift
│       └── PDFRenderPipeline.swift
├── Presentation/
│   ├── Dashboard/
│   ├── Inspection/
│   │   ├── InspectionRootView.swift
│   │   ├── InspectionView.swift
│   │   ├── SectionSidebarView.swift
│   │   ├── SectionDetailView.swift
│   │   ├── ItemDetailView.swift
│   │   └── ItemListView.swift
│   ├── Finalize/
│   │   └── FinalizeView.swift
│   ├── Report/
│   │   └── ReportPreviewView.swift
│   ├── Shared/
│   │   ├── LazyMediaGrid.swift
│   │   └── DesignSystem/
│   └── ViewModels/
│       ├── InspectionViewModel.swift
│       └── DashboardViewModel.swift
├── Templates/
│   └── InspectionTemplate.json
└── Resources/
```

### 1.4 Dependency Injection Strategy

- **Single container:** `AppContainer` (in `Application/DI/`) holds all repository and service implementations.
- **Constructor injection** into Use Cases and ViewModels; no global singletons for core behavior.
- **Protocol-based:** Presentation and Application depend only on `InspectionRepositoryProtocol`, `MediaAssetRepositoryProtocol`, etc.
- **SwiftUI:** Inject container (or specific use-case factories) via `.environmentObject` or custom `EnvironmentKey` for previews and tests.

### 1.5 Inspection State Machine (Strict)

State transitions are **only** valid in the Application layer. See **Section 6** for the full enum and rules; the state machine is implemented in `InspectionStateMachine` and invoked by `FinalizeInspectionUseCase` and `CreateRevisionUseCase`. Views never set `status` or `locked` directly.

### 1.6 Event Sourcing for Audit Trail

- **Append-only event log** per inspection (or global): `AuditEvent` entities (see Section 2).
- **Domain events** emitted by Use Cases: `InspectionFinalized`, `RevisionCreated`, `PhotoAdded`, `ItemUpdated`, etc.
- **AuditEventRepository** appends events with timestamp, actor, versionId, and payload. No edits or deletes.
- **Rebuild of “current state”** is optional (e.g. for debugging); primary read path is still “current version snapshot” from `InspectionRepository`.

### 1.7 Immutable Version Snapshots

- On **finalize**, the Application layer writes a **snapshot** of the full inspection (version + inspection + metadata) to `versions/{versionId}.json` and never overwrites it.
- **Draft** state is the only mutable artifact; it lives in `draft.json` or in-memory with periodic persist.
- **Revision** creates a new versionId and new snapshot chain; `previousVersionId` links back.

### 1.8 Concurrency Boundaries

- **Main actor:** All SwiftUI views and ViewModels; UI updates only.
- **Background:** All repository reads/writes (disk), thumbnail generation, compression, export rendering, and LiDAR processing on a dedicated `actor` or serial queue (e.g. `StorageActor`, `ExportActor`).
- **Async/await:** Use Cases expose `async` methods; ViewModels call them with `Task { }` and update `@Published` on `@MainActor`.
- **No synchronous disk I/O** from views or ViewModels; all file access via async repository APIs.

### 1.9 Testing Strategy

- **Domain:** Unit tests on entities and state machine transitions (pure Swift).
- **Application:** Unit tests on Use Cases with in-memory/fake repositories.
- **Infrastructure:** Integration tests with temp directories for FileSystem repos and export pipeline.
- **Presentation:** UI tests for critical flows (create inspection, add photo, finalize); snapshot tests for design system components.

---

## 2. DATA MODEL REBUILD

### 2.1 Current Gaps (from `Models.swift`)

- **Inspection** uses `inspectionId: String` and `id: String` — standardize on **UUID** for sync.
- **InspectionVersion** has `VersionStatus.draft` / `.final` and `locked: Bool` — replace with **InspectionState** enum (Section 6).
- **InspectionPhoto**: only `fileName`; no `AnnotationOverlay` reference, no asset role (full vs compressed vs thumbnail).
- No **InspectionVersion** link to previous version (revision chain).
- **InspectionSignature**: stores `imageData: Data` in model — move to blob storage by signatureId; model holds only `signatureId`, `name`, `date`, `deviceId`, `captureMetadata`.
- No **AuditEvent**, **ReportPackage**, **LiDARScan**, **Measurement**, or **AnnotationOverlay** types.

### 2.2 Draft vs Final Immutable Model

- **Draft:** Mutable aggregate rooted at `InspectionVersion` (state `.draft` or `.awaitingCustomerSignature` / `.awaitingInspectorSignature`). Persisted to `draft.json` or equivalent; can be overwritten.
- **Final:** Immutable snapshot. Once state becomes `.finalized(versionId)` or `.revised(previousVersionId)`, the version payload is **never** modified. Stored in `versions/{versionId}.json` with optional hash in metadata.

### 2.3 Revision History Chain

- `InspectionVersion` gains `previousVersionId: UUID?`. Finalized version has `previousVersionId == nil` for first report, or the UUID of the version that was revised.
- Revisions are new versions (new UUID, new versionNumber); the chain is walked by following `previousVersionId` for audit/display.

### 2.4 Hashable Finalized Package

- **ReportPackage** (new): Represents the exact bundle that was finalized — inspection snapshot, list of asset IDs (photos + annotations), signatures, metadata.
- On finalization, serialize `ReportPackage` to canonical JSON (sorted keys, deterministic), compute **SHA256**, store hash in version metadata and in audit. Embed hash in report footer and optionally send to server for registration.

### 2.5 JSON Template Import Engine

- Keep **HeavyTemplate** / **HeavySection** / **HeavyItem** (from `TemplateImporter.swift`) as the **import DTO**.
- Add **schema version** in template JSON (e.g. `"templateSchemaVersion": 1`). Decoder uses it to support future migrations.
- **TemplateRepositoryProtocol** loads template; **CreateInspectionUseCase** converts HeavyTemplate → Domain entities (Section, Item) with **stable UUIDs** derived from template (e.g. seed from sectionId/itemId) so future sync can match.

### 2.6 Codable Schema Versioning

- All persisted domain entities include `schemaVersion: Int` in their CodingKeys. Decoder checks version and applies migrations (e.g. `schemaVersion 1 → 2`) before decoding into current model.

### 2.7 Stable UUID Strategy

- **Inspection:** `id: UUID` (jobId). Generated once at creation.
- **Section / Item:** UUIDs generated from template IDs (e.g. `UUID(namespace: inspectionId, name: sectionId)`) so re-import of same template yields same IDs for sync.
- **MediaAsset:** UUID at capture/import; never reused.
- **InspectionVersion:** New UUID per version (including revisions).

### 2.8 Append-Only Audit Events

- **AuditEvent:** `id`, `timestamp`, `versionId?`, `inspectionId`, `actorId?`, `action: String`, `payload: Data?` (JSON). Append-only; no update/delete API.

### 2.9 New / Revised Entity Sketches

```swift
// Domain/ValueTypes/InspectionState.swift
enum InspectionState: Equatable, Codable {
    case draft
    case awaitingCustomerSignature
    case awaitingInspectorSignature
    case finalized(versionId: UUID)
    case revised(previousVersionId: UUID)
}

// Domain/Entities/MediaAsset.swift
struct MediaAsset: Identifiable, Codable, Equatable {
    var id: UUID
    var role: MediaRole          // .full, .compressed, .thumbnail
    var fileName: String
    var caption: String
    var sortOrder: Int
    var annotationOverlayId: UUID?  // optional link to overlay
    var createdAt: Date
}
enum MediaRole: String, Codable { case full, compressed, thumbnail }

// Domain/Entities/AnnotationOverlay.swift
struct AnnotationOverlay: Identifiable, Codable, Equatable {
    var id: UUID
    var photoAssetId: UUID
    var pencilKitData: Data     // PencilKit PKDrawing or custom JSON
    var schemaVersion: Int
}

// Domain/Entities/LiDARScan.swift
struct LiDARScan: Identifiable, Codable, Equatable {
    var id: UUID
    var versionId: UUID
    var usdzFileName: String
    var floorplanPNGFileName: String?
    var measurements: [Measurement]
    var capturedAt: Date
}

// Domain/Entities/ReportPackage.swift
struct ReportPackage: Codable {
    var versionId: UUID
    var inspectionSnapshot: Inspection
    var assetIds: [UUID]
    var signatureIds: [UUID]
    var finalizedAt: Date
    var schemaVersion: Int
    // Hash computed at serialization time, not stored in this struct
}
```

---

## 3. PERFORMANCE WAR PLAN

### 3.1 Current Bottlenecks (with file references)

| Bottleneck | Location | Fix |
|------------|----------|-----|
| **State explosion** | `InspectionView` holds full `version` + `draft`; `store.versions` is full array in memory | Load only current version by ID; keep draft in Application layer or single source; paginate version list if needed |
| **Re-render loops** | `ForEach($draft.inspection.sections)` + bindings deep into items | Avoid binding entire version; use identifiers and command callbacks (e.g. `onItemUpdate(id, field, value)`) |
| **Main-thread violations** | `ItemDetailView.loadImage()` — `Data(contentsOf: url)` | All image load from disk on background; deliver UIImage on MainActor for display |
| **Disk I/O blocking** | `InspectionStore.load()` / `save()` synchronous | Move to async; batch writes with debounce (e.g. 500ms after last change) |
| **Memory with 300+ images** | `ItemDetailView` loads full UIImage per photo in horizontal list; `HTMLReportRenderer` base64 in memory | Never hold 300 full UIImages; thumbnails only in UI; export streams or batches |
| **Report export** | `HTMLReportRenderer.renderHTML` loads every photo via `loadPhotoData` into base64; `PDFReportRenderer` single-page formatter | Progressive export: generate HTML in chunks; embed images as file references or batch load; multi-page PDF with pagination |

**Files:** `InspectionView.swift` (17–30), `ItemDetailView.swift` (66–80, 119–124), `InspectionStore.swift` (30–54), `HTMLReportRenderer.swift` (50–52, 81–84), `PDFReportRenderer.swift` (14–25).

### 3.2 Async/Await Concurrency Model

- **Repositories:** All methods async (`func loadVersion(id: UUID) async throws -> InspectionVersion?`).
- **ViewModels:** Call use cases in `Task { await useCase.execute(...) }`; receive result and update `@Published` on MainActor.
- **Media load:** `MediaAssetRepository.loadThumbnail(assetId:) async -> UIImage?`; full-size only when needed (annotation, export).

### 3.3 Background Queue Isolation

- Introduce **StorageActor** (or serial DispatchQueue) for all file writes. All repository writes go through it; reads can be concurrent (multiple reads allowed).
- **ThumbnailCacheEngine** and **PhotoCompressionPipeline** run on background queue/actor; post results to MainActor for UI.

### 3.4 Lazy Loading Architecture

- **Version list:** Load metadata only (id, clientName, propertyAddress, status, date) from index; full version loaded on demand when user opens inspection.
- **Section/Item:** Already list-based; ensure no eager load of all item photos. Item detail loads photos for that item only.

### 3.5 Thumbnail Caching Engine

- **On-disk cache:** `photos/thumbnails/{assetId}.jpg` (or similar). Generated when photo is added or on first access.
- **In-memory cache:** NSCache or custom LRU keyed by assetId; cap total size (e.g. 100 MB). API: `func thumbnail(for assetId: UUID) async -> UIImage?`.
- **LazyMediaGrid** (and item photo strip) must use **thumbnail** URLs/loaders only, not full-size.

### 3.6 Disk Write Batching

- **Debounced save:** When draft changes, enqueue “save draft” with 300–500 ms debounce. Single write for multiple rapid edits.
- **Atomic writes:** Write to temp file then replace (already used in current `save()` with `.atomic`); extend to version snapshots.

### 3.7 Progressive UI Rendering

- **Lists:** Use `LazyVStack` / `LazyVGrid`; avoid building all rows up front.
- **Report preview:** If implemented, load HTML in chunks or use WKWebView with incremental load; avoid building one giant string with 300 base64 images.

### 3.8 Large Dataset Scrolling Strategy

- **LazyVGrid** with fixed cell size; reuse cells. Prefer `AsyncImage` or custom **ThumbnailAsyncImage** that uses ThumbnailCacheEngine.
- **ItemDetailView** photo strip: horizontal `LazyHStack` with thumbnail loader; full image only in annotation or full-screen viewer.

### 3.9 Performance Targets

| Metric | Target | How |
|--------|--------|-----|
| 60fps scrolling | Smooth list/grid | Lazy loading, thumbnail-only in grid, no sync work on main |
| &lt;200ms photo thumbnail load | Fast | On-disk thumbnail cache + in-memory LRU; generate in background on add |
| &lt;5s full report export | Acceptable | Background export, streamed/batched image embedding, multi-page PDF |
| Zero UI freeze during export | Non-blocking | Export on background actor; progress via Combine/async stream |
| Memory &lt;500MB peak | Bounded | No full-res in grid; limit decoded image count; release caches on warning |

---

## 4. LIDAR-FIRST ENGINEERING

### 4.1 Feature Gating

- **Check:** `ARWorldTrackingConfiguration.supportsSceneReconstruction` or device capability (LiDAR) before showing RoomPlan/LiDAR UI.
- **Non-LiDAR:** Hide “Capture Room” / “Add 3D Scan” entry points; show message that feature is available on LiDAR-capable iPads.

### 4.2 Capture Pipeline

- Use **RoomPlan** (RoomPlan API) to capture room; output **USDZ** + structured data (walls, doors, windows, dimensions).
- **RoomPlanCaptureService** (Infrastructure/LiDAR): encapsulates ARSession and RoomPlan builder; exposes async `captureRoom() -> LiDARScanResult` (USDZ URL, optional floorplan image, measurements).
- Store USDZ in `Documents/.../Inspections/{jobId}/lidar/{scanId}.usdz`.

### 4.3 Measurement Normalization

- **Measurement** entity: `id`, `scanId`, `type` (e.g. length, area), `value` (Double), `unit`, `label?`, `sourcePoint?`, `targetPoint?`.
- Normalize units (e.g. meters) in domain; display in user preference (ft/in or m).

### 4.4 USDZ Storage Strategy

- One USDZ per scan; filename `{scanId}.usdz`. Metadata (measurements, capture date) in `lidar/{scanId}_meta.json` or inside a companion JSON in same folder.

### 4.5 Floorplan PNG Export

- From RoomPlan or USDZ, generate top-down floorplan as PNG (e.g. via custom render or system APIs). Store as `lidar/{scanId}_floorplan.png`; reference in **LiDARScan** entity.

### 4.6 Thumbnail Generation

- Generate a thumbnail for the scan (e.g. first frame or floorplan) and store in `lidar/thumbnails/{scanId}.jpg` for list/preview.

### 4.7 Structured Measurement Storage

- **LiDARScan.measurements** array persisted with scan; included in report export (e.g. “Room dimensions” section or table).

### 4.8 Failure Recovery

- If capture fails (user cancels, session error), discard partial data; do not write incomplete USDZ. Log to audit.

### 4.9 Background Processing Isolation

- RoomPlan capture runs on main (ARKit requirement); post-processing (USDZ write, thumbnail, measurements extract) on background actor.

### 4.10 Export Requirements

- **Report:** Embed floorplan PNG in HTML/PDF; add “3D Model” section with link to USDZ (e.g. “View 3D model: [filename]” or secure link if uploaded). Do not embed USDZ in PDF (size); optional separate share of USDZ.
- **Professional presentation:** Clean section title “Floor Plan & 3D Scan”, thumbnail + link.

---

## 5. APPLE PENCIL OPTIMIZED ANNOTATION ENGINE

### 5.1 Current Limitation (`PhotoAnnotationView.swift`)

- Custom **Canvas** + **DragGesture** strokes; no PencilKit. No pressure, no native Pencil latency optimization.
- **Rasterizes on save** and overwrites file — violates “annotations create new, linked versions; never overwrite original.”
- No persistent **vector overlay**; no undo/redo stack.

### 5.2 Redesign: PencilKit + Vector Overlay

- Use **PencilKit** (`PKCanvasView`) for drawing. Get **PKDrawing** data; store as **AnnotationOverlay** (PKDrawing serialized or custom JSON of strokes).
- **Non-destructive:** Original photo remains; overlay stored in `annotations/{photoAssetId}.json` (or by overlayId). Export-time **rasterization** bakes overlay onto a copy for report/PDF.

### 5.3 Stroke Smoothing & Pressure

- PencilKit provides pressure and smoothing. Use default or tuned **PKInkingTool** (pen, pencil). No custom point smoothing required if PencilKit is used.

### 5.4 Undo/Redo Stack

- **PKDrawing** supports undo via **PKCanvasView**’s undo manager. Expose Undo/Redo buttons in UI and connect to `undoManager`.

### 5.5 Non-Destructive JSON Storage

- **AnnotationOverlay** model: `id`, `photoAssetId`, `pencilKitData: Data` (PKDrawing.dataRepresentation()) or custom JSON schema for strokes (if you need cross-platform). Version the schema for future compatibility.

### 5.6 Export-Time Rasterization

- During report export, for each photo that has an overlay: load full-size image + overlay; render composited image to temp file; embed that in report. Original + overlay remain separate on disk.

### 5.7 Multi-Layer Editing

- Single overlay per photo is sufficient for v1. Multiple layers (e.g. multiple PKDrawings) can be added later with `overlayLayers: [AnnotationOverlay]` and composite order.

### 5.8 Gesture Conflict Prevention

- Use **PKCanvasView** in a way that allows Pencil to draw and finger to pan/zoom (e.g. `drawingGestureRecognizer` for Pencil only, or use `allowsFingerDrawing = false` so finger doesn’t draw). Separate pan/zoom gesture for canvas.

### 5.9 Tools: Arrow, Circle, Freeform, Colors

- PencilKit supports pen/pencil; **arrow** and **circle** can be implemented as custom **PKTool** or as separate “shape” layer (vector shapes in JSON) drawn on top of PKDrawing. Colors: green / yellow / red — use **PKInkingTool** with those colors.

### 5.10 Zero Lag on Large Images

- **Large image tiling:** For very large photos (e.g. 4K), use tiled drawable (e.g. split into tiles, load visible tiles only) or downsample for canvas and store overlay in **normalized coordinates** (0–1) so overlay scales to full resolution at export.

### 5.11 Implementation Note

- Replace current `PhotoAnnotationView` with a wrapper around **UIViewControllerRepresentable** for **PKCanvasView**; load **AnnotationOverlay** from repository when opening; on save, write **PKDrawing.dataRepresentation()** to **AnnotationOverlay** and persist via **AnnotationRepository** (or **MediaAssetRepository** with overlay link).

---

## 6. STRICT INSPECTION STATE MACHINE

### 6.1 Enum Definition

```swift
enum InspectionState: Equatable, Codable {
    case draft
    case awaitingCustomerSignature
    case awaitingInspectorSignature
    case finalized(versionId: UUID)
    case revised(previousVersionId: UUID)
}
```

- **draft:** Editable; no signatures required yet.
- **awaitingCustomerSignature** / **awaitingInspectorSignature:** Optional substates if you collect signatures in sequence; otherwise collapse to “signatures pending.”
- **finalized(versionId):** This version is locked; versionId is self.
- **revised(previousVersionId):** This version is a revision of the given version; both are immutable.

### 6.2 Rules

- **No edits** after finalization. Any edit attempt in UI is blocked; Application layer rejects mutations for non-draft states.
- **Revision** creates a **new** version (new UUID) in state **draft**, with `previousVersionId` set; the old version remains **finalized**.
- **State transitions** only in Application layer: `InspectionStateMachine.transition(from:to:)` or equivalent, called from **FinalizeInspectionUseCase** and **CreateRevisionUseCase**. Views never set `status` or `locked`.

### 6.3 Enforcement

- **InspectionRepository** (or **InspectionStateMachine**) checks state before any update. **UpdateItemUseCase** loads version; if state != .draft (and not .awaiting* if you allow minor edits there), return failure.
- **FinalizeView** only invokes **FinalizeInspectionUseCase**; the use case performs transition and snapshot write.

**Current violation:** `FinalizeView.finalize()` (lines 59–65) mutates `version` in the view. Remove that; replace with `finalizationService.finalize(versionId: version.id)` and let the service update the repo and emit events.

---

## 7. CRYPTO-GRADE FINALIZATION SYSTEM

### 7.1 Atomic Finalization Transaction

1. **Validate:** Signatures present, compliance checkbox (if any), state is draft.
2. **Create immutable snapshot:** Serialize current inspection + version metadata to **ReportPackage** (or equivalent snapshot DTO).
3. **Compute SHA256** of canonical JSON (sorted keys, no whitespace variance).
4. **Write snapshot** to `versions/{versionId}.json`.
5. **Write audit events:** `InspectionFinalized`, with hash and timestamp.
6. **Update index:** Set version state to `.finalized(versionId)` (and locked) in inspections index.
7. **Optional:** Send hash to server (registration endpoint) for external proof.

All steps in a single transactional flow; if any step fails, roll back (e.g. do not update index).

### 7.2 Embed Hash in Report Footer

- Every HTML/PDF report generated from a finalized version must include a footer line: e.g. “Report hash: SHA256:&lt;hex&gt;”. Allows recipient to verify integrity.

### 7.3 Signature Metadata

- For each **Signature**, store: `timestamp`, `deviceId` (e.g. identifierForVendor), optional `IP` if captured at signature time (e.g. when sync is available). Persist in Signature entity or in audit.

### 7.4 Hash Chain Across Revisions

- When creating a revision, the new version can store `previousVersionHash` in its metadata. Verification can walk the chain and ensure each version’s hash matches and links to previous.

### 7.5 Tampering Prevention

- Finalized snapshot file is **read-only** from app (open with no write). Hash is stored in metadata and in audit; any change to the file would invalidate the hash on next verification.

---

## 8. REPORT RENDERING ENGINE REDESIGN

### 8.1 Current Issues

- **HTMLReportRenderer:** Single blob of HTML; inline base64 images (memory spike); no template abstraction; no draft watermark; no sidebar; no section filtering.
- **PDFReportRenderer:** Single-page **UIMarkupTextPrintFormatter**; no pagination; poor for long reports.

### 8.2 Swift-Based HTML Templating

- Introduce a **template** (e.g. Swift string interpolation or a small DSL) for report structure: header, sidebar nav, main content sections, footer (with hash). Data passed as a struct; no Spectora-like layout copy.

### 8.3 Clean Card-Based Layout

- Each defect item as a **card** (title, severity badge, location, observed, implication, recommendation, photos). Summary at top (Safety / Major / Marginal / Minor counts). Responsive so it works on web and in WKWebView.

### 8.4 Sidebar Navigation

- Left sidebar with anchors to section IDs; smooth scroll or jump to section.

### 8.5 Section Filtering

- Optional filter (e.g. “Defects only” or by section) applied at data level before rendering; same template, smaller payload.

### 8.6 Summary Auto-Generation

- Summary block at top: counts by severity (already in domain); optional “Key findings” sentence list derived from high-severity items.

### 8.7 Asset Bundling Pipeline

- **Export pipeline:** Build list of asset IDs (photos + annotated composites); generate thumbnails or report-sized images in temp folder; reference in HTML as relative paths (e.g. `assets/photo_1.jpg`). Zip or directory for “report package” export.

### 8.8 Photo Annotation Baking

- For each photo with **AnnotationOverlay**, render composited image to temp file; use that in report. Never expose raw overlay format in client-facing report.

### 8.9 Progressive Export Pipeline

- **ReportExportOrchestrator:** Step 1 — gather data; Step 2 — generate HTML in chunks (e.g. section by section); Step 3 — resolve images (batch load, write to assets); Step 4 — produce PDF from HTML (multi-page) or use PDFKit for direct multi-page PDF. Progress callback for UI (e.g. “Generating… 2/5 sections”).

### 8.10 Responsive Web Design

- CSS media queries; readable on iPad and desktop browser. Use system font stack; neutral + accent color from Design System.

### 8.11 Draft Watermark

- When generating report for a **draft** version (e.g. preview), overlay “DRAFT — NOT FINAL” watermark on every page or in header.

---

## 9. VISUAL SYSTEM REDESIGN

### 9.1 Color System

- **Neutral:** Gray scale for backgrounds and text (adapt to light/dark).
- **Accent:** Single modern accent (e.g. blue or teal) for primary actions and key highlights. Severity colors: Safety (red), Major (orange), Marginal (yellow), Minor (green) — keep distinct and accessible.

### 9.2 Typography Scale

- Define a small set of text styles: **Title**, **Headline**, **Body**, **Caption**, **Footnote**. Map to Dynamic Type; use **preferredFont(forTextStyle:)** or SwiftUI equivalents.

### 9.3 Spacing System

- 4pt base; 8, 12, 16, 24, 32. Use consistently for padding and gaps.

### 9.4 Card System

- Rounded corners (e.g. 12pt), subtle shadow, padding 16. Use for section cards, item cards, and report cards.

### 9.5 Large Touch Targets

- Minimum 44pt for interactive elements; generous tap areas for list rows and buttons (field inspection, gloved use).

### 9.6 Field Inspection Mode UI

- High-contrast, minimal chrome; large section/item titles; quick status toggles; camera/photo prominent. Optional “field mode” that hides sidebar and shows only current section + big buttons.

### 9.7 Dark Mode (Attic Safe)

- Full dark theme support; dimmed but readable in low light. Toggle or system-driven.

### 9.8 High Contrast Mode

- Respect **Accessibility → Display → Increase Contrast**; optionally increase severity color contrast and borders.

### 9.9 Dynamic Type

- All labels and body text scale with user text size preference.

### 9.10 One-Handed Usage

- On iPhone, primary actions reachable at bottom or thumb zone; consider tab bar or bottom toolbar for key actions.

### 9.11 Magic Keyboard Shortcuts

- iPad: Define **keyCommands** for New Inspection, Save, Finalize, Next/Previous Section, etc. Show in help overlay or menu.

---

## 10. OFFLINE-FIRST STORAGE ENGINE

### 10.1 File Structure (Target)

```
Documents/NexGenSpec/
├── index.json                    # List of version IDs + metadata only
├── Inspections/
│   └── {jobId}/
│       ├── metadata.json         # Inspection-level metadata
│       ├── draft.json            # Current draft (if any)
│       ├── versions/
│       │   └── {versionId}.json  # Immutable snapshots
│       ├── photos/
│       │   ├── full/
│       │   │   └── {assetId}.jpg
│       │   ├── compressed/
│       │   │   └── {assetId}.jpg  # Optional; for sync/upload
│       │   └── thumbnails/
│       │       └── {assetId}.jpg
│       ├── annotations/
│       │   └── {assetId}.json     # Overlay per photo
│       ├── lidar/
│       │   ├── {scanId}.usdz
│       │   ├── {scanId}_floorplan.png
│       │   └── thumbnails/
│       └── exports/
│           └── {exportId}/        # Optional; cached report bundles
├── audit/
│   └── events.jsonl or per-inspection events
└── templates/
    └── ...
```

- **Current** `FilePaths` already has `photosFolder`, `thumbnailsFolder`, `annotationFile`, `lidarFolder`. Extend to `photosFolder(jobId:role:)` (full/compressed/thumb) and add `versionsFolder`, `draftFile`, etc.

### 10.2 Store Photos on Disk, Not in Memory

- **MediaAsset** references `fileName` and `role`; repository loads bytes only when needed (thumbnail or full for export/annotation). No `UIImage` or `Data` in domain entity for photo content.

### 10.3 Background Compression

- After adding a full-res photo, enqueue job: generate compressed version (e.g. max 1920px, JPEG 85%) to `compressed/`; update asset metadata or separate manifest. Used for sync/upload to reduce bandwidth.

### 10.4 Thumbnail Generation

- On add (or on first access): generate thumbnail (e.g. 200px), write to `thumbnails/{assetId}.jpg`. ThumbnailCacheEngine uses this.

### 10.5 Disk Write Batching

- Draft saves debounced; version snapshot writes are single-shot. Use StorageActor to serialize all writes.

### 10.6 Crash-Safe Recovery

- Atomic writes (write to temp, then move); for draft, optional “last good” copy. On launch, if draft.json is missing or corrupt, fall back to last known good or prompt user.

### 10.7 Export Transaction Safety

- Export to temp directory; on success, move to final exports folder or share directly. No partial export visible to user.

### 10.8 Optional Purge of Full-Res After Upload

- Future: after successful cloud upload, optionally delete `full/` for that inspection to save space; keep thumbnails and compressed. Policy-driven (e.g. “Purge full-res after 30 days if uploaded”).

### 10.9 Support 300+ Photos

- No single directory listing of 300 files in one go if it’s slow; use manifest (e.g. `photos/manifest.json` with asset IDs and filenames) and load on demand. Thumbnail generation spread over time (background queue) so adding 300 photos doesn’t block.

---

## 11. LEGAL HARDENING

### 11.1 Mandatory Inspector Compliance Checkbox

- **Already present** in `DashboardView` new inspection sheet: “I confirm I am a licensed or authorized inspector…” — keep mandatory; create inspection only when checked. Log acceptance (e.g. AuditLog) with inspectionId and timestamp.

### 11.2 App-Level Terms & Conditions

- **TermsAndConditionsView** exists but is D.I.A. Inspections–branded. **Separate NexGenSpec:** Replace branding with “NexGenSpec” and generic “Reporting software terms”; remove D.I.A. website references from app UI. Keep a link to “Inspection agreement and photo policy” as a separate document (can still be D.I.A. content if that’s the inspection company, but app name and liability should state “NexGenSpec is reporting software only”).

### 11.3 Draft Watermark

- All draft report previews and exports show “DRAFT — NOT FINAL” clearly (see Section 8.11).

### 11.4 Audit Log Export

- **AuditLog** currently writes to single file; support export (e.g. share as .txt or .jsonl). Add structured **AuditEvent** export (timestamp, actor, action, versionId) for legal/compliance.

### 11.5 Data Retention Policy

- Document in app (Settings or Legal): e.g. “Inspection data retained for 5 years; you may export and delete.” Optional in-app purge after retention (admin-only or user with confirmation).

### 11.6 Liability Containment

- Clear wording: “NexGenSpec is reporting software only. The inspector is responsible for the accuracy and compliance of the report.” No implied warranty on report content.

### 11.7 Signature Authenticity Tracking

- Store signature metadata (timestamp, deviceId); optional hashing of signature image. Display “Signed at {date} on device” in report.

### 11.8 Clear Separation from D.I.A. Inspections

- App name: NexGenSpec. No “D.I.A. Inspections” in app title or primary branding in app. Terms can reference “your inspection company” or “the inspector”; if T&C content is shared with D.I.A., present it as “Inspection agreement (provided by your inspector)” not as “D.I.A. Inspections app.”

**File to update:** `TermsAndConditionsView.swift` — replace logo and references with NexGenSpec where appropriate; keep legal content but attribution clear.

---

## 12. FUTURE SCALABILITY DESIGN

### 12.1 Cloud Sync

- **Design now:** Stable UUIDs for all entities; **lastModified** or **version** per entity for conflict detection. Repository protocol can have a “remote” implementation that syncs with backend; local-first: write to local repo, then push events/deltas. No refactor of domain or use cases.

### 12.2 Multi-User Teams

- **Actor** or **userId** in AuditEvent and optional on Inspection (e.g. “owner”). Future: filter dashboard by assigned user; permissions in Application layer.

### 12.3 Admin Dashboard

- Separate module or target (e.g. web or internal app) that reads audit logs, list of inspections, subscription status. App exposes no admin UI; only data shape and APIs need to support it.

### 12.4 AI Summary Drafting

- **Use case:** “Generate draft summary for section” — takes section/items, returns text. Application layer calls AI service (async); result written to item fields by existing **UpdateItemUseCase**. No change to domain model.

### 12.5 Subscription Tiers

- **Feature flags** or capability checks (e.g. “LiDAR allowed for tier X”). Check in Use Case or at entry point (e.g. “Capture Room” visible only if tier allows). No payment processing in app; only “tier” or “entitlement” state.

### 12.6 Payment Status Tracking

- **Not processing:** App only displays “Subscription: Active until …” or “Upgrade”; actual payment and status come from backend. Local cache of “subscriptionStatus” optional.

---

## 13. COMPLETE EXECUTION ROADMAP

### Phase 1 — Foundation (Weeks 1–3)

- **Data model rebuild:** New Domain entities (Inspection, Version, Section, Item, MediaAsset, AnnotationOverlay, AuditEvent, ReportPackage, InspectionState). Keep Codable and schema version. **Migration:** Map existing `Models.swift` and JSON to new shapes; one-time migration for existing inspections.
- **Folder structure:** Create Domain, Application, Infrastructure, Presentation folders; move existing files into Presentation/ and adapt imports.
- **Repository protocols:** Define InspectionRepositoryProtocol, MediaAssetRepositoryProtocol, AuditEventRepositoryProtocol. Implement **FileSystemInspectionRepository** with async load/save and index + per-version files.
- **State machine:** Implement **InspectionStateMachine** and **FinalizeInspectionUseCase**; remove state mutation from **FinalizeView** (call use case only).
- **Concurrency:** InspectionStore replaced by repository; all I/O async; ViewModels use Task + MainActor for UI.

**Validation:** Existing inspections load; create new inspection; finalize; state is immutable after finalize.

### Phase 2 — Performance & Media (Weeks 4–6)

- **Thumbnail pipeline:** ThumbnailCacheEngine; generate thumbnails on add and on first access; **ItemDetailView** and any grid use thumbnails only; no sync `Data(contentsOf:)` on main.
- **Lazy loading:** Version list from index only; full version on open. **LazyMediaGrid** and item photo strip use async thumbnail API.
- **Disk batching:** Debounced draft save; StorageActor for all writes.
- **Annotation overlay model:** Add AnnotationOverlay; store overlay JSON per photo; **PhotoAnnotationView** save path writes overlay, not overwriting photo. Export pipeline bakes overlay at export time.

**Validation:** 100+ photos in one inspection; smooth scrolling; &lt;200ms thumbnail load; memory stable.

### Phase 3 — Finalization & Audit (Weeks 7–8)

- **Finalization service:** Atomic transaction: snapshot → SHA256 → write version file → audit events → update index. Hash in report footer.
- **Audit events:** Append-only AuditEvent repo; emit events for finalize, revision, photo add, item update. Export audit log.
- **Report package:** ReportPackage type; hash chain for revisions.

**Validation:** Finalize produces hash; report footer shows hash; audit log exportable.

### Phase 4 — Report Engine & Design (Weeks 9–11)

- **HTML/PDF redesign:** Template-based HTML; card layout; sidebar; multi-page PDF; asset bundling; draft watermark. Progressive export on background.
- **Visual system:** Color, typography, spacing, cards; dark mode; Dynamic Type; large touch targets.

**Validation:** Export 300-photo report in &lt;5s; no UI freeze; professional layout.

### Phase 5 — LiDAR & Pencil (Weeks 12–14)

- **RoomPlan integration:** Feature gate; capture pipeline; USDZ + floorplan PNG; measurements; store in lidar folder.
- **PencilKit annotation:** Replace custom Canvas in PhotoAnnotationView with PencilKit; vector overlay storage; export-time rasterization. Arrow/circle tools if not in PencilKit.

**Validation:** LiDAR capture on supported device; annotations persist and export correctly.

### Phase 6 — Legal & Polish (Weeks 15–16)

- **Legal:** NexGenSpec T&C separation; audit export; data retention wording; signature metadata.
- **App Store:** Privacy manifest; no required permissions beyond camera/photos/LiDAR as needed; checklist (screenshots, description, compliance).

### Migration Strategy from Current Codebase

- **Step 1:** Introduce new Domain and Repository types alongside existing Models and InspectionStore. No delete yet.
- **Step 2:** Add adapter that reads existing `inspections.json` and per-job `inspection.json` (if any) into new version/snapshot format; write to new layout (index + versions/). Run once on first launch after update.
- **Step 3:** Switch UI to use new repository and ViewModels that call Use Cases. Remove direct InspectionStore update from views.
- **Step 4:** Remove old InspectionStore and old model usage; delete deprecated code paths.
- **Step 5:** Add schema version to all persisted files; document migration for future schema changes.

---

## Appendix A — File Reference Quick Map

| Current File | Role in Redesign |
|--------------|------------------|
| `Models.swift` | Replaced by Domain/Entities and ValueTypes; migrate to new shapes |
| `InspectionStore.swift` | Replaced by FileSystemInspectionRepository + InspectionStateMachine |
| `InspectionViewModel.swift` | Kept in Presentation/ViewModels; consumes Use Cases only |
| `InspectionView.swift` | Presentation; remove deep bindings; use commands |
| `FinalizeView.swift` | Presentation; call FinalizeInspectionUseCase only; no state mutation |
| `ItemDetailView.swift` | Presentation; use async thumbnail/photo load; annotation saves overlay |
| `PhotoAnnotationView.swift` | Replace with PencilKit + overlay persistence |
| `HTMLReportRenderer.swift` | Replaced by Infrastructure/Export/HTMLReportGenerator + template |
| `PDFReportRenderer.swift` | Replaced by PDFRenderPipeline (multi-page, background) |
| `LazyMediaGrid.swift` | Use ThumbnailCacheEngine; accept asset IDs or URLs from repo |
| `FilePaths.swift` | Extend for versions/, full/compressed/thumbnails, audit |
| `AuditLog.swift` | Evolve to AuditEventRepository + structured events |
| `TemplateImporter.swift` | Keep; move to Infrastructure or Application; add schema version |
| `TermsAndConditionsView.swift` | NexGenSpec branding; legal separation from D.I.A. |
| `InspectionVersion+Empty.swift` | Move to Domain or remove if not needed |

---

## Appendix B — Architecture Diagram (Text)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           PRESENTATION LAYER                                 │
│  DashboardView ──► InspectionRootView ──► InspectionView                    │
│        │                     │                      │                        │
│        │                     │                      ├─ SectionSidebarView   │
│        │                     │                      ├─ SectionDetailView    │
│        │                     │                      ├─ ItemDetailView       │
│        │                     │                      ├─ FinalizeView         │
│        │                     │                      └─ (Report preview)     │
│        ▼                     ▼                                                │
│  DashboardViewModel    InspectionViewModel  (state: selection, filter only)   │
│        │                     │  commands: loadVersion, updateItem,           │
│        │                     │           addPhoto, finalize, export          │
└────────┼─────────────────────┼──────────────────────────────────────────────┘
         │                     │
         ▼                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          APPLICATION LAYER                                   │
│  CreateInspectionUseCase  UpdateItemUseCase  AddPhotoUseCase                 │
│  FinalizeInspectionUseCase  CreateRevisionUseCase  ExportReportUseCase       │
│  InspectionStateMachine   FinalizationService   ReportExportOrchestrator      │
│        │                     │                      │                        │
│        └─────────────────────┴──────────────────────┘                        │
│                              │                                               │
│                    depends on Repository Protocols                            │
└──────────────────────────────┼──────────────────────────────────────────────┘
                               │
         ┌─────────────────────┼─────────────────────┐
         ▼                     ▼                     ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│ DOMAIN           │  │ DOMAIN           │  │ DOMAIN           │
│ Inspection       │  │ InspectionRepo   │  │ AuditEventRepo   │
│ InspectionVersion│  │ MediaAssetRepo  │  │ TemplateRepo     │
│ Section, Item   │  │                  │  │                  │
│ MediaAsset      │  │                  │  │                  │
│ AnnotationOverlay│ │                  │  │                  │
│ LiDARScan       │  │                  │  │                  │
│ ReportPackage   │  │                  │  │                  │
│ InspectionState │  │                  │  │                  │
└────────┬────────┘  └────────┬──────────┘  └────────┬────────┘
         │                    │                      │
         ▼                    ▼                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        INFRASTRUCTURE LAYER                                   │
│  FileSystemInspectionRepository   FileSystemMediaStore   FileSystemAudit      │
│  ThumbnailCacheEngine   PhotoCompressionPipeline   RoomPlanCaptureService    │
│  PencilKitAnnotationStore   HTMLReportGenerator   PDFRenderPipeline           │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

*End of Architecture Redesign Document.*
