# B-0118 — CloudKit Sync Disclosure (DRAFT for attorney review)

> ## ⚠️ SUPERSEDED — DO NOT USE AS CURRENT TRUTH
> **This is the OLD "sync dark" draft, written when build 22 shipped iCloud sync
> OFF in Release. That is no longer the live model.** As of build 26 (1.0.0),
> **iCloud Sync ships ON by default**: a user's inspections (inspection record,
> report PDF, thumbnails) sync across THAT user's OWN Apple devices through their
> PRIVATE iCloud account (Apple CloudKit). The data goes only to the user's own
> iCloud — NexGenSpec never receives, stores, hosts, or can access it (no
> NexGenSpec server/backend). Users can turn on **Local-Only mode** to keep
> inspections on a single device. iCloud Sync is **not a backup**, and
> **deletions sync** across the user's devices. The "CRITICAL TIMING" note below
> (sync dark / "no inspection data leaves the device" / publish only at a future
> GA) is therefore **FALSE for the shipping app and must NOT be relied on.**
>
> **Canonical, current source of truth:** `AppStore/SYNC_DISCLOSURE_DRAFT.md`.
> Use that for all copy and the App Privacy label. The data-flow facts in §1
> below remain broadly accurate, but read them as describing the **now-default-ON**
> behavior, not a dormant capability.

> **STATUS: DRAFT. Not legal advice. Not for publication as-is.** Authoritative legal
> wording is the attorney track. This document gives (1) the *technical truth* of what
> data moves where when sync is enabled, (2) machine-readable FAQ markup, and (3) a
> suggested App Privacy mapping — so the attorney can write accurate copy and Nick can
> answer App Store Connect correctly.
>
> **~~CRITICAL TIMING — read first.~~ (SUPERSEDED — see the box above.)** This
> paragraph described build 22 shipping sync **dark** (`SyncFeature.isEnabled`
> hard-OFF in Release, behaving like build 21 with no inspection data leaving the
> device) and said the live privacy/terms pages must NOT claim syncing until a
> future sync-GA release. **That timing no longer holds: sync is ON by default in
> the shipping build**, so the privacy/terms/label copy MUST disclose iCloud sync
> now. Retained only for history.

---

## 1. Data-flow truth (when sync is ON) — read from the build-22 code

- **Model:** local-first. The on-device per-user store stays the source of truth and is
  never wiped by sync. CloudKit is a one-account **mirror/observer**.
- **Destination:** the user's **own private iCloud database** (Apple CloudKit private
  DB), in a per-account custom zone, encrypted at rest in the user's iCloud.
  **NexGenSpec never receives, hosts, or can read inspection content.**
- **Always synced:** inspection version JSON (current + finalized snapshots), report PDF,
  integrity hash, cover-photo thumbnail — the small legal record.
- **On-demand only (off by default):** original photos, video, LiDAR/USDZ, full-res
  signatures (per-device "Sync original media over iCloud" toggle).
- **Never synced:** device-local diagnostics/audit logs, deletion receipts.
- **Identity:** app login is a Firebase account; iCloud is a *separate* identity. The app
  stores only an opaque, irreversible hash of the iCloud user record — **never the Apple
  ID**. If the device's iCloud account changes, sync pauses ("refuse-and-isolate") and
  never mixes data between accounts.
- **Default + escape hatches:** ON by default for a signed-in user with iCloud available
  (this is the live model as of build 26 — the older "OFF by default" wording was the
  sync-dark plan and no longer holds). A "Local-Only" mode forces it fully off. The app
  never *requires* iCloud.
- **Deletion:** account deletion tears down the binding and best-effort deletes the
  user's CloudKit zone (no residual PII in iCloud). Sync is **not a backup** — a deletion
  propagates across the user's own devices.

## 2. Copy deltas (DRAFT — sync is now LIVE/default-ON; attorney to finalize)

> The "Current (true while sync is dark)" column below is the OLD, now-FALSE copy —
> it must NOT remain on the live pages. The right-hand column is the wording that is
> accurate today; treat it as the required replacement, not a future GA option.

| Page | OLD copy — now FALSE (was "true while sync is dark") | Required replacement (DRAFT) |
|---|---|---|
| `privacy.html` on-device clause | "All data remains on your device…" | "NexGenSpec still never stores your inspection content. If you enable iCloud Sync, your inspections sync across **your own** devices through **your private iCloud account** (Apple CloudKit) — only to your iCloud, never to our servers." |
| `terms.html` Multi-device note | "…do NOT sync between devices." | "With iCloud Sync on, inspections sync across your own devices via your private iCloud account; NexGenSpec never receives them. Sync is not a backup — keep your own backups; deletions sync between your devices." |
| `support.html` FAQ | (add) | See §3. |

The in-app mirrors of these strings are already flag-gated in code
(`SyncFeature.multiDeviceLegalClause` / `multiDeviceTermsClause` /
`multiDeviceBackupSubtitle` / `localFirstBannerText`) so the binary stays truthful in
both flag states. Keep the website wording in lockstep with those.

## 3. support.html FAQ + FAQPage JSON-LD (DRAFT)

- **Does NexGenSpec store my inspections on its servers?** No. NexGenSpec never
  stores or can read your inspection content. Sync off → on device only; sync on → your
  own private iCloud, not our servers.
- **How do my inspections sync?** With iCloud Sync on (the default), across your own
  devices on the same iCloud account, via Apple's CloudKit private database. You can turn
  it off or set Local-Only anytime.
- **Is iCloud Sync a backup?** No — sync mirrors data across devices, so a deletion syncs
  too. Keep an independent backup of finalized inspections.
- **Do my clients' details go to NexGenSpec or third parties?** No. Client content stays
  on your device and, with sync on, in your private iCloud. You remain the data controller.

```html
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "FAQPage",
  "mainEntity": [
    {"@type":"Question","name":"Does NexGenSpec store my inspections on its servers?","acceptedAnswer":{"@type":"Answer","text":"No. NexGenSpec never stores or can read your inspection content. With iCloud Sync off, everything stays on your device; with it on, data syncs through your own private iCloud account, not our servers."}},
    {"@type":"Question","name":"How do my inspections sync between my devices?","acceptedAnswer":{"@type":"Answer","text":"With iCloud Sync on (the default), inspections sync across your own devices signed into the same iCloud account via Apple's CloudKit private database. You can turn it off or set Local-Only at any time."}},
    {"@type":"Question","name":"Is iCloud Sync a backup?","acceptedAnswer":{"@type":"Answer","text":"No. Sync mirrors the same data across your devices, so a deletion syncs too. Keep an independent backup of finalized inspections."}},
    {"@type":"Question","name":"Do my clients' details go to NexGenSpec or third parties?","acceptedAnswer":{"@type":"Answer","text":"No. Client content lives on your device and, if sync is on, in your private iCloud. NexGenSpec never receives it. You remain the data controller for client information."}}
  ]
}
</script>
```

## 4. App Store Connect — App Privacy questionnaire (suggested mapping)

> SUPERSEDED framing: the old "build 22 sync dark / no-data-leaves / answers unchanged
> from build 21" debate no longer applies — sync is ON by default in the shipping build,
> so the label MUST disclose iCloud sync. The mapping below is the disclosing answer.
> Final wording is a compliance judgment to confirm with the attorney; see the canonical
> `AppStore/SYNC_DISCLOSURE_DRAFT.md` §4.

With sync ON by default (the live model):
- CloudKit private DB = the **user's own iCloud**, not a third-party SDK and generally
  **not "data collected by the developer"** under Apple's guidance.
- Collected for auth: email + (Sign in with Apple) user id → *App Functionality / Account
  Management*, linked to identity, **not tracking**.
- Crash data (Crashlytics): *Diagnostics → Crash Data*, not linked, not tracking.
- Coarse location (weather / address autofill): *App Functionality*, not stored by you,
  not linked, not tracking.
- **No tracking; no third-party ad identifiers.**
- Inspection content / client PII / photos: **not collected by the developer** (stays on
  device or in the user's private iCloud).

## 5. Ownership
- This draft (facts + JSON-LD + ASC mapping): SUPERSEDED in-repo starting point.
  Canonical copy is `AppStore/SYNC_DISCLOSURE_DRAFT.md`. **Attorney finalizes prose.
  Nick answers App Store Connect.**
- The old "publish website changes only at sync-GA, not for build 22" instruction is
  VOID: sync is live/default-ON as of build 26, so the privacy/terms/support pages and
  the App Privacy label MUST disclose iCloud sync now — they must not keep the old
  local-only/no-sync wording.
