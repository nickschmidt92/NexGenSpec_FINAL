# NexGenSpec — Execution Roadmap

See **ARCHITECTURE_REDESIGN.md** for full system design. This file is a phased checklist.

---

## Phase 1 — Foundation (Weeks 1–3)

### Data & Domain
- [ ] Introduce `InspectionState` (done: `Domain/ValueTypes/InspectionState.swift`)
- [ ] Add `InspectionStateMachine` (done: `Application/Services/InspectionStateMachine.swift`)
- [ ] Add `InspectionRepositoryProtocol` and `VersionMetadata` (done: `Domain/Repositories/InspectionRepositoryProtocol.swift`)
- [ ] Map existing `InspectionVersion.status` + `locked` to `InspectionState` in adapters (bridge until Models.swift is fully replaced)
- [ ] Add schema version to persisted JSON (optional in Phase 1)

### Infrastructure
- [ ] Implement `FileSystemInspectionRepository` (async load/save; index + per-version or draft file)
- [ ] Add `StorageActor` or serial queue for all disk writes
- [ ] Debounced draft save (300–500 ms)

### Application
- [ ] `FinalizeInspectionUseCase`: validate signatures → state machine → snapshot → hash → write → audit
- [ ] Remove state mutation from `FinalizeView`; call use case only
- [ ] `CreateRevisionUseCase` using state machine

### Presentation
- [ ] Replace direct `InspectionStore.update(version:)` with use case calls where finalization is involved
- [ ] ViewModels call use cases via `Task { await ... }`; update `@Published` on MainActor

### Validation
- [ ] Existing inspections load
- [ ] Create new inspection
- [ ] Finalize: state becomes immutable; no edit after finalize
- [ ] Create revision from finalized version

---

## Phase 2 — Performance & Media (Weeks 4–6)

- [ ] `ThumbnailCacheEngine` (on-disk + in-memory LRU)
- [ ] Generate thumbnails on photo add and on first access
- [ ] `ItemDetailView`: async thumbnail load only; no sync `Data(contentsOf:)` on main
- [ ] `LazyMediaGrid` / item photo strip use thumbnail API
- [ ] `AnnotationOverlay` model and persistence (per-photo overlay JSON)
- [ ] PhotoAnnotationView: save overlay instead of overwriting photo; export bakes at export time

**Validation:** 100+ photos; smooth scroll; &lt;200 ms thumbnail; memory stable.

---

## Phase 3 — Finalization & Audit (Weeks 7–8)

- [ ] Atomic finalization: snapshot → SHA256 → write → audit → index
- [ ] Hash in report footer
- [ ] Append-only `AuditEvent` repository and event types
- [ ] Audit log export

---

## Phase 4 — Report Engine & Design (Weeks 9–11)

- [ ] Template-based HTML report; card layout; sidebar; multi-page PDF
- [ ] Progressive export on background; &lt;5 s for 300 photos; no UI freeze
- [ ] Design system: color, typography, spacing, dark mode, Dynamic Type

---

## Phase 5 — LiDAR & Pencil (Weeks 12–14)

- [ ] RoomPlan capture; USDZ + floorplan PNG; measurements; feature gate
- [ ] PencilKit annotation; vector overlay; export-time rasterization

---

## Phase 6 — Legal & App Store (Weeks 15–16)

- [ ] NexGenSpec T&C separation from D.I.A. branding
- [ ] Audit export; signature metadata; data retention wording
- [ ] App Store checklist

---

## Adding New Files to Xcode

New folders created:

- `NexGenSpec/NexGenSpec/Domain/ValueTypes/`
- `NexGenSpec/NexGenSpec/Domain/Repositories/`
- `NexGenSpec/NexGenSpec/Application/Services/`

Add these files to the NexGenSpec target in Xcode (File → Add Files to "NexGenSpec" → select the new folders, "Create groups", target NexGenSpec).
