# Pre-submission punch list — PDF CSS, IAP rename, blockers, invoice lock

Closes the pre-submit gates for v1.0 App Store submission. Branch carries
8 commits ahead of `main` covering CSS regressions in data-heavy PDFs,
pre-submit blockers, the versioned IAP product ID rename per D-0108,
LiDAR error handling, and the invoice audit-trail fix landed today.

## Commits (oldest → newest)

| SHA | Title |
|---|---|
| 75ecdb6 | Fix PDF report CSS bugs that surface under data-heavy reports |
| e583e11 | Resolve pre-submit blockers B-0034 (mic copy) and B-0036 (logo URL) |
| 570dc1d | Tighten pre-submit posture: file protection, RoomPlan guard, section attestation |
| ca93de8 | T-01365: Rename IAP product IDs to versioned `annualv1` / `monthlyv1` |
| 78df348 | Add `schemaVersion` anchor to `InspectionVersion` for v1.1 migrations |
| b42a81f | LiDAR: add `RoomCaptureSession.didFailWith` handler |
| 3debda4 | functions: pin esbuild and vite via npm overrides to patch Dependabot mediums |
| 5dd6962 | Fix invoice $ alpha-input + audit-trail lock after Send (T-01384, T-01385) |

## Closes

- **T-01384** — Lock Invoice section after Send (audit-trail integrity)
- **T-01385** — Reject alpha characters in invoice $ fields via `decimalFiltered` binding modifier
- **T-01386** — Phone format `(xxx) xxx-xxxx` (pre-existing in `35a4e8d`; verified in `DesignSystem.swift:353` and three input sites; on-device dogfood)
- **T-01223** — `subscriptions.isAdminAccount` admin gate (pre-existing in `a48cd44`; verified zero remaining `authManager.isAdmin` references)
- **T-01365** — IAP product ID rename to `annualv1` / `monthlyv1` (per D-0108)
- **B-0034**, **B-0036** — pre-submit blockers

## Test plan

- [x] XCTest suite — 57 tests passing on iPhone 17 simulator, iOS 26.5 SDK
- [x] Clean Debug build — no warnings on touched files
- [x] Auto-provisioning device build + install to iPad Pro 11" M4
- [ ] On-device dogfood (T-01368) — invoice decimal filter, invoice lock-after-send, phone format, finalize flow, LiDAR error paths, data-heavy PDF regressions

## Schema / migration notes

`schemaVersion` anchor (commit `78df348`) sets the foundation for v1.1
data migrations. No migration required for this PR — `schemaVersion: 1`
is the floor. Existing TestFlight drafts decode cleanly.

## IAP rename — required ASC sync

`ca93de8` renames product IDs to `com.nexgenspec.annualv1` and
`com.nexgenspec.monthlyv1`. Both products must exist in App Store
Connect in the `nexgenspec_pro` subscription group AND have status
"Ready to Submit" before the build-10 binary is uploaded, or App Review
will fail the IAP submission. The annual product is created; monthly is
in progress (tracked separately in T-01222).

## Out of scope (will land in a follow-up)

- Debug-only `DemoModeFixture` for screenshot capture (uncommitted in
  branch — separate PR after merge)
- Screenshot capture script at `scripts/screenshots.sh` (uncommitted)
- ASC text drafts + Privacy Label click-through guide in `AppStore/`
  (documentation only, uncommitted)
