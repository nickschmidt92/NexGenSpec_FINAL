# Further Additions & Optimizations

What was just added in this pass, plus a backlog of high-value options.

---

## Just Implemented

1. **Debounced draft save** (`InspectionStore`) — `update(version:)` schedules a single save after 400ms instead of writing on every change. Flush on app background (`willResignActive`) so no data loss.
2. **In-memory thumbnail cache** (`PhotoLoadService`) — NSCache (~80 MB limit) keyed by job+photo; memory warning clears cache. Reduces re-decode when scrolling back over 300 photos.
3. **Background report export** (`ReportExportService` + `InspectionOverviewView`) — Export menu: "Quick summary (text)" and "Full report (PDF)". PDF runs in `Task.detached` with progress overlay; share sheet when done. No UI freeze.
4. **Annotation baking in reports** (`AnnotationBakeService` + `HTMLReportRenderer`) — For each photo in the report, if an overlay exists it’s composited (PencilKit + arrows/circles) onto the image. Overlay stores optional `canvasWidth`/`canvasHeight` for correct scaling.

---

## Backlog (prioritized)

### Performance & scale

- **Version list = metadata only** — Load a lightweight index (id, clientName, address, date, status) for the dashboard; load full `InspectionVersion` only when opening an inspection. Cuts memory with many jobs.
- **Signature image on disk** — Replace `InspectionSignature.imageData` with a file path (e.g. `signatures/{id}.png`) and keep only metadata in the model. Shrinks JSON and memory.
- **LazyMediaGrid uses PhotoLoadService** — If you have a grid that shows inspection photos by URL, switch it to `AsyncThumbnailView` or a similar loader that uses `PhotoLoadService` for consistency and caching.
- **Export: stream or batch images** — For 300+ photos, avoid building one huge HTML string with all base64 in memory. Consider writing HTML in chunks or writing images to a temp folder and referencing them by path in the report package.

### UX & accessibility

- **iPad keyboard shortcuts** — Add `keyCommands` for New Inspection, Save, Next/Previous section, Finalize. Show in a help overlay.
- **Dynamic Type** — Use `@ScaledMetric` or `Font.body` (system) so text respects user size. Design system already has spacing; add text style tokens.
- **VoiceOver** — Ensure list rows, severity badges, and Export menu have clear `accessibilityLabel`/`accessibilityHint`.
- **High contrast** — In `DesignSystem`, add a high-contrast color set and use it when `UIAccessibility.isReduceTransparencyEnabled` or increased contrast is on.

### Features

- **RoomPlan capture flow** — Implement capture UI using RoomPlan API; write USDZ to `lidar/`, optional floorplan PNG; save metadata via `LiDARScanStore`. Gate with `LiDARCapability.isSupported`.
- **Undo/redo in PencilKit** — Expose `PKCanvasView.undoManager` (e.g. Undo/Redo toolbar buttons) so annotations support undo.
- **Draft auto-save indicator** — Show a small “Saving…” / “Saved” when debounced save runs, so users know edits are persisted.

### Reliability

- **Error surfacing** — Replace `// TODO: surface error` in `InspectionStore.save()` with an `@Published` error or callback so the UI can show an alert.
- **Recovery on corrupt index** — If `load()` fails or decode fails, try loading a backup (e.g. `inspections.json.backup`) or show “Recover” and don’t overwrite.

### Future-ready

- **Stable sync IDs** — You already use UUIDs; ensure section/item IDs are stable across template re-import (e.g. UUID from template id) so future cloud sync can match.
- **Audit event schema** — Extend `AuditLog` to append structured events (e.g. JSON lines: action, versionId, timestamp) for export and compliance.

---

## Quick wins (no new screens)

- Add `.accessibilityLabel` to Export menu items and progress text.
- Use `Spacing` and `AppColor` from `DesignSystem` in `InspectionOverviewView` and `SectionDetailView` for consistency.
- In `ReportExportService`, on `.failure` set an error message and show it in the overlay (e.g. “Export failed: …”).
