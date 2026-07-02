# NexGenSpec — SOP: Debugging Workflow & Landmine Register

**Version:** v1 · **Date:** 2026-06-30 · **Build audited:** 1.0.0 (26)
**Stack:** SwiftUI · FirebaseAuth + FirebaseCore + FirebaseCrashlytics (no Firestore, no Firebase Storage) · **CloudKit** private DB for sync (`NexGenSpec/Sync/`) · StoreKit 2 · on-device storage under `FilePaths.appRoot` (JSON + jpeg/png/PDF).

This SOP is generated from a code-level audit of 8 failure dimensions. Every landmine below cites a real `file:line` + status (`guarded` / `at-risk`). Use the triage matrix first (symptom → steps), then the register for the exact site.

---

## 0. Environment preflight (do this before any debug session)

1. **Disk (D-0131):** run `~/cleanup.sh`; do **not** open Xcode if `df -h /` shows < 10 GB free.
2. **One repo only:** the canonical repo is `~/Developer/NexGenSpec_FINAL` (non-synced). iCloud ghost copies were removed 2026-06-30 — never edit a NexGenSpec repo under `~/Library/Mobile Documents/…` or `~/Documents`/`~/Desktop`.
3. **Clean tree:** `git status` — a Stop-hook (`warn-dirty-repos.py`) now warns on uncommitted/untracked drift; act on it.
4. **Build sanity:** `xcodebuild -scheme NexGenSpec -configuration Release -destination 'generic/platform=iOS' clean archive` reproduces submission-path breakage (Release differs from Debug — see Build 22 history).

---

## 1. Symptom → Steps triage matrix

### 🔴 CRASH / HANG
| If… | Then check | Landmine |
|-----|-----------|----------|
| UI **freezes** during LiDAR "Save", video import, PDF receipt, cover-photo, or text summary | The action is a SwiftUI Button calling a **synchronous** write on `@MainActor`. Fix = wrap the export/write in `Task.detached(priority:.userInitiated)`. | `RoomPlanCaptureBridge.swift:416` (USDZ+PNG), `InspectionOverviewView.swift:844` (video), `AccountDeletionReceiptService.swift:83` (receipt PDF), `InspectionOverviewView.swift:1425` (text), `:1161` (cover) — all **at-risk** |
| UI freezes during **report/PDF/invoice** generation | Should NOT happen — core pipeline is off-main. Re-verify the caller still wraps in `Task.detached`. | `PDFReportRenderer.swift:55`, `HTMLReportRenderer.swift:293`, `ReportExportService.swift:65` — **guarded** |
| **Crash** rendering a report from sparse data (no sections/signature/date) | Model layer is force-unwrap-clean; look outside models. | Models/renderers **0 at-risk** (4 benign IUOs) |
| **Crash** opening camera on a device without one | Leaf camera views set `.camera` with no internal guard; all *current* callers guard, so suspect a **new** unguarded call site. | `CameraCaptureView.swift:17`, `VideoRecorderView.swift:25`, `CoverPhotoPicker.swift:54` — **at-risk (low)** |

### 🔨 WON'T BUILD
| If… | Then check |
|-----|-----------|
| Builds in Debug, fails in Release | Reproduce with `-configuration Release` (Build 22 class of bug). Check `#if DEBUG` symbols leaking into Release. |
| SPM / package graph errors | `File > Packages > Reset`; Firebase 12.12.0 pin; delete `~/Library/Developer/Xcode/DerivedData/NexGenSpec-*`. |
| Signing / archive validate fails | Confirm entitlements match capabilities (CloudKit, no aps/remote-notification — stripped in Build 22/24). |

### 🟡 UI / STATE
| If… | Then check | Landmine |
|-----|-----------|----------|
| Two required sheets fight / one won't show | Sheet sequencing (name vs fallback-email) — fixed Build 26; new sheets must not add a second simultaneous `.sheet(isPresented:)` on one view. | `RootView.swift:72` — **guarded** |
| Pro/watermark state flickers or wrong at launch | `isPro` seeds from a UserDefaults bool for a 7-day offline grace before the live re-check lands. | `SubscriptionManager.swift:249` — **at-risk** (see StoreKit) |
| Stale data after login/logout | Auth state listener drives `applyUser`; it's retained + removed on deinit. | `AuthManager.swift:71` — **guarded** |

### ☁️ SYNC (CloudKit — **there is no Firestore**)
| If… | Then check | Landmine |
|-----|-----------|----------|
| Data not syncing across devices | Sync is CloudKit private DB in `NexGenSpec/Sync/`; note it currently **ships flag-OFF**. Check `SyncCoordinator`. | — |
| Deleted account's remote data lingers | `deleteZone` is client-issued but backed by a durable Keychain "owed" marker + cold-launch retry sweep. | `SyncCoordinator.swift:171/259`, `SyncTeardownOwed.swift:107` — **guarded** |
| "Firestore" in code | Only **comments** referencing a future custom-claims backend — no live Firestore. | `AuthManager.swift:49`, `AppSettingsView.swift:812` |

### 📱 DEVICE
| If… | Then check | Landmine |
|-----|-----------|----------|
| LiDAR feature on iPhone | LiDAR is **iPad-only**; gated centrally, shows "not available on iPhone" fallback. | `LiDARCapability.swift:23`, `LiDARCaptureView.swift:36` — **guarded** |
| Permission-string rejection at submit | Usage strings live in `project.pbxproj` `INFOPLIST_KEY_*` (merged at build; `GENERATE_INFOPLIST_FILE=YES`). All required keys present (Camera, PhotoLibrary, Microphone, Location, Calendars). | `project.pbxproj:454-459` — **guarded** |
| Pencil-only failure | No hard Pencil dependency — canvas uses `.anyInput`. | `PencilKitPhotoAnnotationView.swift:231` — **guarded** |

### 💳 STOREKIT
| If… | Then check | Landmine |
|-----|-----------|----------|
| Purchases don't resolve | Product IDs `com.nexgenspec.monthlyv1/annualv1` must match `NexGenSpec.storekit`; legacy IDs are entitlement-check-only (grandfathered), intentionally not in the storekit file. | `SubscriptionManager.swift:28-38` — **guarded** |
| Restore does nothing | Restore → `AppStore.sync()` + `updateEntitlements()`, wired to paywall button. | `PaywallView.swift:176` → `SubscriptionManager.swift:356` — **guarded** |
| Pro unlockable offline / jailbreak | **isPro seeds from a spoofable UserDefaults bool** (`nexgenspec.entitlement.isPro`, 7-day offline grace) before the live `Transaction.currentEntitlements` check. | `SubscriptionManager.swift:249` — **at-risk** |
| Trusting unverified transactions | All paths unwrap `VerificationResult` via `verify()` (throws on `.unverified`). | `SubscriptionManager.swift:417` — **guarded** |

### 📄 OUTPUT (report / invoice / PDF)
| If… | Then check | Landmine |
|-----|-----------|----------|
| Client name/address breaks HTML or shows `&amp;` | Every interpolated field routes through `String.htmlEscaped` (escapes `& < > " '`). | `String+HTMLEscaping.swift:11`; renderers **0 at-risk / 40 guarded** |
| Report won't render when weather fails | Weather is fully optional; nil/timeout/decode-fail omits the block and the report still renders. | `WeatherService.swift:251-279`, `HTMLReportRenderer.swift:578` — **guarded** |
| False "INTEGRITY CHECK FAILED" on old report | Empty branding fields are omitted from canonical encoding so pre-Build-26 seals still verify. | `Models.swift:450+` — **guarded** |
| PDF pagination wrong (US-Letter) | B-0070 pagination path; render off-main via `UIPrintPageRenderer` page loop. | `PDFReportRenderer.swift:145` — **guarded** |

---

## 2. Landmine register (audit summary — 2026-06-30)

**At-risk (7):**
1. `SubscriptionManager.swift:249` — isPro seeds from spoofable UserDefaults bool (offline grace). *Security/gating.*
2. `RoomPlanCaptureBridge.swift:416` — LiDAR USDZ export + floor-plan PNG render/write on `@MainActor` (large-scan freeze). *Hang.*
3. `InspectionOverviewView.swift:844` — imported video (tens of MB) written on main. *Hang.*
4. `AccountDeletionReceiptService.swift:83` — receipt PDF render+write on main (brief). *Hang.*
5. `InspectionOverviewView.swift:1425` — plain-text summary write on main (minor). *Hang.*
6. `InspectionOverviewView.swift:1161` — cover-photo JPEG write on main (minor). *Hang.*
7. `CameraCaptureView.swift:17` / `VideoRecorderView.swift:25` / `CoverPhotoPicker.swift:54` — leaf camera views lack internal `isSourceTypeAvailable` fallback (all callers currently guard). *Crash (defensive).*

**Intentional retentions (not bugs):** DeviceCheck trial bit (`functions/src/index.ts:369`, device-scoped, no PII); deletion-receipt PDF (`AccountDeletionReceiptService.swift:69`, user's own record).

**Clean dimensions:** HTML escaping (0/40), force-unwraps in models (0), weather handling (0/9), Firestore listeners (N/A — CloudKit), account-deletion orphans (0 unintentional), device usage strings (all present).

---

## 3. Recommended fix priority (not yet applied)
- **P1 (pre-1.0 nice-to-have):** `RoomPlanCaptureBridge.swift:416` off-main — most visible freeze.
- **P2:** `SubscriptionManager.swift:249` — add a live re-check gate before granting Pro-only output when the seed is the only source; weigh against the deliberate offline-grace UX.
- **P3:** video-import write off-main (`:844`).
- **P4 (defensive):** internal camera guards in the 3 leaf views.
- The receipt/text/cover writes are low-impact; batch when convenient.
