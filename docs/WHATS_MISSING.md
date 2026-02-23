# What Else Is Missing for the App

High-level gaps and polish items. **All items below have been implemented** as of the last pass; this doc is kept for reference.

---

## 1. **First-run / empty state**

- **Dashboard with no inspections** – List is just empty. Consider:
  - ContentUnavailableView (“No inspections yet”, “Create your first inspection”) with a button that opens the New Inspection sheet.
- **No sample inspection** – `RootView` has logic to insert a sample inspection, but the app entry point (`NexGenSpecApp`) uses `DashboardView()` directly, so that sample is never created. Either:
  - Use the same “insert sample when list is empty” logic from the main app, or
  - Rely on the empty state and “New Inspection” only.

---

## 2. **Edit client contact after creation**

- **Client email and phone** are only set in “New Inspection”. If the user typos or the client changes contact info, there’s no way to fix it.
- **Suggestion:** On **Overview** (or a small “Client info” section), allow editing client name, email, phone, property address, inspector name, and inspection date **while the inspection is still a draft**. Lock these (or hide edit) once finalized.

---

## 3. **Show client email/phone on Overview**

- Overview shows client name, property address, date, inspector. It does **not** show client email or phone.
- **Suggestion:** Add email and phone to the Overview metadata block (and to the plain-text export if you use it for sharing).

---

## 4. **Authentication**

- **LoginView** and **RootView** (auth gate) exist but are **not** used by `NexGenSpecApp`; the app goes straight to `DashboardView`.
- If you want login:
  - Switch the app’s root to `RootView` (or a similar gate) and use `AuthManager` / `LoginView` so that the dashboard is only shown when authenticated.
- If you don’t need login yet:
  - You can leave as-is or remove/unused the login code to avoid confusion.

---

## 5. **Terms & Conditions**

- **TermsAndConditionsView** and **LegalHistoryView** exist but are **never presented** in the app.
- If you need T&C acceptance before use:
  - Show **TermsAndConditionsView** on first launch (or when terms change), and only allow access after “I accept” (and optionally persist acceptance + show in **LegalHistoryView**).

---

## 6. **App icon**

- Xcode may still warn about an unassigned child in the App Icon set if there’s no 1024×1024 asset.
- **Fix:** Add a 1024×1024 app icon in the asset catalog so the warning goes away and the app looks correct on device and App Store.

---

## 7. **Export / scale**

- **Large reports** (e.g. hundreds of photos) build HTML (and possibly PDF) in memory; export can be slow or memory-heavy.
- **Improvement (when you need it):** Stream or batch images (e.g. write images to a temp folder and reference by path in HTML instead of embedding), and/or chunked writes, so big reports don’t spike memory.

---

## 8. **RoomPlan / LiDAR**

- **LiDARCaptureView** is a placeholder (“Save placeholder scan”).
- When you’re ready for real capture: implement actual RoomPlan (or ARKit) capture, save USDZ (or agreed format) and metadata (e.g. via **LiDARScanStore**), and optionally link scans to the inspection.

---

## 9. **Invoice & Send**

- **PDF attachment:** User must tap “Export PDF” before “Send Invoice” if they want the report attached. If they forget, the email goes without the PDF.
- **Improvement:** Optionally “Export PDF and attach” in one step when they tap Send (e.g. export in background, then present mail composer with the PDF attached when done), or a clear note on the button: “Export PDF first to attach to email.”

---

## 10. **Accessibility and polish**

- **VoiceOver:** Add or refine `accessibilityLabel` / `accessibilityHint` on Overview, Finalize, Invoice & Send, and key buttons.
- **Dynamic Type:** Use the design system fonts (e.g. `AppFont` / `@ScaledMetric`) where appropriate so text scales.
- **Keyboard shortcuts (iPad):** You have Save, section nav, Finalize; optional: shortcut for “Invoice & Send” when visible, and a shortcuts help overlay (e.g. ⌘?).

---

## 11. **Reliability / edge cases**

- **Mail not configured:** You already show an alert when the device can’t send mail; keep that.
- **Export failure:** ReportExportService sets `errorMessage`; ensure it’s visible on Overview and on Invoice & Send (e.g. inline or alert) so the user knows why export failed.
- **Corrupt or missing template:** If the inspection template fails to load, `createNewInspection` does nothing (guard fails). Consider surfacing a message like “Template not loaded; cannot create inspection” so the user isn’t left guessing.

---

## Suggested order to tackle

1. **Empty state + optional sample** – So new users see a clear path to create an inspection.
2. **Edit client info on Overview (draft only)** – So email/phone/address can be fixed before finalize.
3. **Show client email/phone on Overview** – So the inspector sees full contact info.
4. **App icon** – Quick fix for the asset warning and store/device appearance.
5. **Auth (if needed)** – Wire RootView/Login into the app entry; otherwise document or remove.
6. **T&C (if needed)** – First-launch gate and optional history view.
7. **Invoice: “Export then send”** – One-tap “Export PDF and send” or clearer UX so the PDF is attached when desired.
8. **Large-report export** – When you have inspections with hundreds of photos.
9. **RoomPlan** – When you’re ready to support LiDAR inspections.

If you tell me your top priority (e.g. “empty state and edit client info”), I can outline or implement the exact code changes next.
