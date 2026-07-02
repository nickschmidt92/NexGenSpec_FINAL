# NexGenSpec — SOP: Debugging Workflow & Landmine Register

**Version:** v2 · **Date:** 2026-07-01 (v1: 2026-06-30) · **Build audited:** 1.0.0 (27 candidate = main@998f0dc + PR #94 + the 2026-07-01 pre-submission PR set)
**Stack:** SwiftUI · FirebaseAuth + FirebaseCore + FirebaseCrashlytics (no Firestore, no Firebase Storage) · **CloudKit** private DB for sync (`NexGenSpec/Sync/`) · StoreKit 2 · on-device storage under `FilePaths.appRoot` (JSON + jpeg/png/PDF).

This SOP is generated from a code-level audit of 8 failure dimensions, re-verified 2026-07-01 by an adversarial multi-agent review (36 findings, each independently refute-checked). Every landmine cites a real `file:line` + status (`guarded` / `at-risk` / `open`). Line numbers are pinned to the build-27 candidate tree and drift as PRs land — trust the function name over the number. Use the triage matrix first (symptom → steps), then the register.

**v2 changes:** corrected the false "sync ships flag-OFF" row (sync ships ON); moved PR #94's fixes (StoreKit seed, video write, camera guards) to guarded; registered the Keychain-cache uninstall-persistence trap, the UIImagePickerController config-ordering crash class, and the dead DeviceCheck server read; added the BACKUP/RESTORE section; corrected the PDF-freeze and camera-crash triage rows.

---

## 0. Environment preflight (do this before any debug session)

1. **Disk (D-0131):** run `~/cleanup.sh`; do **not** open Xcode if `df -h /` shows < 10 GB free. Note: the script's simulator-wipe line needs `sudo` (a terminal); headless runs skip it — the DerivedData/caches lines still free most of the space.
2. **One repo only:** the canonical repo is `~/Developer/NexGenSpec_FINAL` (non-synced). iCloud ghost copies were removed 2026-06-30 — never edit a NexGenSpec repo under `~/Library/Mobile Documents/…` or `~/Documents`/`~/Desktop`.
3. **Clean tree:** `git status` — a Stop-hook (`warn-dirty-repos.py`) warns on uncommitted/untracked drift; act on it.
4. **Build sanity:** `xcodebuild -scheme NexGenSpec -configuration Release -destination 'generic/platform=iOS' clean archive` reproduces submission-path breakage (Release differs from Debug — see Build 22 history). Headless `xcodebuild build` with a `-derivedDataPath` under `/tmp` stalled indefinitely on 2026-07-01 (SWBBuildService idle, no compile activity) while the identical build with default DerivedData completed — if a headless build hangs at 0% CPU, retry with default DerivedData before debugging the project.
5. **Xcode headless limits:** `xcodebuild -exportArchive` for App Store needs an ASC session ("No Accounts") + iOS Distribution cert — neither exists headless on this Mac. Store validation/upload is ALWAYS Organizer, by hand.

---

## 1. Symptom → Steps triage matrix

### 🔴 CRASH / HANG
| If… | Then check | Landmine |
|-----|-----------|----------|
| **Crash the moment "Record Video" is tapped** (real device only; simulator can't reproduce) | `UIImagePickerController` config ORDER: `cameraCaptureMode = .video` throws `NSInvalidArgumentException` unless `mediaTypes` already contains `public.movie` (fresh pickers default to images-only). Required order: `sourceType` → `mediaTypes` → `cameraCaptureMode`. Introduced by a guard refactor in PR #94, caught + fixed in review before merge. | `VideoRecorderView.swift:28-40` — **guarded (build 27)**; the ordering constraint is the landmine |
| UI **freezes** during LiDAR "Save" | USDZ export + floor-plan render + record commit — moved off-main in PR #100, which is **gated on an on-device iPad test** (room.export off-main is undocumented; simulator can't exercise RoomPlan). Until that PR merges, the freeze is known/accepted. | `RoomPlanCaptureBridge.swift` `LiDARScanPersistence.save` — **fix pending device test (PR #100)** |
| UI freezes during video import, text summary, cover photo, deletion receipt | All moved off-main via `Task.detached`: video import in PR #94, text summary + cover photo in PR #96, deletion receipt in PR #97. If a freeze reappears, check the caller kept the detach. | `InspectionOverviewView.swift` (video ~:847, text export, cover photo), `AppSettingsView.swift` (receipt call site) — **guarded (build 27)** |
| UI freezes during **report/PDF/invoice** generation | Only the HTML string render is off-main. WKWebView load + the `UIPrintPageRenderer` numberOfPages/drawPage pagination loop are **inherently main-actor** (WKWebView is main-thread-bound) — a huge, image-heavy report CAN stall there by design. Caller-side `Task.detached` cannot move it; mitigate with progress UI / page bounds, don't hunt a caller bug. | `PDFReportRenderer.swift` (HTML render off-main :55; pagination loop main-actor ~:145) — **known main-actor phase** |
| **Crash** rendering a report from sparse data (no sections/signature/date) | Model layer is force-unwrap-clean; look outside models. | Models/renderers **0 at-risk** (4 benign IUOs) |
| Tapped camera but the **photo/video library appeared** (no crash) | All 3 leaf camera views fall back to `.photoLibrary` when `.camera` is unavailable (build 27). This is intentional — check Simulator / Mac "Designed for iPad" / a caller that skipped the `isSourceTypeAvailable` gate. The old "crash opening camera" class is gone. | `CameraCaptureView.swift` / `VideoRecorderView.swift` / `CoverPhotoPicker.swift` — **guarded (build 27)** |

### 🔨 WON'T BUILD
| If… | Then check |
|-----|-----------|
| Builds in Debug, fails in Release | Reproduce with `-configuration Release` (Build 22 class of bug). Check `#if DEBUG` symbols leaking into Release. |
| SPM / package graph errors | `File > Packages > Reset`; Firebase 12.12.0 pin; delete `~/Library/Developer/Xcode/DerivedData/NexGenSpec-*`. NOTE: `cleanup.sh` wipes `~/Library/Caches/*` including the global SPM cache — first build after cleanup re-downloads all packages (grpc/GoogleAppMeasurement are large; looks like a hang, isn't). |
| Signing / archive validate fails | Confirm entitlements match capabilities (CloudKit, no aps/remote-notification — stripped in Build 22/24). |
| ASC upload rejected: duplicate build number | `CURRENT_PROJECT_VERSION` bumps in its own PR (build 27 bump = PR #99); verify it's merged before archiving. Build 26 is already on ASC. |

### 🟡 UI / STATE
| If… | Then check | Landmine |
|-----|-----------|----------|
| Two required sheets fight / one won't show | Sheet sequencing (name vs fallback-email) — fixed Build 26; new sheets must not add a second simultaneous `.sheet(isPresented:)` on one view. | `RootView.swift:72` — **guarded** |
| Pro/watermark state flickers or wrong at launch | `isPro` seeds from the **Keychain** entitlement cache (7-day offline grace) before the live `Transaction.currentEntitlements` walk lands. See STOREKIT for the uninstall-persistence trap. | `SubscriptionManager.swift` init ~:272 — **guarded (build 27)** |
| Paywall says "3 free inspections remaining" but New Inspection bounces back to it | `freeInspectionsRemaining` counts only the local counter; `canCreateInspection` ALSO honors `deviceCheckTrialUsed`. After delete+reinstall (or a resold device) the two disagree. | `SubscriptionManager.swift:78-119` — **open (P2)** |
| Stale data after login/logout | Auth state listener drives `applyUser`; it's retained + removed on deinit. | `AuthManager.swift:71` — **guarded** |

### ☁️ SYNC (CloudKit — **there is no Firestore**)
| If… | Then check | Landmine |
|-----|-----------|----------|
| Data not syncing across devices | **Sync ships ON in Release** (production container `iCloud.com.nexgenspec.app`; `SyncFeature.isEnabled` is unconditionally true in Release since PR #91 — the old "ships flag-OFF" note in v1 of this doc was WRONG). Users opt out via Local-Only mode (`SyncFeature.effectiveSyncAllowed`); DEBUG gates on `ngs.sync.devEnabled`. Also: a stale "flag-OFF shipping build" comment survives at `SyncCoordinator.swift:167` — don't trust it. | `SyncFeature` / `SyncCoordinator` |
| **Photos / PDFs / thumbnails missing on the second device** | Expected: the shipping port syncs the inspection-record JSON ONLY (`CloudKitSyncPort.apply()`: `.mediaUpserted/.mediaDeleted → break`). Media stays on the originating device until the MediaAsset/ReportPDF slice ships. Settings copy corrected to match in PR #98. | `CloudKitSyncPort.swift` — **by design (current slice)** |
| Offline edits lost after force-quit | The outbound sync queue is **memory-only** — queued CloudKit ops die with the process. Recovery is ONLY a subsequent local edit to the same record: pull is inbound-only and never pushes local state. | `CloudKitSyncPort.swift:31` — **open (P2)** |
| Sync silently dead all session (flaky network at launch) | A failed CloudKit bind is never retried in-session; foreground pulls no-op until relaunch. | `SyncCoordinator.swift:153` — **open (P2)** |
| Deleted account's remote data lingers | `deleteZone` is client-issued, backed by a durable Keychain "owed" marker + cold-launch retry sweep — but per-zone `Result` errors are discarded inside the batch op, so a partial failure can read as success until the sweep. | `SyncCoordinator.swift:171/259`, `SyncTeardownOwed.swift:107` — **guarded**; `CloudKitBackends.swift:123` — **open (P2)** |
| "Firestore" in code | Only **comments** referencing a future custom-claims backend — no live Firestore. | `AuthManager.swift:49`, `AppSettingsView.swift` |

### 📱 DEVICE
| If… | Then check | Landmine |
|-----|-----------|----------|
| LiDAR feature on iPhone | LiDAR is **iPad-only**; gated centrally, shows "not available on iPhone" fallback. | `LiDARCapability.swift:23`, `LiDARCaptureView.swift:36` — **guarded** |
| Permission-string rejection at submit | Usage strings live in `project.pbxproj` `INFOPLIST_KEY_*` (merged at build; `GENERATE_INFOPLIST_FILE=YES`). All required keys present (Camera, PhotoLibrary, Microphone, Location, Calendars). | `project.pbxproj` — **guarded** |
| Pencil-only failure | No hard Pencil dependency — canvas uses `.anyInput`. | `PencilKitPhotoAnnotationView.swift:231` — **guarded** |

### 💳 STOREKIT
| If… | Then check | Landmine |
|-----|-----------|----------|
| Purchases don't resolve | Product IDs `com.nexgenspec.monthlyv1/annualv1` must match `NexGenSpec.storekit`; legacy IDs are entitlement-check-only (grandfathered), intentionally not in the storekit file. | `SubscriptionManager.swift:28-38` — **guarded** |
| Restore does nothing | Restore → `AppStore.sync()` + `updateEntitlements()`, wired to paywall button. | `PaywallView.swift:176` → `SubscriptionManager.swift` ~:378 — **guarded** |
| Pro state survives app deletion / QA reset "doesn't work" | **The entitlement cache is Keychain-backed (build 27+) and Keychain items survive uninstall.** Delete+reinstall inside the 7-day grace re-grants the Pro launch state from the stale cache (reconciled by the next `currentEntitlements` walk). To fully reset a test device: delete the `com.nexgenspec.entitlement.cache` Keychain item or wait out the grace — reinstalling is NOT enough. This WILL confound the manual sandbox purchase+restore test if forgotten. | `SubscriptionManager.swift` ~:436-473 — **intentional retention; QA trap** |
| Legacy (≤26) Pro user demoted right after updating | The legacy UserDefaults snapshot is migrated INTO the Keychain (if inside grace) before the plist keys are purged — added in the 2026-07-01 update to PR #94. If demotion still reproduces, check the migration ran before the first `updateEntitlements` walk. | `SubscriptionManager.swift` `migrateAndPurgeLegacyUserDefaultsEntitlementCache` — **guarded (build 27)** |
| Free trial resets on delete+reinstall | **The server-side backstop is currently DEAD in production:** the `getTrialStatus` Cloud Function is IAM-locked at the Google layer (HTML 403 before function code runs), the client fails open, so `deviceCheckTrialUsed` never turns true from the network. Server fix, no binary change: `gcloud functions add-invoker-policy-binding getTrialStatus --region=us-central1 --member=allUsers` (match `markTrialUsed`), then verify an unauthenticated POST returns the function's own JSON 401, not Google's HTML page. | `DeviceCheckTrialGate.swift:81/244-247`, `functions/src/index.ts:317-320` — **OPEN (P1, server-side)** |
| Trusting unverified transactions | All paths unwrap `VerificationResult` via `verify()` (throws on `.unverified`). | `SubscriptionManager.swift` ~:494 — **guarded** |

### 📄 OUTPUT (report / invoice / PDF)
| If… | Then check | Landmine |
|-----|-----------|----------|
| Client name/address breaks HTML or shows `&amp;` | Every interpolated field routes through `String.htmlEscaped` (escapes `& < > " '`). | `String+HTMLEscaping.swift:11`; renderers **0 at-risk / 40 guarded** |
| Report won't render when weather fails | Weather is fully optional; nil/timeout/decode-fail omits the block and the report still renders. | `WeatherService.swift:251-279`, `HTMLReportRenderer.swift:578` — **guarded** |
| False "INTEGRITY CHECK FAILED" on old report | Empty branding fields are omitted from canonical encoding so pre-Build-26 seals still verify. | `Models.swift:450+` — **guarded** |
| Near-blank **page 2** in every PDF | Cover page `min-height:100vh` can overflow the US-Letter printable area under `UIPrintPageRenderer`. | `HTMLReportRenderer.swift:214` — **open (P2)** |
| PDF pagination wrong (US-Letter) | B-0070 pagination path (`UIPrintPageRenderer` page loop). Also: `numberOfPages == 0` is masked by `max(_,1)` → a silent blank one-pager instead of the HTML fallback. | `PDFReportRenderer.swift:145/155` — **guarded / open (P3)** |

### 💾 BACKUP / RESTORE (format v4, AES-GCM)
| If… | Then check | Landmine |
|-----|-----------|----------|
| "This backup was made by an older version…" on restore | **Intentional.** v4 (landed build-26 line, commit 0ac0b34) seals every frame with header+path AAD and enforces fileCount completeness; v1/v2/v3 are deliberately non-restorable (disposable-tester-data decision, B-0047). Not corruption, not a regression — create a new backup. | backup services — **by design** |
| AAD / fileCount failure on a **v4** file | Genuine truncation or tamper — the loud failure is the feature working, not an app bug. | — |
| Passphrase rejected | Floor is 12 chars; PBKDF2 210k iterations. | — |

---

## 2. Landmine register (v2 — 2026-07-01, build-27 candidate)

**Fixed since v1 (verify on merge):**
1. StoreKit spoofable UserDefaults seed → Keychain cache + legacy migration — PR #94. *Was register #1.*
2. Imported-video main-thread write → `Task.detached` — PR #94. *Was #3.*
3. Leaf camera views unguarded → internal `.photoLibrary` fallback — PR #94 (+ the mediaTypes-ordering crash the refactor introduced, fixed in the 2026-07-01 update). *Was #7.*
4. Plain-text summary + cover-photo main-thread writes → PR #96. *Were #5/#6.*
5. Deletion-receipt PDF main-thread render/write → PR #97. *Was #4.*
6. LiDAR USDZ/PNG main-thread save → PR #100 — **merge only after the on-device iPad test**. *Was #2.*

**Open (new in v2):**
1. `DeviceCheckTrialGate.swift:81` — `getTrialStatus` IAM-locked in production; trial-reset backstop dead; fail-open. **P1, server-side gcloud fix, no binary change.**
2. `CloudKitSyncPort.swift:31` — outbound sync queue memory-only; offline edits dropped on force-quit until next local touch. P2.
3. `SyncCoordinator.swift:153` — failed CloudKit bind never retried in-session. P2.
4. `CloudKitBackends.swift:123` — `deleteZone` discards per-zone Result errors (sweep still covers eventual consistency). P2.
5. `HTMLReportRenderer.swift:214` — cover `min-height:100vh` near-blank page 2 risk. P2.
6. `SubscriptionManager.swift:101` — `freeInspectionsRemaining` ignores `deviceCheckTrialUsed`; paywall copy contradicts the gate. P2.
7. `PDFReportRenderer.swift:155` — `max(numberOfPages,1)` masks a zero-page render as a blank one-pager. P3.
8. Report ID uses render-time `Date()` — same sealed report, different ID per export. `HTMLReportRenderer.swift:105`, P3.
9. Silent drops: missing/undecodable report photos omitted without placeholder (`HTMLReportRenderer.swift:288`, P3); video-import failure log-only (`InspectionOverviewView.swift:857`, P3); whole-video `Data` load before the off-main write — jetsam risk on very large clips (`InspectionOverviewView.swift:834`, P3); PDF tmp filename collides on same client+day (`PDFReportRenderer.swift:183`, P3); plain-text summary counts include excluded defects (`InspectionOverviewView.swift` ~:1410, P3); deletion receipts accumulate on-device indefinitely (`AccountDeletionReceiptService.swift:70`, P3, arguably by design).

**Intentional retentions (not bugs):** DeviceCheck trial bit (device-scoped, no PII); deletion-receipt PDF (user's own record — copy corrected in PR #98: delivered via share sheet, not auto-email); **Keychain entitlement cache survives uninstall** (see STOREKIT — QA/reset trap).

**Review traps (App Review, not code):** the admin demo account can never reach the paywall (Settings hides Upgrade for admins; Dashboard/report gates never fire) — REVIEW_NOTES must tell the reviewer to create a fresh account, or the prior 2.1 "couldn't locate the IAP" rejection repeats. Paywall duration display relies on ASC display-name wording (`displayPrice` has no period suffix), P3.

**Clean dimensions (re-verified 2026-07-01):** HTML escaping (0/40), force-unwraps in models (0), weather handling (0/9), Firestore listeners (N/A — CloudKit), account-deletion orphans (0 unintentional; disclosure gaps fixed in PR #98), device usage strings (all present).

---

## 3. Fix status (supersedes v1 §3 "not yet applied")
- ~~P1 LiDAR off-main~~ → PR #100, **device-test-gated**.
- ~~P2 StoreKit seed~~ → PR #94 (Keychain + migration).
- ~~P3 video write~~ → PR #94.
- ~~P4 camera guards~~ → PR #94 (with the ordering-crash correction).
- ~~receipt/text/cover writes~~ → PRs #96 / #97.
- **Still open:** the "Open (new in v2)" list above — DeviceCheck IAM (P1, server-side) first; the P2 sync/PDF items are post-submission candidates.
