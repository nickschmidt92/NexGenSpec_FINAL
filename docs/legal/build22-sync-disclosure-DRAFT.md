# B-0118 — CloudKit Sync Disclosure (DRAFT for attorney review)

> **STATUS: DRAFT. Not legal advice. Not for publication as-is.** Authoritative legal
> wording is the attorney track. This document gives (1) the *technical truth* of what
> data moves where when sync is enabled, (2) machine-readable FAQ markup, and (3) a
> suggested App Privacy mapping — so the attorney can write accurate copy and Nick can
> answer App Store Connect correctly.
>
> **CRITICAL TIMING — read first.** Build 22 ships sync **dark**:
> `SyncFeature.isEnabled` is hard-OFF in Release (it's a DEBUG-only dev toggle). A
> build-22 App Store release behaves exactly like build 21 — **no inspection data
> leaves the device.** So the live privacy/terms pages remain accurate for build 22 and
> must **NOT** be changed to claim syncing until the release that flips sync ON in
> Release (sync GA). Publish this rewrite *with that release*, not before. Doing it now
> would misdescribe the shipped app.

---

## 1. Data-flow truth (when sync is ON) — read from the build-22 code

- **Model:** local-first. The on-device per-user store stays the source of truth and is
  never wiped by sync. CloudKit is a one-account **mirror/observer**.
- **Destination:** the user's **own private iCloud database** (Apple CloudKit private
  DB), in a per-account custom zone, encrypted at rest in the user's iCloud.
  **NexGenSpec LLC never receives, hosts, or can read inspection content.**
- **Always synced:** inspection version JSON (current + finalized snapshots), report PDF,
  integrity hash, cover-photo thumbnail — the small legal record.
- **On-demand only (off by default):** original photos, video, LiDAR/USDZ, full-res
  signatures (per-device "Sync original media over iCloud" toggle).
- **Never synced:** device-local diagnostics/audit logs, deletion receipts.
- **Identity:** app login is a Firebase account; iCloud is a *separate* identity. The app
  stores only an opaque, irreversible hash of the iCloud user record — **never the Apple
  ID**. If the device's iCloud account changes, sync pauses ("refuse-and-isolate") and
  never mixes data between accounts.
- **Opt-in + escape hatches:** OFF by default even when available; user turns it on. A
  "Local-Only" mode forces it fully off. The app never *requires* iCloud.
- **Deletion:** account deletion tears down the binding and best-effort deletes the
  user's CloudKit zone (no residual PII in iCloud). Sync is **not a backup** — a deletion
  propagates across the user's own devices.

## 2. Copy deltas (DRAFT — publish at GA, attorney to finalize)

| Page | Current (true while sync is dark) | GA replacement (DRAFT) |
|---|---|---|
| `privacy.html` on-device clause | "All data remains on your device…" | "NexGenSpec LLC still never stores your inspection content. If you enable iCloud Sync, your inspections sync across **your own** devices through **your private iCloud account** (Apple CloudKit) — only to your iCloud, never to our servers." |
| `terms.html` Multi-device note | "…do NOT sync between devices." | "With iCloud Sync on, inspections sync across your own devices via your private iCloud account; NexGenSpec never receives them. Sync is not a backup — keep your own backups; deletions sync between your devices." |
| `support.html` FAQ | (add) | See §3. |

The in-app mirrors of these strings are already flag-gated in code
(`SyncFeature.multiDeviceLegalClause` / `multiDeviceTermsClause` /
`multiDeviceBackupSubtitle` / `localFirstBannerText`) so the binary stays truthful in
both flag states. Keep the website wording in lockstep with those.

## 3. support.html FAQ + FAQPage JSON-LD (DRAFT)

- **Does NexGenSpec store my inspections on its servers?** No. NexGenSpec LLC never
  stores or can read your inspection content. Sync off → on device only; sync on → your
  own private iCloud, not our servers.
- **How do my inspections sync?** If you enable iCloud Sync, across your own devices on
  the same iCloud account, via Apple's CloudKit private database. Opt-in; can be turned
  off or set to Local-Only anytime.
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
    {"@type":"Question","name":"Does NexGenSpec store my inspections on its servers?","acceptedAnswer":{"@type":"Answer","text":"No. NexGenSpec LLC never stores or can read your inspection content. With iCloud Sync off, everything stays on your device; with it on, data syncs through your own private iCloud account, not our servers."}},
    {"@type":"Question","name":"How do my inspections sync between my devices?","acceptedAnswer":{"@type":"Answer","text":"If you enable iCloud Sync, inspections sync across your own devices signed into the same iCloud account via Apple's CloudKit private database. It is opt-in and can be turned off or set to Local-Only at any time."}},
    {"@type":"Question","name":"Is iCloud Sync a backup?","acceptedAnswer":{"@type":"Answer","text":"No. Sync mirrors the same data across your devices, so a deletion syncs too. Keep an independent backup of finalized inspections."}},
    {"@type":"Question","name":"Do my clients' details go to NexGenSpec or third parties?","acceptedAnswer":{"@type":"Answer","text":"No. Client content lives on your device and, if sync is on, in your private iCloud. NexGenSpec never receives it. You remain the data controller for client information."}}
  ]
}
</script>
```

## 4. App Store Connect — App Privacy questionnaire (suggested mapping)

> Decide WITH the attorney whether build 22 (sync dark) needs any change at all. Two
> views: (a) Release behavior = no-data-leaves, so answers are unchanged from build 21;
> (b) the binary contains the dormant capability + CloudKit entitlement, so some disclose
> proactively. Compliance judgment, not a code fact.

At sync GA (or if disclosing now):
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
- This draft (facts + JSON-LD + ASC mapping): in-repo starting point. **Attorney
  finalizes prose. Nick answers App Store Connect.**
- Publish website changes **with the sync-GA release**, not for build 22.
