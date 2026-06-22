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
