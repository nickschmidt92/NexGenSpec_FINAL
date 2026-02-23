# Phase 1 — Architectural Audit

## 1. Current Architectural Pattern

**Pattern: MV-like with shared mutable store**

- **InspectionStore** (`InspectionStore.swift`): Single `ObservableObject` holding full `[InspectionVersion]` in memory. Load/save is synchronous to one JSON file (`inspections.json`). Acts as both repository and “state holder.”
- **Views** receive `@Binding var version` or read from `@EnvironmentObject store` and mutate via `store.update(version:)` or direct binding.
- **InspectionViewModel** (`InspectionViewModel.swift`): Holds a **full** `InspectionVersion` in `@Published var version` plus selection/filter state. No use-case layer; ViewModel is a thin wrapper over the version object.
- **Flow:** Dashboard → InspectionRootView(versionID) → resolves version from store → InspectionView(version, onUpdate) → Form with deep bindings into `version.inspection.sections` and `version.inspection.sections[].items`. On disappear, `updated(draft)` writes back to store.

**Verdict:** Ad-hoc MVC/MVVM hybrid. No clear Application/Domain boundary; business rules live in Store and in Views.

---

## 2. Business Logic Incorrectly Mixed into Views

| Location | What’s wrong |
|----------|--------------|
| **FinalizeView.swift:59–65** | **FinalizeView** mutates `version.status`, `version.locked`, `version.finalizedAt` directly and calls `onFinalize(version)`. Finalization rules (e.g. “both signatures required”) are enforced only by button disable; the actual state transition is done in the view. |
| **SignatureView.swift:47–56** | `saveSignatures()` builds signature objects and appends to `version.inspection.signatures` inside the view. Signature validation and storage belong in a service/store. |
| **DashboardView.swift:81–88** | Create-inspection logic (guard inspectorConfirmed, build Inspection + InspectionVersion, insert) is triggered by button; the “business rule” (inspectorConfirmed required) is in the view’s disabled state and in Store’s guard. |
| **InspectionStore.finalize (116–122)** | Store mutates version in place and saves. No validation beyond !locked; no snapshot, no hash, no audit. |
| **InspectionStore.createRevision (125–140)** | Revision logic (copy inspection, clear signatures, new version) is in Store; no immutable snapshot of the finalized version. |

**Files to refactor:** `FinalizeView.swift`, `InspectionStore.swift` (move finalize/revision into a state-aware service or dedicated methods with validation).

---

## 3. Loose State (Booleans Instead of Enums)

| Location | Current | Issue |
|----------|---------|--------|
| **Models.swift:174–196** | `InspectionVersion` has `status: VersionStatus` (draft/final) and **`locked: Bool`**. Two sources of truth: “final” and “locked” can theoretically diverge. | Should be single **InspectionState** enum: draft | awaitingCustomerSignature | awaitingInspectorSignature | finalized(versionId) | revised(previousVersionId). |
| **ItemDetailView** | `isLocked: Bool` passed from parent. | Should derive from `version.state.isEditable` (or equivalent) so one place defines “can edit.” |
| **InspectionStore.finalize** | Checks `!versions[idx].locked` then sets status + locked. | Redundant; state enum makes “finalized” a single concept. |
| **InspectionStore.update** | Checks `!versions[idx].locked`. | Same: derive from state. |
| **InspectionStore.createRevision** | Checks `versions[idx].status == .final`. | Should check state.isFinalized. |

**Files:** `Models.swift` (InspectionVersion), `InspectionStore.swift`, all callers of `isLocked` / `version.locked`.

---

## 4. Large Data in ViewModels / Memory

| Location | Issue |
|----------|--------|
| **InspectionStore** | Holds **full** `[InspectionVersion]` in memory. Each version embeds full Inspection (all sections, items, photos array, signatures with **imageData**). With many inspections and 300+ photos (metadata + signature blobs), this grows unbounded. |
| **InspectionViewModel** | Holds full **InspectionVersion** (same payload). When user navigates section/item, the entire inspection tree is in memory. |
| **Models.InspectionSignature** | **`imageData: Data`** stored in the model; signature images kept in memory and in JSON. Should be file-backed (store by id, model holds id + metadata). |
| **DashboardView** | Lists `store.versions`; each row needs only metadata (client, address, date, status). Loading full versions for list is wasteful. |

**Target:** Version list should be metadata-only; full version loaded when user opens an inspection. Signature imageData should be on disk, reference by id.

---

## 5. Media Loaded on Main Thread

| Location | Issue |
|----------|--------|
| **ItemDetailView.loadImage(photo)** (119–123) | `Data(contentsOf: url)` and `UIImage(data: data)` are synchronous and typically run on main (called from body / view hierarchy). With many photos, this blocks UI. |
| **ItemDetailView** photo strip | ForEach(item.photos) + loadImage(photo) in body: **every** visible photo triggers sync load; no thumbnails, no async. |
| **HTMLReportRenderer** (81–84) | `loadPhotoData(jobId:fileName:)` uses `Data(contentsOf: url)` for each photo when building HTML; runs on whatever thread calls renderHTML (likely main). Export can freeze UI with 300 photos. |
| **LazyMediaGrid** | Uses `AsyncImage(url: url)` with file URLs; no thumbnail path. File URL loading may still block depending on implementation. |

**Files:** `ItemDetailView.swift`, `HTMLReportRenderer.swift`, `LazyMediaGrid.swift` (and any other direct photo load).

---

## 6. Re-render Loops / Over-renders

| Location | Issue |
|----------|--------|
| **InspectionView** (17–30) | `ForEach($draft.inspection.sections)` with nested `ForEach($section.items)`. Deep bindings mean any keystroke or picker change updates draft and can trigger full Form re-evaluation. |
| **ItemDetailView** | `@Binding var item`; every field edit propagates up. If parent re-renders and passes new binding, entire Form can re-render. |
| **InspectionRootView** (25–27) | `if let version = store.versions.first(where: { $0.id == versionID })` — when store.versions changes (e.g. after save), this re-evaluates and can replace the whole InspectionView with a new instance, losing local draft state if not careful. |
| **SummaryView.filteredDefects()** | Called in body (List(filteredDefects())); no @State cache. Filter runs every body evaluation. |

**Mitigation:** Prefer identity-stable sections/items (e.g. by id); avoid binding entire version in one go; consider command-style updates (e.g. updateItem(id, field, value)) to limit diffing. Cache filtered lists in @State or ViewModel when inputs haven’t changed.

---

## Summary Table

| # | Question | Answer |
|---|----------|--------|
| 1 | Architectural pattern | MV-like; shared InspectionStore; no Application/Domain layer. |
| 2 | Business logic in views | FinalizeView, SignatureView, Dashboard create flow; Store does finalize/revision without state machine. |
| 3 | Loose state | VersionStatus + locked boolean; isLocked passed around. Need InspectionState enum. |
| 4 | Large data in VMs | Full versions + signature imageData in Store and InspectionViewModel. |
| 5 | Main-thread media | ItemDetailView.loadImage sync; HTMLReportRenderer loadPhotoData sync. |
| 6 | Re-render risk | Deep bindings in InspectionView; filteredDefects() in body; store.versions change can replace InspectionView. |
