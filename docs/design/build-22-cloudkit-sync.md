# NexGenSpec Build 22 — CloudKit Sync: Design Doc & Frozen Contract (P0)

> **Status:** DRAFT — awaiting Nick's sign-off. No code is written until this is signed off.
> **Project:** P-0003 NexGenSpec · NickOS task **T-01582** · blockers **B-0117** (resolved), **B-0118** (open, non-code gate).
> **Baseline:** `main @ 6e5bc12` = 1.0.0 (build 21), on TestFlight, carrying the B-0117 fix.
> **Branch:** `edit/cloudkit-sync-build22`.
> **Target:** 1.0.x → **build 22** (`MARKETING_VERSION` TBD with Nick; `CURRENT_PROJECT_VERSION = 22`).

---

## 0. What this build delivers (DONE definition)

One inspector's inspections appear and stay in sync across **all three** of their own
devices — iPhone + iPad + Mac — keyed off **their iCloud account**, while the local-first
per-UID store remains the never-wiped source of truth. Capture works on iPhone/iPad; Mac is a
finalize/review station with capture gracefully hidden. With sync OFF (default) or no iCloud, the
app is behaviorally **identical to build 21**.

Mac is **in scope this build**, not a follow-on.

**Nick handles App Store submission.** This doc ends at: all gates green on a real iOS+Mac build,
CloudKit schema deployed to Prod, `CFBundleVersion = 22`, PR opened.

---

## 1. Verified ground truth (read from the repo, not assumed)

| Fact | Source | Implication |
|---|---|---|
| Local store path = `Application Support/NexGenSpec/Users/<firebaseUID>/` | `FilePaths.appRoot` + `SessionScope.currentSegment` | Local key = **Firebase UID**, never Apple ID. |
| `currentSegment = pinnedUID ?? activeUID ?? "_nobody"`; `activeUID = Auth.auth().currentUser?.uid` | `SessionScope.swift:37-68` | Identity for the local path is fully Firebase-derived. |
| `indexURL` is **computed** per-UID on every read/write | `InspectionStore.swift:43` | The store already re-resolves paths per active user (B-0096 fix). |
| Account-switch seam | `NexGenSpecApp.swift:113-127` `onChange(of: authManager.currentUID)` → `SessionMigration.runIfNeeded()` + `store.reloadFromDisk()` + `CustomTemplateStore.reload()` | **The single hook point** for sync start/stop/rebind. |
| Per-inspection layout | `FilePaths.swift:125-235` | `Inspections/<jobId>/current.json` (source of truth), `versions/<versionId>.json` (immutable snapshots), `photos/ thumbnails/ videos/ lidar/ annotations/ signatures/`, cover photo at root; index at `inspections.json` (+ `.backup`). |
| `current.json` is per-inspection source of truth | `InspectionStore.rebuildIndexFromVersionFiles()` | Index is **derivable**; sync at the version-JSON granularity is sufficient + self-healing. |
| Immutability invariant | `InspectionState.isEditable` false for `.finalized`/`.revised`; `InspectionStateMachine`; finalize writes+verifies integrity hash before `locked=true` (`InspectionStore.finalize` + `FinalizationService`) | Conflict policy = **LWW for drafts only**; finalized/locked records immutable. |
| **No wipe on logout** | `AuthManager.logout()` clears in-memory + profile/templates/temp only; `InspectionStore.wipeAppRoot()` fires **only** on Account Deletion + interrupted-deletion recovery | Landmine 2 is structurally satisfied today; the job is to **not regress it**. |
| Diagnostics sink | `Diagnostics.logError(context:error:persistToDisk:)` → Crashlytics + optional on-disk log **inside appRoot** | CloudKit errors pipe here; **the on-disk `diagnostics.log` must be excluded from sync** (it lives in appRoot). |
| Entitlements today | `NexGenSpec.entitlements` = **only** `com.apple.developer.applesignin` | Must ADD CloudKit container + remote-notification (Nick, dev portal). |
| Build flags | `TARGETED_DEVICE_FAMILY="1,2"`, `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD=NO`, build 21, bundle `com.nexgenspec.app` | iPad ships; Mac is OFF; no `UIBackgroundModes` in `Info.plist` yet. |
| `UIRequiredDeviceCapabilities` | none required (verified) | Good — do **not** add camera/LiDAR as required when enabling Mac. |

---

## 2. THE IDENTITY CONTRACT (load-bearing — everything depends on this)

Two **independent** identity systems:

- **Firebase UID** — the app login (email/password or Sign in with Apple). **Keys the local store. Never changes meaning.**
- **iCloud Apple ID** — the device's iCloud account. Keys the CloudKit private DB. We never read the
  raw Apple ID; CloudKit exposes a stable, per-container **`CKRecord.ID` for the user record**
  (`CKContainer.userRecordID`) and `CKShare.Participant` identity. We persist a *hash/opaque token* of
  `userRecordID`, not the Apple ID.

### 2.1 The rule

> **The local path NEVER keys on Apple ID.** Firebase UID stays the sole local key. CloudKit is an
> observer/mirror bound to the Firebase-UID store via an explicit, locally-persisted binding table.

### 2.2 The binding table

A locally-persisted (Keychain-backed, `…ThisDeviceOnly`, like the fallback-email store) map:

```
SyncBinding {
  firebaseUID: String          // local store key
  cloudUserToken: String       // hash(CKContainer.userRecordID) — opaque, not the Apple ID
  zoneName: String             // CloudKit custom zone bound to this firebaseUID (see §4)
  boundAt: Date
  seededAt: Date?              // set once one-time seeding completes (idempotency, §7)
  schemaVersion: Int
}
```

Stored **per firebaseUID**, in the Keychain (never plist/UserDefaults → never lands in an unencrypted
backup). One row per (firebaseUID) on this device. The binding is what lets us detect every edge below.

### 2.3 Edge-case matrix (every case explicitly defined)

| # | Scenario | Behavior |
|---|---|---|
| A | Normal: same firebaseUID + same iCloud across devices | Bind on first sync; mirror both ways. The happy path. |
| B | **One app account across two iClouds** (firebaseUID X signs in, iCloud changes to a different Apple ID) | `cloudUserToken` no longer matches the binding for X → **refuse-and-isolate**: stop sync, do **not** push X's local data to the new iCloud, do **not** pull the new iCloud's data into X's local store. Surface "iCloud account changed — sync paused." Local store untouched. |
| C | **One iCloud across two app accounts** (firebaseUID X then Y on the same iCloud) | Each firebaseUID gets its **own custom zone** in the same private DB (zone name derived from firebaseUID, see §4). Y never reads X's zone. No cross-contamination because the local store is already per-UID and the zone is per-UID. |
| D | iCloud signed out entirely (`CKAccountStatus != .available`) | Detach sync (no engine), app runs 100% locally (build-21 behavior) + soft "Sign in to iCloud to sync" nudge. **No local mutation.** (§9) |
| E | App signed out (Firebase logout) | Existing seam clears in-memory state; sync engine stops. Local per-UID store stays on disk (unchanged today). On re-login to the same firebaseUID, sync resumes against the same zone. |
| F | Apple ID changes **under** a logged-in firebaseUID mid-session | Same as B — refuse-and-isolate, pause sync, never cross. |
| G | Account **deletion** (Firebase `user.delete()`) | Local wipe path runs as today. Additionally: tear down the binding for that firebaseUID and **delete its CloudKit zone** (best-effort) so no residual PII in iCloud (5.1.1(v) parity). |
| H | First sync on a device that already has local data (build-21 upgrader) | One-time idempotent seeding (§7), guarded by `seededAt`. |
| I | Two devices offline edit the same draft, then both come online | LWW on drafts by `modifiedAt` (§8). Finalized never conflicts (immutable). |
| J | Sign-in ordering: Firebase before iCloud ready, or vice-versa | Sync engine is started/stopped **reactively** off both `authManager.currentUID` (seam) **and** `CKAccountStatus` change notifications; whichever readies last triggers bind. Never assume an order. |

**Refuse-and-isolate is fail-closed:** any ambiguity about which identity owns the data → stop sync,
never move data, never wipe, log to Diagnostics, surface a non-destructive banner.

---

## 3. Architecture

- **Local-first store stays the source of truth.** CloudKit is an **observer/mirror**.
- **CloudKit PRIVATE DB**, mirrored **manually via `CKSyncEngine`** (iOS 17+/macOS 14+) over
  `CKRecord`s in a **custom zone per firebaseUID**.
- **`NSPersistentCloudKitContainer` is REJECTED** — it wipes the local store on iCloud sign-out (data
  loss). We never let Apple's machinery own the local store.
- **Firebase plaintext sync REJECTED** — custodian/breach liability + re-opens the cross-account leak
  class server-side. (Firebase+E2E only if server-readable data is ever needed — it isn't.)
- The vendor (Nick) stores nothing; Apple enforces per-user isolation; per-zone isolation enforces
  per-firebaseUID isolation within one iCloud.

### 3.1 What syncs (quota-aware — counts against the USER's 5 GB iCloud)

| Tier | Content | Sync policy |
|---|---|---|
| Always | inspection version JSON (`current.json` + immutable `versions/*.json`), report PDF, integrity snapshot/hash, cover-photo thumbnail | Pushed/pulled always — small, the legal record. |
| On-demand / optional | raw photos, videos, LiDAR/USDZ, full-res signatures | `CKAsset`, fetched lazily on the device that needs them; a per-device toggle "Sync original media over iCloud" (default OFF). |
| **Never synced** | `diagnostics.log`, `audit_log.txt` (device-local plaintext), `.b0096-migrated` marker, deletion receipts | Excluded explicitly. |

### 3.2 The seam hook

`NexGenSpecApp.onChange(of: authManager.currentUID)` already re-scopes the store. We extend exactly
this point (plus a `CKAccountStatus` observer) to **start/stop/rebind** the sync engine. No other code
path touches identity, so this is the only seam.

---

## 4. CloudKit schema v1 (Dev environment ONLY until P7)

Designed for evolution: every record carries `schemaVersion: Int` (start `1`); **additive-only**
changes thereafter (new optional fields, never rename/retype/remove). Deployed to **Dev** during
development; promoted **Dev → Prod exactly once, LAST** (§ slice plan P7), because Prod schema is
near-irreversible.

**Zone:** `CKRecordZone(zoneName: "ngs-<hash(firebaseUID)>")` in the private DB — one zone per
firebaseUID (edge C isolation). Zone-level deletes give clean per-account teardown (edge G).

**Record types:**

| Record type | Key fields | Notes |
|---|---|---|
| `InspectionVersion` | `recordName = versionId.uuidString`; `inspectionId`, `versionNumber`, `status`, `locked`, `finalizedAt`, `modifiedAt`, `schemaVersion`, `payload: CKAsset` (the version JSON), `clientNameEnc?`/metadata for listing | One record per version. `locked == true` ⇒ immutable (server-side we never overwrite a locked record — see §8). |
| `ReportPDF` | `recordName = "pdf-<versionId>"`; `versionId` ref, `pdf: CKAsset`, `schemaVersion` | Always synced. |
| `MediaAsset` | `recordName = "<jobId>/<relativePath>"`; `jobId`, `relativePath`, `kind`, `blob: CKAsset`, `schemaVersion` | On-demand tier. |
| `SyncMeta` | singleton per zone; `schemaVersion`, `seedComplete`, `appBuild` | Lets a newer client detect an older zone and refuse/upgrade additively. |

Record `payload`/`pdf`/`blob` use `CKAsset`; small metadata fields are queryable for listing without
downloading payloads.

---

## 5. The `SyncPort` protocol (the seam contract)

Sync is injected behind a protocol so (a) flag-OFF compiles it out of the hot path, (b) it's unit-
testable with an in-memory fake, (c) the local store has **zero** compile-time dependency on CloudKit.

```swift
protocol SyncPort: AnyObject {
    /// Reactive lifecycle — called from the identity seam + CKAccountStatus observer.
    func bind(firebaseUID: String) async        // start/resume mirror for this UID (no-op if flag off / no iCloud)
    func unbind()                                // stop mirror, never touch local data
    /// Local store → cloud (observer pushes local changes; never the reverse-as-truth).
    func recordLocalChange(_ change: SyncChange)
    /// One-time, idempotent seeding entry point (guarded by binding.seededAt).
    func seedIfNeeded(firebaseUID: String) async
    /// Status for UI + observability.
    var status: AnyPublisher<SyncStatus, Never> { get }
}

enum SyncStatus { case off, localOnly, idle, syncing, paused(reason: String), error(String) }
```

A `NoopSyncPort` is the flag-OFF / no-iCloud implementation (does nothing) → guarantees flag-OFF ==
build 21. The `CloudKitSyncPort` is the real one. The store calls `recordLocalChange` on the existing
write paths (`writeVersionToFile`, finalize, delete) — additively, behind the port.

---

## 6. Feature flag

- `SyncFeature.isEnabled` — compile-time-capable, runtime-gated; **default OFF**. Drives whether the
  app constructs `CloudKitSyncPort` or `NoopSyncPort`.
- **Local-only mode** — a user-facing, persisted setting (for NDA/privacy users) that forces
  `NoopSyncPort` even when the flag and iCloud are available. Fail-closed: when local-only is on,
  CloudKit is never touched.
- **Opt-in** — sync is OFF by default even when available; the user turns it on. (App Store rule: we
  may not *require* iCloud.)
- Three independent gates, all must be true to sync: `flag enabled` ∧ `not local-only` ∧
  `CKAccountStatus == .available` ∧ `binding valid`.
- **Sync is NOT subscription-gated (DECIDED).** Business model = 3 free *watermarked* reports with
  **all** features (sync included), then subscribe to keep creating. So there is **no Pro check in the
  sync path** — the existing subscription gate stays on report *creation/finalization*, and sync just
  mirrors whatever is already local. This keeps the sync gate to the four conditions above.
- **Free-quota edge (DECIDED):** the free-3 counter is per-device via DeviceCheck
  (`refreshDeviceCheckTrial`). A report **synced in** from another device must **never** increment this
  device's create-counter — the quota is on *creation* and was already counted at the origin. Enforced
  in slice 4 (apply-back path). Subscription state itself is not synced (StoreKit/Universal Purchase
  carries it per Apple ID).

---

## 7. One-time seeding (build-21 upgraders)

- Triggered on first valid bind for a firebaseUID with `binding.seededAt == nil`.
- **Idempotent + guarded + dedup-proof**: enumerate local `Inspections/<jobId>/current.json` +
  `versions/*.json`; for each, `CKModifyRecordsOperation` with `recordName` deterministically derived
  from `versionId` and `.ifServerRecordUnchanged` / save-policy that **never clobbers** an existing
  cloud record. Set `binding.seededAt` only after the full pass completes with no remaining un-pushed
  records (mirrors the B-0096 migration's "marker only after source fully drained" pattern).
- **Interrupt-safe**: a partial seed resumes; already-pushed records are skipped by recordName
  existence. Re-running is a no-op.
- **Lossless**: seeding never deletes or mutates local data; it only pushes.

---

## 8. Conflict resolution

- **Finalized/locked versions are IMMUTABLE.** Server rule: a record with `locked == true` is never
  overwritten; if both sides have a locked record for the same `versionId`, they are byte-identical by
  construction (integrity hash) — assert + log if not, never merge. A revision is a **new** versionId,
  so it never collides.
- **Drafts: last-writer-wins by `modifiedAt`.** Two devices editing the same draft → the higher
  `modifiedAt` wins the whole version record. (Field-level merge is out of scope for v1; drafts are
  single-inspector working copies, low real-world contention.)
- Never resurrect a deleted inspection: deletes propagate as record deletions within the zone; a
  tombstone (`SyncMeta` deletion log) prevents a stale offline device from re-pushing a deleted draft.

---

## 9. Graceful degradation (`CKAccountStatus` matrix)

| Status | Behavior |
|---|---|
| `.available` + flag on + not local-only + binding valid | Full sync. |
| `.noAccount` / `.restricted` (MDM iPad) / `.couldNotDetermine` | `NoopSyncPort`; app 100% local (build 21); soft "Sign in to iCloud to sync" nudge; never block, never lose. |
| `.temporarilyUnavailable` | Treat as paused; retry on next status change; local unaffected. |

App-Store-but-not-iCloud users are fully supported (local-only path). **We never require iCloud.**

---

## 10. Mac target

- **Approach: Designed-for-iPad (DECIDED)** — flip `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD=YES`.
  Pros: one build-setting flip, no new UI, Apple-silicon native, ships immediately, free. Cons: "iPad
  app on Mac" — no native macOS menu bar / multi-window / AppKit, iOS-only capture APIs unavailable
  (irrelevant — capture is hidden on Mac). None of the cons bite a finalize/review station. Mac
  Catalyst remains the later upgrade path if true desktop polish is ever wanted.
- Mac = **finalize/review station**: camera/LiDAR capture UI **hidden** (not disabled-as-dead), with a
  "Capture on iPhone/iPad" affordance. Degrades cleanly when camera/LiDAR are absent.
- Do **not** add camera/LiDAR to `UIRequiredDeviceCapabilities` (would block Mac install + Apple
  rejection for dead features).
- **Universal Purchase** so Pro carries to Mac (Nick, App Store Connect).

---

## 11. Observability

- All CloudKit errors → `Diagnostics.logError(...)` (Crashlytics sink already exists). **No swallowed
  failures.** Every `SyncPort` failure path logs with a stable `context:` tag.
- A sync-status UI surface (small status pill + a Settings "iCloud Sync" section reflecting
  `SyncStatus`), so a silently-failing field push is visible.
- `diagnostics.log`/`audit_log.txt` are **excluded from sync** (they live in appRoot).

---

## 12. The two landmines — explicit proofs to be enforced

1. **IDENTITY:** local path computed solely from `SessionScope.currentSegment` (Firebase UID). No sync
   code may ever write to a path derived from Apple ID. Enforced by: keeping all path resolution in
   `FilePaths`/`SessionScope` untouched; the `SyncPort` operates on records, never on `appRoot`
   resolution. **Gate: adversarial-verify (P6).**
2. **NEVER AUTO-WIPE LOCAL:** `CloudKitSyncPort.unbind()` and every `CKAccountStatus` transition are
   pure detach — they call no wipe. The only `wipeAppRoot()` callers stay exactly the two existing
   Account-Deletion paths. **Gate: real-build-test — prove iCloud sign-out / Apple-ID change loses
   nothing.**

---

## 13. Validation gates → method (mirrors T-01582)

| Gate | Method |
|---|---|
| Local store NEVER keys on Apple ID | adversarial-verify |
| iCloud sign-out / Apple-ID change NEVER wipes local | real-build-test |
| Seeding idempotent, lossless, dedup-proof across re-runs + interrupt | loop-until-dry |
| Finalized immutable under two-device conflict | adversarial-verify |
| Server-side cross-account isolation in CloudKit zones | audit-fanout |
| Opt-in/local-only fully bypasses CloudKit (fail-closed) | adversarial-verify |
| FLAG-OFF == build 21 behaviorally | regression-test |
| Sync failures observable (no swallowed errors) | audit-fanout |
| Real xcodebuild + XCTest on iOS AND Mac (Mac w/o camera/LiDAR degrades) | real-build-test |
| CloudKit schema additive-only/forward-compat BEFORE Prod deploy | adversarial-verify |

---

## 14. Implementation plan (slices, mostly SOLO, flag OFF, each + its gate)

- **P1 — Workflow parallel (read-only finders):** map the full store/auth/finalize/media surface so
  slices code against reality. *(Already partially done inline for the spine; P1 widens it.)*
- **Slice 1:** feature-flag scaffold + `SyncPort`/`NoopSyncPort` + binding table (Keychain). Gate: flag-OFF == build 21.
- **Slice 2:** read-only mirror (push local→cloud, no apply-back). Gate: isolation + no-wipe.
- **Slice 3:** idempotent one-time seeding. Gate: loop-until-dry.
- **Slice 4:** two-way sync + conflict resolution (Workflow pipeline if per-record). Gate: finalized-immutable.
- **Slice 5:** Mac target enablement (Workflow parallel + worktree — project file / sources / assets are file-disjoint). Gate: real iOS+Mac build.
- **P6 — Workflow parallel (adversarial validation):** one REFUTE-verifier per risk + completeness critic + code-class sweep, then real build/test as the final sequential gate; loop-until-dry on defects.
- **P7 — SOLO gated ship:** deploy CloudKit schema Dev→Prod (LAST, near-irreversible), bump `CURRENT_PROJECT_VERSION → 22`, open PR.

Every slice touching data integrity/isolation gets a regression test (mirroring `FilesAppPublisherSafetyTests`). Real `xcodebuild` before any "done". D-0131: `df -h /` > 10 GB before any Xcode session (currently 41 GB free ✓).

---

## 15. Non-code gating (owner: Nick) — before ANY build-22 App Store submission

Tracked in NickOS **B-0118**:

- [ ] Rewrite `nexgenspec.com/privacy.html` + `/terms.html` + `support.html` FAQ (incl. FAQPage JSON-LD) — they currently say "data never leaves the device" (true for build 21, FALSE once synced).
- [ ] Re-answer App Store Connect **App Privacy** questionnaire (data now transits iCloud). [Verify exact CloudKit-private-DB treatment.]
- [ ] Update App Store description/keywords (drop "all data on-device").
- [ ] Create CloudKit container `iCloud.com.nexgenspec.app` + add iCloud/CloudKit + remote-notification entitlements (today: only Sign in with Apple). Deploy schema Dev→Prod before release.
- [ ] Do NOT add camera/LiDAR to `UIRequiredDeviceCapabilities`.
- [ ] Mac: Designed-for-iPad vs Catalyst; Mac screenshots; Universal Purchase; App Review notes.
- [ ] Physically verify sync on two devices on one iCloud AFTER the Prod schema deploy.
- **Legal track (owner: attorney, parallel):** custom EULA vs Apple LEULA; warranty/liability caps; controller-vs-processor allocation; e-signature consent-to-electronic-records (ESIGN/UETA); CCPA/state-law obligations.

---

## 16. Spike (design-validation; real CloudKit spike blocked on the container)

A running CloudKit spike requires the container `iCloud.com.nexgenspec.app` + entitlement, which is a
Nick/dev-portal task (§15). Until then the spike is **design-level**: the edge-case matrix (§2.3),
the seeding idempotency proof (§7), and the conflict/immutability rules (§8) are the spike's outputs.
First real code (slice 1) is inert behind the flag and needs no container; the container is required
only at slice 2 (first real push) and the Prod deploy at P7.

---

## 17. Decisions — RESOLVED with Nick (2026-06-22)

1. **Sync gating:** FREE / not subscription-gated. Sync is included in the 3-free-watermarked-reports
   model; subscription gates report creation, not sync. (§6) ✓
2. **Mac approach:** Designed-for-iPad. (§10) ✓
3. **`MARKETING_VERSION`:** stay `1.0.0` (nothing released to App Store yet); bump
   `CURRENT_PROJECT_VERSION → 22` only. ✓
4. **Original-media sync:** OFF / on-demand; JSON + PDF + thumbnails always. (§3.1) ✓

Contract frozen on these. Remaining work proceeds per §14.

---

## 18. P1 recon deltas (folded into the frozen contract, 2026-06-22)

From the read-only recon workflow (5 finders). These refine, not change, the contract:

- **In-app "no sync" copy is in the binary, not just the website.** `LegalScreens.swift:92-93` and
  `BackupStatusView.swift:69` both tell the user inspections do **not** sync between devices. These
  strings become false when sync is on, so they must be **flag-gated** (show sync-aware copy only when
  `SyncFeature` is enabled). This is a *code* gate, additional to B-0118's website work. (Addressed in
  the UI slice alongside slice 5; tracked here so it isn't missed.)
- **Quota "synced-in doesn't count" is naturally satisfied.** Local creation burns a free slot only
  because `DashboardView` calls `subscriptions.recordInspectionCreated()` after a successful
  `createNewInspection()`. Synced-in inspections will arrive via `InspectionStore.insert(version:)`,
  which does **not** call `recordInspectionCreated()` → no quota burn. **Robustness (slice 4):** add
  additive `originUID: String?` / `isSyncedCopy: Bool` (default false) to `InspectionVersion`
  (decodeIfPresent, schemaVersion already present) and rebuild `freeInspectionsUsed` from
  locally-created (non-synced) inspections on account switch, so the counter can't drift.
- **Minimal local-write seam set for slice 2's push mirror:** `InspectionStore.writeVersionToFile`
  (320-328), `writeVersionFileOnlyForAutoSave` (552-574), `saveMetadataIndex` (278-318),
  `FinalizationService.writeSnapshot` (22-41); deletes via `deleteVersion` (813-853) /
  `purgeExpiredInspections` (856-879); media writers (photo/video/signature/annotation/cover/LiDAR).
  Account-deletion wipe (`beginWipe`/`performDiskWipe`) must **pause** sync, never push.
- **`schemaVersion` already exists** on `InspectionVersion` (default 1) and `MetadataIndex` — good; the
  CloudKit `schemaVersion` mirrors it.
- **Media is referenced by filename string** in the JSON (never embedded). Confirms §3.1: JSON+PDF+
  thumbnail always; raw media as `CKAsset` on-demand. A media-sync pass must enumerate disk, not trust
  JSON alone, to avoid orphaned references on restore.
- **Test harness:** `SessionScope.uidProvider` override + stash-based temp `appRoot`; Firebase never
  configured in tests; XCTest runs with no device/signing. New sync tests follow `B0096ScopingTests` /
  `FilesAppPublisherSafetyTests` patterns.

### Slice 1 (implemented 2026-06-22, flag OFF, unwired)
Pure-additive scaffold under `NexGenSpec/Sync/`, not referenced by app code, so behavior == build 21:
`SyncFeature` (flag, default OFF + local-only mode), `SyncPort`/`SyncStatus`/`SyncChange`,
`NoopSyncPort` (inert), `SyncBindingStore` (Keychain-backed `firebaseUID → SyncBinding`, mirrors the
`AuthManager` fallback-email `SecItem` pattern, `…ThisDeviceOnly`). Regression test
`SyncScaffoldTests`.
