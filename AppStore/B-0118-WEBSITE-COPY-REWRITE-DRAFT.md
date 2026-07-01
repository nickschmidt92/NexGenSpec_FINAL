# B-0118 — Website + App Store copy rewrite (DRAFT for attorney review)

**Status: DRAFT — engineering-authored. Do NOT publish until an attorney reviews the
substance.** Companion to `AppStore/SYNC_DISCLOSURE_DRAFT.md` (which holds the full
data-handling rationale + the privacy/terms/ASC-label guidance). This doc adds the
**literal, ready-to-paste blocks** for the specific public surfaces the build-26 audit
(2026-06-26) found still denying sync, plus the `marketing/ASO.md` finding that the prior
draft did not cover.

**Why this is a submit-blocker (B-0118):** NexGenSpec 1.0.0 ships CloudKit cross-device
sync **default-ON**. Every public surface that says "local-only / never leaves your
device / does not sync" is now FALSE → Apple Guideline 5.1 auto-reject + privacy
misrepresentation exposure. The **in-app** Privacy/Terms/Settings and the **App Store
metadata** (`AppStore/metadata.txt`, `LISTING.md`, `REVIEW_NOTES.md`,
`PRIVACY_LABEL_CLICKTHROUGH.md`) were already corrected and are consistent. The surfaces
below are the remaining gaps.

**Canonical wording source** (already shipped, keep all four consistent): in-app
`NexGenSpec/Sync/SyncFeature.swift` (`dataLocationClause`, `multiDeviceTermsClause`,
`multiDeviceLegalClause`) and `NexGenSpec/LegalScreens.swift`.

**The one-paragraph truth the copy must reflect:** *With iCloud Sync on (the default),
inspections — the record, the report PDF, and thumbnails — sync across the Apple devices
on the user's iCloud account, through the user's **private** iCloud (Apple CloudKit),
**only** to their iCloud; NexGenSpec never receives, stores, or can access them, and there
is no NexGenSpec server in the path. A **Local-Only** mode keeps inspections on one
device. Sync is not a backup (deletions propagate).* Full-resolution original media
(photos/videos/LiDAR) is on-demand, not part of the default sync set.

---

## SURFACE 1 — `marketing/website-pages/support.html` : visible FAQ (lines ~338–341) — **HIGH**

### BEFORE (stale — flat "No"):
```html
<summary>Do my inspections sync between iPads?</summary>
<div class="answer">
  <p>No. NexGenSpec is intentionally local-first &mdash; your inspection content never leaves your device. Inspections live on the iPad or iPhone they were created on.</p>
  <p>To move an inspection between your own devices: open the inspection, tap the share icon, choose <strong>Save to Files</strong>, then transfer the resulting .zip via AirDrop, iCloud Drive, or any file-sharing method you prefer.</p>
</div>
```

### AFTER (ready to paste):
```html
<summary>Do my inspections sync between my devices?</summary>
<div class="answer">
  <p>Yes. With iCloud Sync on (the default), NexGenSpec syncs your inspections &mdash; the inspection record, the report PDF, and thumbnails &mdash; across the Apple devices signed in to your iCloud account, through your <strong>private</strong> iCloud (Apple CloudKit). The data goes only to your iCloud account: <strong>NexGenSpec never receives, stores, or can access it</strong>, and there is no NexGenSpec server in the path.</p>
  <p>Prefer to keep everything on a single device? Turn on <strong>Local-Only mode</strong> in Settings. Note that sync is not a backup &mdash; deleting an inspection removes it from your other devices too, so keep your own backups.</p>
  <p>To move a full inspection package (PDF + photos + LiDAR scans) intentionally, open the inspection, tap the share icon, and choose <strong>Save to Files</strong>.</p>
</div>
```

---

## SURFACE 2 — `support.html` : FAQPage JSON-LD structured data (lines ~63–70) — **HIGH**

This is machine-readable and indexed by search engines; it must match Surface 1.

### BEFORE (stale):
```json
{
  "@type": "Question",
  "name": "Do my inspections sync between iPads?",
  "acceptedAnswer": {
    "@type": "Answer",
    "text": "No. NexGenSpec is local-first. Inspections live on the device they were created on. To move an inspection between your own devices, use the Files-app export from within the inspection."
  }
},
```

### AFTER (ready to paste):
```json
{
  "@type": "Question",
  "name": "Do my inspections sync between my devices?",
  "acceptedAnswer": {
    "@type": "Answer",
    "text": "Yes. With iCloud Sync on (the default), NexGenSpec syncs your inspections (the inspection record, the report PDF, and thumbnails) across the Apple devices on your iCloud account, through your private iCloud (Apple CloudKit). The data goes only to your iCloud account; NexGenSpec never receives, stores, or can access it. Prefer one device? Turn on Local-Only mode in Settings. Sync is not a backup: deleting an inspection removes it from your other devices too."
  }
},
```

---

## SURFACE 3 — `support.html` : "Account & Privacy" paragraph (line ~386) — **MEDIUM**

Keep the TRUE "no NexGenSpec server" claim; add the iCloud-sync clause.

### BEFORE (stale):
```html
<p>NexGenSpec is local-first and stores all inspection content on your device. We do not host your reports, photos, or client information on our servers. See the <a href="privacy.html">Privacy Policy</a> for the full data-handling story and the <a href="terms.html">Terms of Service</a> for usage terms.</p>
```

### AFTER (ready to paste):
```html
<p>With iCloud Sync on (the default), NexGenSpec syncs your inspections across the Apple devices on your private iCloud account (Apple CloudKit) &mdash; the data goes only to your iCloud, and <strong>NexGenSpec never hosts, receives, or can access your reports, photos, or client information on any server</strong>. Turn on <strong>Local-Only mode</strong> in Settings to keep inspections on a single device. See the <a href="privacy.html">Privacy Policy</a> for the full data-handling story and the <a href="terms.html">Terms of Service</a> for usage terms.</p>
```

---

## SURFACE 4 — `support.html` : "works offline" FAQ (line ~379) — **LOW (implication only)**

"entirely on-device" reads as a no-sync claim. Keep the offline truth, drop the implication.

### BEFORE:
```html
<p>Yes. Inspections are created, captured, finalized, and exported entirely on-device. Internet is only required for sign-in (one time per device), subscription validation, the weather stamp at the start of an inspection, and sending the final PDF via email.</p>
```

### AFTER (ready to paste):
```html
<p>Yes. Inspections are created, captured, finalized, and exported on your device, with no internet connection required for that work. Internet is used for sign-in, subscription validation, the weather stamp at the start of an inspection, sending the final PDF via email, and &mdash; when iCloud Sync is on &mdash; syncing your inspections to your other devices through your private iCloud.</p>
```

---

## SURFACE 5 — `support.html` : "How do I back up my inspections?" FAQ (lines ~367–371) — **LOW (clarify)**

Not a sync denial (it correctly describes iCloud *Backup*, which is separate from CloudKit
*sync*), but for accuracy add the "sync is not a backup" nuance so the two aren't confused.
**Suggested addition** to the end of the answer:

```html
  <p>iCloud Sync (on by default) keeps your inspections on your other Apple devices, but it is <strong>not</strong> a backup &mdash; deleting an inspection removes it everywhere it synced. Keep iCloud Backup on, or save periodic <strong>Save to Files</strong> archives, for a true backup.</p>
```

---

## SURFACE 6 — `marketing/ASO.md` : App Store "Description" PRIVACY-FIRST bullet (line ~82) — **MEDIUM**

`ASO.md` is headed **"Ready to paste into App Store Connect."** If pasted instead of the
already-corrected `AppStore/metadata.txt`, the false claim reaches Apple. The bullet also
violates the explicit guardrail in `AppStore/LISTING.md` forbidding "never leaves your
device" wording.

### BEFORE (stale):
```
• PRIVACY-FIRST
  Your inspection data lives on your device. Calendar access is optional. No photos, notes, or reports leave your iPad unless you explicitly export them.
```

### AFTER (ready to paste):
```
• PRIVATE BY DESIGN
  Your inspections sync across your own Apple devices through your private iCloud account — only to your iCloud, never to a NexGenSpec server. Prefer one device? Turn on Local-Only mode. Calendar access is optional.
```

### Two adjacent `ASO.md` lines to reconcile while you're in the file (not sync-denials, but inaccurate):
- **Line ~91** (Requirements): *"...syncing in and viewing reports works on iPhone"* — vague/garbled. Suggest: *"iPhone compatible — report creation is iPad-optimized, and your inspections sync to iPhone through your private iCloud for viewing."*
- **Lines ~78–79** (ENCRYPTED BACKUPS): *"**Admins** can create passphrase-encrypted backups…"* — there is no admin/team role (the app is single-user per iCloud login; multi-user is a rejected scope). Suggest dropping "Admins": *"Create passphrase-encrypted backups of every inspection, ready to restore on a new device."*

---

## SURFACE 7 — `nexgenspec.com/privacy.html` and `/terms.html` — **NOT IN THE REPO / UNVERIFIED**

These live pages could not be audited (only `support.html` is in `marketing/website-pages/`).
The App Store submission links the Privacy Policy URL, so they almost certainly carry the
same stale "never leaves your device" wording and **must** be confirmed + rewritten before
flipping the ASC App Privacy label. Use the corrected clauses already drafted in
`AppStore/SYNC_DISCLOSURE_DRAFT.md` §1 (Privacy) and §2 (Terms) verbatim — restated here
for convenience:

- **privacy.html** — replace the "no sync / local-only" section with §1's
  **"Cross-device sync (your iCloud)"** paragraph.
- **terms.html** — replace the "Multi-device note" with §2's corrected note.

---

## Attorney review checklist (substance)

1. Client (homeowner) PII + e-signatures now replicate into the **inspector's own** private
   iCloud. Confirm the controller/processor framing: inspector = data controller,
   NexGenSpec = no-access tool provider.
2. ASC App Privacy label: does routing the user's own content through **their own** private
   iCloud count as "shared with a third party (Apple)"? Default to the more-disclosing
   answer unless advised (see `SYNC_DISCLOSURE_DRAFT.md` §4).
3. "Sync is not a backup / deletions propagate" — confirm this disclaimer is sufficient to
   limit data-loss liability.
4. Confirm consistency across all surfaces before publish: in-app (done) ↔ website
   privacy/terms/support ↔ ASC metadata (done) ↔ ASC App Privacy label.

## After sign-off (mechanical, gated on attorney approval)
1. Apply Surfaces 1–6 to `support.html` / `ASO.md` (I can do this on request).
2. Publish updated `privacy.html` / `terms.html` / `support.html` to nexgenspec.com LIVE.
3. Flip the ASC App Privacy label per `SYNC_DISCLOSURE_DRAFT.md` §4.
4. Close B-0118 only when all are LIVE and consistent at submission.
