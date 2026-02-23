# What’s Next: Optimize & Add

Prioritized list of what’s still missing or worth adding. Items already done in recent work are marked ✅.

**Last big pass (implemented):** Overview/Summary/Finalize in sidebar, keyboard shortcuts (⌘S, ⌘←/→, ⌘F), VoiceOver + high contrast (SectionDetailView, SummaryView, FinalizeView, DesignSystem.forSeverity), metadata-only version list + loadFullVersion(id), export images to temp folder (batch), RoomPlan placeholder capture (Save placeholder scan).

---

## Critical gaps (app flow)

### 1. **Reach Overview, Summary, and Finalize from an open inspection** ⚠️
Right now, opening an inspection only shows the **section sidebar + item list**. These screens exist but are **never navigated to** from the app:

- **Overview** — Cover page, client/address, summary counts, **Export** (Quick summary / Full PDF), **Capture Room** (LiDAR).
- **Summary** — Findings grouped by severity (Safety, Major, Marginal, Minor).
- **Finalize** — Signatures and “Finalize & Lock.”

**Suggestion:** Add a way from the inspection screen to these (e.g. **Overview** and **Finalize** in the sidebar, or a toolbar menu “Overview / Summary / Finalize” that pushes the right view). That will make Export and Finalize actually usable.

---

## Performance & scale

| Item | Status | Notes |
|------|--------|--------|
| **Version list = metadata only** | ❌ | Dashboard still loads full `[InspectionVersion]`. For many jobs, keep only metadata in the index and `loadFullVersion(id)` when opening. |
| **Signature image on disk** | ✅ | Signatures use `imageFileName` + `SignatureStore`; report uses `loadImageData(jobId:)`. |
| **LazyMediaGrid + PhotoLoadService** | ✅ | `LazyMediaGrid(jobId:photos:...)` uses `AsyncThumbnailView`; ItemDetailView uses it for photos. |
| **Export: stream/batch images** | ❌ | Large reports (300+ photos) still build HTML with base64 in memory. Consider temp folder + image paths or chunked write. |

---

## UX & accessibility

| Item | Status | Notes |
|------|--------|--------|
| **iPad keyboard shortcuts** | Partial | Only ⌘N (New Inspection). Add e.g. Save, Next/Previous section, Finalize, and a shortcuts help overlay. |
| **Dynamic Type** | Partial | Design system has `AppFont`; not all screens use it. Use `Font.body` / `@ScaledMetric` where appropriate. |
| **VoiceOver** | Partial | VersionRow, New Inspection, Export menu have labels/hints. Add for section sidebar, severity badges, Finalize, Overview. |
| **High contrast** | Partial | `AppColor.safetyAccessible` etc. used on Overview badges; extend to SectionDetailView and severity pickers. |

---

## Features

| Item | Status | Notes |
|------|--------|--------|
| **RoomPlan capture** | Stub | `LiDARCaptureView` is a placeholder. Implement real capture (RoomPlan API → USDZ + metadata via `LiDARScanStore`). |
| **PencilKit undo/redo** | ✅ | Undo/Redo toolbar in `PencilKitPhotoAnnotationView`. |
| **Draft save indicator** | ✅ | “Saving…” / “Saved \(time)” in InspectionView toolbar. |

---

## Reliability

| Item | Status | Notes |
|------|--------|--------|
| **Save error surfacing** | ✅ | `InspectionStore.saveError` + Dashboard alert + `clearSaveError()`. |
| **Recovery on corrupt index** | ✅ | `load()` tries backup at `inspectionsIndexBackup` if main index fails; backup written before overwrite. |

---

## Future-ready

| Item | Status | Notes |
|------|--------|--------|
| **Stable sync IDs** | ✅ | `StableUUID.from(seed:)` for section/item IDs in `createNewInspection`. |
| **Structured audit** | ✅ | `AuditEventStore` + `audit_events.jsonl`; `AuditLog.log` appends with optional versionId/inspectionId. |

---

## Quick wins (no new screens)

1. **Navigation** — From InspectionView (or its root), add links/sidebar entries or a menu for **Overview** and **Finalize** (and optionally **Summary**) so Export and Finalize are reachable.
2. **Keyboard shortcuts** — Add ⌘S (save), Next/Previous section, and Finalize where applicable; optional help overlay (e.g. ⌘?).
3. **Accessibility** — Add `accessibilityLabel`/`accessibilityHint` to section sidebar rows, severity badges in SectionDetailView/ItemListView, and Finalize/Overview buttons.
4. **Design system** — Use `Spacing` and `AppColor` in SectionDetailView and other list/card views for consistency.

---

## Suggested order of work

1. **Wire Overview + Finalize (and optionally Summary)** into the inspection flow so users can export and finalize.
2. **Keyboard shortcuts** for Save and section navigation (and Finalize) on iPad.
3. **Metadata-only version list** + `loadFullVersion(id)` when you’re ready to scale to many inspections.
4. **Export streaming/batch** when reports with hundreds of photos become common.
5. **RoomPlan capture** when you’re ready to support LiDAR inspections.
6. **VoiceOver and high-contrast** pass on the main flows (sidebar, Overview, Finalize, Export).

If you tell me your priority (e.g. “make Overview and Finalize reachable” or “add keyboard shortcuts”), I can outline or implement the exact code changes next.
