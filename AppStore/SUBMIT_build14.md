# NexGenSpec — Build 14 submission runbook

Single source of truth for getting **1.0.0 (14)** from `main` → TestFlight → App Store.
Guards against the four ways this got fumbled before: wrong repo copy, archiving before
fixes were merged, submitting untested, and the microphone privacy-label wording.

Build 14 = the audit-fix build (B-0065 monetization gate, security hygiene, functions
hardening, robustness, + invoice locale fix). Confirmed on the App Store version label as
v1.0.0 (build number 14).

---

## Phase 0 — Merge build 14 ✅ DONE (2026-06-05)
- [x] PR #40 merged to `main` (merge commit `a7bb397`); sub-PRs #36–#39 + #25 auto-closed.

## Phase 1 — Verify on `main` ✅ DONE
- [x] `CURRENT_PROJECT_VERSION = 14` ×6, `hasFeatureAccess` = pure entitlement check,
      invoice locale fix present, tree clean. Build compiles (iOS Simulator SDK).

## Phase 2 — Archive & upload (Xcode) — YOUR STEP
- [ ] Disk: run `~/cleanup.sh`, then `df -h /` → need **≥ 10 GB free** (D-0131). Don't open Xcode below that.
- [ ] Open **`~/Developer/NexGenSpec_FINAL/NexGenSpec.xcodeproj`** — ⚠️ NOT the `~/Documents/` copy (that one is the abandoned iCloud copy).
- [ ] Pull latest first: `git checkout main && git pull`.
- [ ] Device dropdown → **Any iOS Device (arm64)**.
- [ ] **Product → Archive**.
- [ ] Organizer → select archive → **Distribute App → App Store Connect → Upload** → through defaults → **Upload**.
- [ ] ✅ GATE: "Upload Successful," then ASC → **TestFlight** shows **1.0.0 (14)** finishing **Processing**.

## Phase 3 — Test on device (TestFlight) — HARD GATE
- [ ] Update to build 14 in the TestFlight app and verify the changed behavior:
  - [ ] **Free** account → PDF export **and** ZIP export both show the **"NEXGENSPEC FREE" watermark**.
  - [ ] **Pro** account → exports are **clean** (no watermark).
  - [ ] Recovery email still works (Keychain migration is silent).
  - [ ] Weather loads; video recording works; company logo renders on the report.
- [ ] ✅ GATE: all pass → continue. Anything broken → STOP, do not submit.

## Phase 4 — Submit to App Store (App Store Connect) — YOUR STEP
ASC → Apps → NexGenSpec → **App Store** tab:
- [ ] If no **1.0** version exists: **(+) → Create New Version → 1.0**.
- [ ] **Build** → (+) → attach **1.0.0 (14)**.
- [ ] **App Privacy** → fill per `AppStore/PRIVACY_LABEL_CLICKTHROUGH.md` (now corrected).
      ⚠️ Set **Precise Location**. Audio Data category stays **No** (on-device only) — but **never** state
      "no microphone use" anywhere; the mic IS used for walkthrough-video audio (Guideline 5.1.1, B-0063).
- [ ] **In-App Purchases** → attach **`com.nexgenspec.annualv1`** ($449/yr) + **`com.nexgenspec.monthlyv1`** ($49/mo).
- [ ] **App Review Info** → notes from `AppStore/REVIEW_NOTES.md`; demo login **appreview@nexgenspec.com**.
- [ ] **Pricing/Availability**: Free; US + CA (D-0114); Mac/Vision **off** (D-0115); age **4+**.
- [ ] Export compliance: nothing (`ITSAppUsesNonExemptEncryption = false`).
- [ ] **Submit for Review**.

---

## Deferred to first post-launch update (NOT in build 14)
- **B-0062** (HIGH) — encrypted-backup restore is non-atomic; rewrite with staging dir + atomic swap.
- **B-0064** remainder — Cloud Functions App Check / maxInstances (the 502-redaction + token-cap parts shipped in 14).
