# NexGenSpec — Build 13 whole-build audit

**Build:** 1.0.0 (13) · **Commit:** `d0c6aed` · **Tag:** `build-13` · **Date:** 2026-06-05
**Method:** 8-subsystem multi-agent audit (find → adversarial refute → synthesize), 26 agents.
**Tracking lives in NickOS** (B-0062/63/64/65) — this doc is a point-in-time snapshot, not a tracker.

## Build confirmation

TestFlight build 13 maps unambiguously to source:

| Evidence | Value |
|----------|-------|
| App Store Connect | 1.0.0 **(13)**, Status Complete, created Jun 4 2026 7:21 PM |
| Git | `d0c6aed` — the **only** commit setting `CURRENT_PROJECT_VERSION = 13`; tree clean, `main` in sync with origin |
| Commit time | Jun 4 2026 5:18 PM (-0600), ~2h before upload — consistent |
| Pinned | annotated tag `build-13` → `d0c6aed`, pushed to origin |

## Verdict

**The build-13 binary is safe to submit.** 0 CRITICAL findings; no crashes, no normal-use data
corruption, no unauthenticated security holes survived verification. This run **independently
re-confirmed** the prior build-13 audit's top three findings (B-0062/63/64).

15 findings stand: **1 HIGH, 5 MEDIUM, 9 LOW.**

## The one pre-submission action

**B-0063** — `AppStore/PRIVACY_LABEL_CLICKTHROUGH.md:102` asserts *"no microphone use,"* but the
walkthrough video recorder captures and permanently retains a mic audio track (`VideoRecorderView.swift:25-28`,
stored via `InspectionOverviewView.swift:738-754`) and `NSMicrophoneUsageDescription` is declared. Pasting
that wording into the App Store Connect App Privacy label is a Guideline 5.1.1(i) accuracy mismatch.
**Fix the wording in ASC — no new binary required.** This is the only true submission gate.

## Resolved during this audit

The audit flagged ASC legal links using bare `/privacy` `/terms` (vs the `.html` routes in the binary)
as a possible dead-link rejection (5.1.1). **All four URLs were curl-checked and return HTTP 200** — not
a blocker. Recommend aligning the paths for consistency only.

## Ranked findings

| # | Sev | Finding | Location | NickOS |
|---|-----|---------|----------|--------|
| 1 | MED | Privacy-label "no microphone use" vs video records/retains audio (5.1.1 mismatch) | `AppStore/PRIVACY_LABEL_CLICKTHROUGH.md:102` | B-0063 |
| 2 | MED | ASC Privacy/Terms use bare routes vs `.html` in binary — **resolved, URLs 200** | `AppStore/metadata.txt:72-73` | — |
| 3 | HIGH | Non-atomic encrypted-backup restore, no rollback — mid-stream failure corrupts live store | `NexGenSpec/Services/EncryptedBackupService.swift:134-157` | B-0062 |
| 4 | MED | Pro PDF watermark gate is dead code — `hasFeatureAccess` always true for free users | `NexGenSpec/Services/SubscriptionManager.swift:89-91` | B-0065 |
| 5 | MED | ZIP export hardcodes `watermark:false`, no entitlement check | `NexGenSpec/Services/InspectionZIPExportService.swift:82-98` | B-0065 |
| 6 | MED | Company logo embedded full-res inline base64 — un-downsampled image can OOM the render | `NexGenSpec/HTMLReportRenderer.swift:60-73,199` | — |
| 7 | LOW | Recovery email stored unencrypted in UserDefaults (should be Keychain) | `NexGenSpec/AuthManager.swift:228-249` | — |
| 8 | LOW | Account email in plaintext in retention audit log (convention is UID-only) | `NexGenSpec/Services/RetentionPolicyService.swift:57` | — |
| 9 | LOW | Dead, weak unsalted-SHA-256 credential store ships unused | `NexGenSpec/Services/KeychainCredentialsStore.swift:20-49` | — |
| 10 | LOW | 502 responses echo Apple's raw DeviceCheck error body to client | `functions/src/index.ts:337-341,392-396` | B-0064 |
| 11 | LOW | No upper-bound length validation on client `deviceCheckToken` | `functions/src/index.ts:247-266` | B-0064 |
| 12 | LOW | PDF render copies videos it never references — wasted disk I/O | `NexGenSpec/HTMLReportRenderer.swift:41-51` | — |
| 13 | LOW | `fetchCurrentWeather` has no in-flight guard; re-entrant call orphans completion | `NexGenSpec/Services/WeatherService.swift:89-92` | — |
| 14 | LOW | `.notDetermined` location path has no app-level timeout — stuck "Fetching weather…" | `NexGenSpec/Services/WeatherService.swift:101-104` | — |
| 15 | LOW | Stale "BUILD 11" stamp in metadata vs submission build 13 | `AppStore/metadata.txt:10` | — |

## Net-new finding (B-0065): monetization double-leak

Free users get clean branded PDFs forever via two independent paths: the Pro watermark gate is dead code
(#4), **and** ZIP export bypasses gating entirely (#5). Revenue leak, not a submission blocker. Fix: gate
clean export purely on entitlement (`isPro || isAdminAccount || isBetaOrSandboxBuild`), plumb
`watermark: !hasFeatureAccess` into `exportZIP`, and add tests asserting fresh(0) and exhausted(3) free
users both receive watermarked PDFs.

## NickOS tracking

- **B-0062** (HIGH) — backup restore non-transactional/orphaning (finding #3)
- **B-0063** (MED) — privacy-label microphone mismatch (finding #1, the submission gate)
- **B-0064** (MED) — Cloud Functions hardening (findings #10, #11)
- **B-0065** (MED) — monetization double-leak (findings #4, #5) — filed by this audit

LOW-hygiene items (#6–#9, #12–#15) are recorded here for triage and not individually filed.
