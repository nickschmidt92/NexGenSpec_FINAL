# Build 22 — P6 Remediation Spec (flag-ON bug fixes before sync GA)

> **Handoff doc.** Pick up here for the post-P6 remediation. State as of the P6
> holistic adversarial pass (2026-06-22). Read alongside NickOS **T-01582**,
> **D-0183**/**D-0184**, and `docs/design/build-22-cloudkit-sync.md` (§13 gates).

## State
- Branch `edit/cloudkit-sync-build22`, **11 commits ahead of main** (main @ `6e5bc12` =
  build 21), **NOT pushed**, tree clean. Sync is **flag-OFF** everywhere (DEBUG-only;
  Release hard-OFF), so the shipping build behaves like build 21.
- Slices 1–5 done (push mirror, seeding, two-way pull/apply, Mac Designed-for-iPad).
  iOS suite **152/152**; iOS + Mac (Designed for iPad) builds **SUCCEEDED**.
- Three adversarial passes done pre-P6 (slice 4c ×2, slice 5 ×1) — all fixed.
- **P6 holistic pass (30 agents): 19 confirmed → 7 distinct issues below; 3 refuted.**

## Critical framing
- **Every P6 issue is a FLAG-ON bug.** None affect the shipping (dark) build. None block
  the P7 Dev→PROD *schema* deploy. They must land **before SyncFeature is enabled for
  users** (sync GA), not before build-22 submission.
- A–F + I are code fixes. Do A–F as ONE batch — they share `applyRemoteVersion` / the
  resolver / `current.json` read paths.

## The fixes

### A — CRITICAL: finalize never reaches CloudKit
`InspectionStore.finalize` keeps the same versionId and pushes it with `ifAbsent:true`
(locked never-clobber). But the draft record already exists in the zone, so
`.ifServerRecordUnchanged` on a tag-less record fails `serverRecordChanged`, which
`CKCloudDatabase.save` swallows as "left immutable" → the finalized payload/status/locked
**never upload**. Device B keeps the stale draft forever.
- **Fix:** push every `.versionUpserted` with **overwrite** (`ifAbsent:false` → `.changedKeys`).
  Receiver-side immutability is already enforced by `SyncConflictResolver.resolveUpsert`
  (keepLocal when local is finalized), so the push-side never-clobber adds no real
  protection — drop it. (Simplest correct fix; §8 immutability is a receiver guarantee.)
  Files: `CloudKitSyncPort.apply` (the `ifAbsent: meta.locked` arg), `CloudKitBackends.save`.
- **Test fix (load-bearing):** `FakeDatabase.save` in `CloudKitSyncPortTests` must model
  `serverRecordChanged` — reject an `ifAbsent:true` save when the recordName already
  exists — and add a test: push a draft for a versionId, then finalize the SAME versionId,
  assert the stored record ends up `locked==1 / status=="Final"` with the finalized payload.
  Update/replace `testFinalizedUsesNeverClobberSaveAndDraftsOverwrite` (it asserts the
  wrong thing — only that `ifAbsent==true` was requested).

### B — HIGH: account-switch TOCTOU cross-account leak (gate 5 / landmine 1)
`DiskVersionReader` and `InspectionStoreVersionWriter` resolve `FilePaths.appRoot` **live**,
not pinned to the bound UID. On A→B switch, `NexGenSpecApp` runs `store.reloadFromDisk()`
(appRoot now=B) before `syncCoordinator.userDidChange(B)`, and the old port's in-flight
`bind/seed/pull` Task isn't cancelled — so an A-port op suspended at an `await` resumes
with appRoot=B: it pushes B's disk into A's zone, or writes A's cloud records into B's store.
- **Fix (robust):** pin isolation to the UID — give `DiskVersionReader` /
  `InspectionStoreVersionWriter` an explicit appRoot (or UID) captured at bind, resolve all
  paths against it (a per-UID `FilePaths` override), so a captured binding can never touch
  another UID's disk.
- **Plus (defense in depth):** `SyncCoordinator.rebind` should capture + `cancel()` (and
  ideally await) the old port's bind Task before swapping; `seed/pull/flushPending` re-check
  `activeBinding`/`Task.isCancelled` after each `await` before `database.save`/`writer.apply`.
- **Test:** switch UID mid-seed and mid-pull; assert no B-record reaches A's zone and no
  A-record reaches B's store. (Also fills the gate-5 test gap.)

### C — HIGH: account deletion never tears down the CloudKit zone/binding (edge G)
Deletion paths (`AppSettingsView.finishLocalWipeAndDismiss`, `NexGenSpecApp` onAppear
recovery) wipe local only. `SyncBindingStore.delete(forUID:)` has zero callers; there is no
`deleteZone`. With the flag on, client PII (in the version payload CKAssets) stays in the
user's private iCloud after account deletion — Apple 5.1.1(v) / design §2.3-G gap.
- **Fix:** add `CloudDatabase.deleteZone(_:)` → `CKCloudDatabase` via
  `modifyRecordZones(saving:[], deleting:[zoneID])`. On BOTH deletion paths, capture the
  deleted firebaseUID's `SyncBinding` BEFORE wipe; if present and `SyncFeature.isEnabled`,
  best-effort `deleteZone(binding.zoneName)`, then `SyncBindingStore.delete(forUID:)`, and
  detach the coordinator. Best-effort (catch + `Diagnostics.logError`, never block the wipe).
  Gate on a binding existing + flag-on so flag-OFF stays a strict no-op.
- **Test:** deletion with a binding (flag on) invokes deleteZone + binding delete; no-op when
  no binding / flag off.

### D — HIGH: undecodable current.json fails OPEN on immutability (gate 4 + 8)
`DiskVersionReader.localState` collapses a read/decode failure of an EXISTING `current.json`
to `version=nil` → `isFinalized=false` (and logs nothing). The resolver then treats a
finalized report as an editable draft → `applyRemoteVersion` (which bypasses `allowsEdit`)
overwrites the immutable legal record. (The delete path is saved by `deleteVersion`'s
metadataList `allowsEdit` guard; the upsert path has no second layer.)
- **Fix:** `localState` fails CLOSED — distinguish missing (→ `.absent`) from
  existing-but-undecodable, log the decode error (mirror `versionData`/`allLocalVersions` +
  the B-0044 pattern), and return a state the resolver maps to **keepLocal** (e.g. an
  explicit `undecodable` case, or `isFinalized:true`). Belt-and-suspenders: in
  `InspectionStore.applyRemoteVersion`, re-check the in-memory `metadataList` entry and refuse
  to overwrite a locked local entry with a non-superseding remote.
- **Test:** resolver/reader returns keepLocal for an existing-but-undecodable finalized version.

### E — HIGH/MED: integrity snapshot never reaches device B (gate 12 / §3.1 Always tier)
Only `current.json` syncs; the integrity snapshot lives in a separate `versions/<id>.json`
written by `FinalizationService.writeSnapshot` and is never synced. On device B,
`loadReportHash` returns nil → `HTMLReportRenderer` renders a FINALIZED report as a *draft*
with no integrity hash; ZIP/PDF exporters emit hash `""`/"unknown". This is the Mac
review-station's primary path.
- **Fix (cheap, no schema change):** in `InspectionStore.applyRemoteVersion`, when the applied
  version is finalized/locked, re-run `FinalizationService.writeSnapshot(version)` so
  `versions/<id>.json` + its hash exist locally. The hash is over the canonical sorted-keys
  encoding of the model, so the recomputed hash is byte-identical to the origin device's.
- **Test:** apply a finalized remote version; assert `loadReportHash` is non-nil and matches.

### F — MED: flushPending drops outbound edits when unbound + false "will retry"
`flushPending` clears `pending` BEFORE the `guard let binding`, so an edit made during a
transient unbind (`.localOnly` / `.paused` / bind-in-flight) is silently dropped (seeding
only runs once, so it won't re-push). And line ~234 sets `.error("…will retry")` with no
retry mechanism.
- **Fix:** snapshot `pending` without clearing; if unbound, return WITHOUT clearing (log per
  §11); remove a change only after its push succeeds. Re-drive `flushPending()` at the end of
  `bind()` (once `activeBinding` is set) and on foreground. Drop/append the "will retry"
  wording to match reality.
- **Test:** edit while unbound then bind → the change is pushed (not lost).

### I — NIT: finalize re-stamps updatedAt after the snapshot is hashed
`finalize` hashes `updated` (draft-time updatedAt) then `writeVersionToFile` stamps a fresh
updatedAt into `current.json`, so it diverges from the sealed snapshot on a hash-covered
field. No observable consequence today, but a locked record shouldn't be re-stamped.
- **Fix:** in `writeVersionToFile`, gate the stamp with `&& !version.locked` (a finalized
  version's edit time is fixed at finalize). Optional test: finalized `current.json.updatedAt`
  == snapshot's.

## Deferred (document, no code now)
- **SyncMeta deletion tombstone (§8):** not implemented → a stale offline device can resurrect
  a deleted draft. LOW (single-inspector contention; additive later). Decision needed: defer +
  document in §8/§12 as a known flag-gated gap, or implement a per-zone deletion log.
- **finalizedAt schema materialization (P7 checklist):** the Dev schema only gains `finalizedAt`
  once a FINALIZED record is pushed in Dev. Add to §15: push a finalized record + verify in the
  CloudKit Dashboard that `InspectionVersion` has every `CloudKitSchema.Field` before promoting
  Dev→Prod. (The 2-device test naturally does this.)
- **Unused background mode:** `remote-notification` UIBackgroundMode + `aps-environment` ship in
  build 22 though APNs is deferred (D-0184). Minor App Review "unused capability" consideration —
  leave as forward-prep, or strip until APNs lands. Nick/submission call.

## Validation after fixes
- `xcodebuild test … -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:NexGenSpecTests`
  (ProcessSuspension "error:" = OS noise).
- Mac build: `xcodebuild build … -destination 'platform=macOS,variant=Designed for iPad'`.
- Re-run an adversarial pass focused on A–F (loop-until-dry), then commit on the branch (never
  main; PR at P7).
- OPS: app target is a synchronized group (drop files in `NexGenSpec/` subfolders, no pbxproj
  edit) EXCEPT build-setting flips; TEST target needs 4 manual pbxproj entries per new test file
  — prior slices added tests to existing in-target files to avoid that. D-0131: `df -h /` > 10GB
  before any Xcode session.

## Adversarial re-pass (round 2) — results & corrections

The post-implementation adversarial pass (8 reviewers + 2-skeptic verification) surfaced 10
confirmed issues. Three were real regressions in the first-cut fixes and were **corrected**;
two are deferred to the sync-GA gate; the rest were test-quality gaps (now closed).

**Corrected in this batch:**
- **A (immutability at the source):** the first cut pushed every `.versionUpserted` with
  `ifAbsent:false` (always overwrite). That was wrong: two devices finalizing the SAME versionId
  offline produce DIVERGENT payloads (`finalizedAt = Date()` per device), so an always-overwrite
  let the second finalize clobber the first finalized cloud record, and a fresh-pulling device
  then adopted the clobber. The spec's "two finalized copies are byte-identical / immutability is
  a receiver guarantee" premise is **false** for this case. Fix now: `CloudDatabase.save` is a
  **fetch-then-conditional** — it overwrites a draft (promotion works) but NEVER overwrites an
  already-`locked` server record (immutability enforced at the source). `ifAbsent` param removed.
- **B (writer cross-account guard):** the first cut checked `SessionScope.currentSegment ==
  boundUID` inside the writer, OFF the MainActor, then hopped to `MainActor.run` to write — a real
  TOCTOU gap (the write still resolves the live `appRoot`). The guard now lives INSIDE
  `InspectionStore.applyRemoteVersion/applyRemoteDelete(expectedUID:)`, synchronous on the
  MainActor and atomic with the write (account switches also run on the MainActor, so none can
  interleave). Reader pinning (DiskVersionReader uid) was already correct.
- **C (deletion teardown after an iCloud switch):** `deleteZone` ran against the CURRENT iCloud
  account; after an Apple-ID switch the zone lives in the OLD (inaccessible) private DB, so it
  deleted nothing real while falsely succeeding. Teardown now checks the live `cloudUserToken`
  against `binding.cloudUserToken` and only deletes the zone when they match; otherwise it logs
  and still drops the local binding.

**Deferred to the sync-GA gate (NOT build-22 blockers — sync ships dark):**
- **D / transient read failure (vs decode corruption):** `current.json` is `.completeUnlessOpen`,
  so a pull while the device is locked could read-fail transiently; failing closed + advancing the
  change token would strand a legitimate remote update. In build 22 the only pull triggers are
  bind + foreground (device unlocked), so this is **not reachable**. `localState` now distinguishes
  read-fail from decode-fail (distinct logs), both fail closed. **When the deferred APNs background
  pull (D-0184) lands, that slice MUST not advance the change token on a transient read miss
  (retry next pull) instead of treating it as a settled keepLocal.**
- **I+E / legacy-finalized hash divergence:** reports finalized on build 21 / pre-fix-I stamped
  `current.json.updatedAt` to finalize-time AFTER hashing the draft-time snapshot, so for those
  legacy reports `current.json.updatedAt != snapshot.updatedAt`. Fix E's cross-device recompute
  hashes `current.json`, so a device that pulls a legacy-finalized report computes a hash that
  DISAGREES with the origin's stored snapshot hash. Reports finalized under fix I and later are
  consistent. **Before sync GA, decide for legacy data: (a) accept the divergence, (b) sync the
  snapshot file instead of recomputing, or (c) a one-time re-seal migration of legacy current.json.**

**Test gaps closed:** direct `DiskVersionReader.localState` undecodable-`current.json` fail-closed
test (D); the fix-E byte-identical-hash test now round-trips through JSON encode/decode (mimics the
real payload-decode pull path); finalize-over-finalize immutability test (A); iCloud-switch teardown
test (C).

### Round-2 pass — corrections to the round-2 corrections (loop-until-dry)

A second adversarial pass over the round-2 corrections found two real bugs the corrections
introduced; both fixed:
- **B (token-advance data loss):** the cross-account guard in
  `InspectionStore.applyRemoteVersion/applyRemoteDelete` returned `true` (skip). `true` keeps
  `pull()`'s `allApplied`, so it ADVANCED the bound account's change token past the un-applied
  record — and incremental pulls never re-fetch past the token, so the account's own cross-device
  edit was permanently, silently lost during the Firebase-flips-before-rebind window. Now returns
  **`false`** (holds the token for retry under the correct binding — same contract as the
  disk-write-failure path). The writer test now asserts `false`.
- **C (orphaned zone):** `SyncAccountTeardown` dropped the binding UNCONDITIONALLY even when the
  zone wasn't deleted (iCloud unavailable → token nil, or `deleteZone` threw transiently). A first
  attempt to "keep the binding so the recovery path retries" was then found (round-3) to rest on a
  FALSE premise — a *normal* completed deletion clears the `deletion-pending-wipe` flag + pin
  before the detached teardown Task runs, so the recovery branch never re-fires and the kept
  binding just lingers (no retry, zone still orphaned — arguably worse). **Final:** the teardown is
  one-shot **best-effort exactly as the spec scopes it** — deleteZone only when the live iCloud
  token matches the bound one (so it never hits the wrong/unknown DB — finding #4), then drop the
  binding regardless. A transient failure leaves the zone as a documented residual in the user's
  OWN private iCloud (Apple-isolated per Apple ID — not a cross-account leak).

### Round-3 pass — C teardown finalized as best-effort; durable retry deferred to sync GA

The round-2 "keep-binding-for-retry" correction was itself wrong (the retry path is unreachable on
a normal deletion). Reverted to spec-compliant **best-effort**: try deleteZone (only when the
current iCloud user owns the zone), log on failure, never block the wipe, drop the binding. B's
`return false` (token-hold) verified clean by this pass. **KNOWN LIMITATION / sync-GA item:** a
transient `deleteZone` failure or iCloud-unavailable at the exact deletion moment leaves the
account's zone as a residual with no durable retry. A robust solution needs a persisted
"teardown-owed" record + a cold-launch sweep, INDEPENDENT of the deletion pin (which a normal
completed deletion clears) — a sync-GA design decision, **not** a build-22 blocker (build 22 ships
sync dark). Tests updated to assert the best-effort drop on both transient paths.

## P7 pre-flight — independent fresh-eyes re-verification (2026-06-22)

Orchestrated re-verification of commit `8cfd34d` with fresh eyes (5-dimension adversarial
fan-out + 2-skeptic verification per finding; build gate re-run from a clean tree), prior to
the Nick-gated P7 ship. **Bottom line: build-22 verification is GREEN — no build-22-affecting
code defect.** flag-OFF == build 21 is provably inert; identity and immutability are clean for
the shipping build.

**Build gate (re-run):** iOS `NexGenSpecTests` **166/166, 0 failures**; Mac (Designed for iPad)
**BUILD SUCCEEDED**. (One environment snag, not a code defect: a stale SPM artifact-cache entry
for `GoogleAdsOnDeviceConversion.zip` — "already exists in file system" — blocked package
resolution until the entry was removed and `-resolvePackageDependencies` re-run clean. Worth
keeping `~/cleanup.sh` from leaving the SPM artifacts cache half-populated.)

**Adversarial fan-out result:** inertness *provably inert* (all 11 non-sync prod files are strict
no-ops with the flag off; ports flag-gate to `NoopSyncPort`); identity *clean* (no residual
cross-account TOCTOU); immutability *clean* for the receiver/resolver/disk-read/hash paths;
submission surface verified — `CURRENT_PROJECT_VERSION` still 21 (bump not prematurely committed),
`MARKETING_VERSION` 1.0.0, Mac flag set, and the Info.plist slimming migrated every build-21 usage
string + `ITSAppUsesNonExemptEncryption=NO` to pbxproj `INFOPLIST_KEY_*` (no shipping data lost).

### Two NEW flag-ON findings (sync-GA, NOT build-22 blockers — sync ships dark)
Both are flag-ON-only (Release hard-OFF → no effect on the shipping build), both are genuinely
novel (distinct from the 3 deferrals above and from each other), and both live on the live
CloudKit push/rebind seams that **no unit test exercises** (only the 2-device manual test does).
Recommendation: **batch into sync-GA hardening with real device validation, do not fix blind now.**

- **NEW-1 (rebind drops the pending push queue) — MED, more-probable:** `SyncCoordinator.rebind`
  (`SyncCoordinator.swift:136-160`) unconditionally `port.unbind()` (which does
  `pending.removeAll()`, `CloudKitSyncPort.swift:109-115`) + rebuilds a fresh port on EVERY
  `.CKAccountChanged` — including the *spurious same-account* notifications Apple posts on iCloud
  re-auth / token refresh. A queued-but-unpushed outbound edit (made while offline/slow) is silently
  dropped: `seedIfNeeded` is one-shot (`seededAt`), nothing re-enqueues local versions on a
  same-account rebind, so the edit's push is permanently lost (local copy survives → cross-device
  push DIVERGENCE, not local data loss). Fix-F closed the same-*port* transient-unbind window; this
  is the uncovered cross-*port* window. Fix: gate the rebuild on an actual identity change (same
  UID + unchanged iCloud token ⇒ keep the existing port + its queue), or hand off the un-pushed
  `pending` snapshot to the new port.
- **NEW-2 (save-policy clobbers a concurrently-finalized record) — HIGH-when-active, low-probability,
  permanent:** `CKCloudDatabase.save` (`CloudKitBackends.swift:52-102`) protects immutability by
  fetch-then-`if locked==1 return`, but then saves with `savePolicy: .changedKeys`, which force-writes
  the changed keys *without* change-tag conflict detection (only `.ifServerRecordUnchanged` checks the
  tag). In the fetch→save window (temp-file write + network round-trip) another device can finalize the
  same `versionId`; this device's save then overwrites `status=Draft/locked=0` onto the now-finalized
  server record. It does NOT self-heal (the finalized-local device never re-pushes an immutable record;
  the resolver only protects the local copy), so a fresh device later pulls the finalized inspection as
  an editable DRAFT — the immutability/tamper-evidence invariant is broken cloud-side. Fix: switch to
  `.ifServerRecordUnchanged` and on `CKError.serverRecordChanged` re-fetch + re-run the locked-guard in
  a small bounded retry loop (the reused record already carries the fetched change tag).

### Build-22 submission-surface items (owner: Nick — external / decision, no code defect)
- **CRITICAL portal dependency (must do before archiving build 22):** entitlements now declare the
  `iCloud.com.nexgenspec.app` CloudKit container + CloudKit service + `aps-environment`. With Automatic
  signing these are embedded at archive time *regardless of the flag*, so the App ID must have Push +
  iCloud(CloudKit) capabilities enabled and the container must EXIST in the Developer portal, or the
  Archive fails to sign / ASC rejects the upload. (The container does NOT need its schema in Prod for
  build 22 to *function* — sync is dark — but it must EXIST for the signed entitlement to validate.)
  Verify with a test Archive + Validate in Organizer.
- **Unused-capability decision (Guideline 2.5.4):** `UIBackgroundModes: remote-notification` +
  `aps-environment` ship with zero backing code (APNs deferred, D-0184). Strip for build 22 (safest for
  public review) vs keep as forward-prep — Nick/submission call. `aps-environment=development` is
  normally rewritten to `production` by the distribution export under Automatic signing; confirm in the
  exported `.app` entitlements.
- **Version bump:** `CURRENT_PROJECT_VERSION 21 → 22` (MARKETING_VERSION stays 1.0.0) is **staged in the
  working tree, not committed** — committed only on Nick's explicit P7 go, together with opening the PR.
