# Sync disclosure — DRAFT for attorney review (B-0118)

**Status: DRAFT.** This is engineering-authored first-pass copy to disclose the
cross-device iCloud sync that ships in NexGenSpec 1.0.0. **Have an attorney review the
substance before publishing** — it concerns replication of homeowner PII and
e-signatures into the inspector's iCloud. This gates the App Store submission (B-0118):
the live website pages + the App Store Connect privacy label currently say
"local-only / no sync," which becomes FALSE the moment a sync build ships (Apple
Guideline 5.1 auto-reject + misrepresentation exposure).

## The data-handling reality (what the copy must accurately reflect)

- Inspection records sync **across the user's own devices** (iPhone, iPad, Mac) through
  **the user's private iCloud account** (Apple CloudKit *private database*). The data goes
  **only to the user's iCloud** — **NexGenSpec never receives, stores, or can access
  it** server-side. There is no NexGenSpec server in the path.
- **What syncs:** the inspection record (JSON), report PDFs, thumbnails, and LiDAR floor
  plans (plan images, room dimensions, scan metadata). Full-resolution original media
  (photos, videos, and 3D room-scan/USDZ files) stays on the device where it was captured
  and does **not** sync in this version; on-demand media sync is a planned later release.
  (Matches build 29 behavior — light-asset sync slice, D-0203/T-01623.)
- **Per-device status flags (by design):** archive status and invoice sent/paid status are
  stored per-device — archiving an inspection on one device leaves it active on the
  others. (T-01612 addendum 2026-07-03.)
- **Encryption:** CloudKit private-database data is encrypted in transit and at rest by
  Apple; identity uses Sign in with Apple.
- **Roles:** the inspector is the **data controller**; NexGenSpec is a **no-access tool
  provider** (it cannot read the synced records).
- **On by default, with an opt-out:** sync is on by default for a signed-in user with
  iCloud available; a **"Local-Only" mode** keeps inspections on a single device for
  NDA/privacy jobs.
- **Deletions propagate** and do not silently come back: deleting an inspection on one
  device removes it from the others (a deletion log prevents a stale device from
  resurrecting it).
- **Sync is not a backup:** because deletions propagate, the user should keep their own
  backups; losing all devices/iCloud can lose data NexGenSpec cannot recover.

## 1) Privacy policy — replace the "no sync / local-only" section with:

> **Cross-device sync (your iCloud).** When iCloud Sync is on (the default), your
> inspections — the inspection record, report PDFs, thumbnails, and LiDAR floor plans —
> sync across the Apple devices signed in to your iCloud account, through Apple's iCloud
> (CloudKit) in your **private** database. This data goes **only to your iCloud account.
> NexGenSpec never receives, stores, or has access to it**, and there is no NexGenSpec
> server in the path. Apple encrypts this data in transit and at rest. Full-resolution
> photos, videos, and 3D room-scan files stay on the device where they were captured and
> do not sync; archive and invoice status are stored per-device.
> Because inspection records can contain your client's personal information and
> e-signatures, that information is replicated into **your** iCloud; you are responsible
> for it as the inspector. To keep inspections on a single device instead, turn on
> **Local-Only mode** in Settings. Sync is not a backup: deletions propagate across your
> devices, so keep your own backups.

## 2) Terms of use — replace the "Multi-device note":

> **Multi-device note.** With iCloud Sync on (the default), your inspections sync across
> your own devices through your private iCloud account; NexGenSpec never receives or
> stores them and cannot access them. With Local-Only mode on, inspections stay on the
> device they were created on. You are responsible for the client information and
> e-signatures contained in your inspections, including as they replicate into your
> iCloud.

## 3) Support FAQ — update the entry (and its FAQPage JSON-LD):

The live FAQ hard-codes **"Do my inspections sync? No."** Change to:

> **Q: Do my inspections sync between my devices?**
> A: Yes. By default, NexGenSpec syncs your inspections — the inspection record, report
> PDFs, thumbnails, and LiDAR floor plans — across the Apple devices on your iCloud
> account, through your **private** iCloud — NexGenSpec never receives or stores them.
> Full-resolution photos, videos, and 3D scan files stay on the device where they were
> captured (use **Save to Files** to move a complete inspection package), and
> archive/invoice status is tracked per-device. Prefer to keep everything on one device?
> Turn on **Local-Only mode** in Settings. Note that sync is not a backup: deleting an
> inspection removes it from your other devices too.

**Also update the `FAQPage` JSON-LD** on the same page so the structured-data answer
matches (it currently encodes the "No" answer).

## 4) App Store Connect — App Privacy label

The local-first label must change to disclose iCloud sync. Per data type:
- **Other User Content** (the inspection content, incl. client PII + e-signatures):
  collected, **Linked** to identity, App Functionality. Now **"shared with third
  parties" = Apple iCloud** as the sync transport (the user's own private DB).
- **Photos/Videos:** Linked, App Functionality (unchanged — captured and stored on-device; not synced).
- **Email Address:** Linked (Sign in with Apple), App Functionality.
- **Precise Location:** Not Linked, App Functionality (weather + address auto-fill — unchanged).
- **Crash Data:** Not Linked.
- **Tracking = No** (unchanged).
- Privacy Policy URL stays `https://nexgenspec.com/privacy.html` (after it's updated).

> Attorney/Apple-policy question to confirm: whether routing the user's own content
> through **their own** private iCloud counts as "sharing with a third party" for the
> label, or is treated as the user's own storage. Default to the more-disclosing answer
> unless advised otherwise.

## 5) App Store description / keywords

Remove any "all data stays on-device" / "100% on-device" / "no cloud" claims from the
listing (`AppStore/LISTING.md`) and replace with accurate "syncs across your own devices
through your private iCloud; NexGenSpec never stores your data" language.

## 6) In-app Terms / Legal copy — remaining sites needing the flag-aware pass

Most in-app sync copy is already flag-aware (`SyncFeature.multiDeviceLegalClause` /
`multiDeviceTermsClause` / `multiDeviceBackupSubtitle` / `localFirstBannerText` /
`dataLocationClause`, all gated on `SyncFeature.isEnabled`). Code review found these
HARD-CODED "device-only" statements that contradict default-ON sync and were NOT yet
gated — attorney should confirm the corrected wording, then they should be gated like
the clauses above:
- `NexGenSpec/TermsAndConditionsView.swift:178` — "stores inspection records on the Inspector's device **only** … cannot recover them if the device is lost…"
- `NexGenSpec/TermsAndConditionsView.swift:349, :482` — "stores inspection records on the Inspector's device."
- `NexGenSpec/TermsAndConditionsView.swift:355` — "NexGenSpec is local-first. … stored privately on your iPhone or iPad…"
- `NexGenSpec/LegalScreens.swift` §8 retention list — the "data will be permanently lost if…" enumeration still reads device-only; reconcile with sync-on (the lead sentence is now `SyncFeature.dataLocationClause`, fixed in code).

Lines that remain TRUE under sync (NO change needed): any "NexGenSpec does not receive
copies / has no server-side database" — CloudKit is the user's *own* private iCloud, not
NexGenSpec's servers.

---

*This doc covers the OUT-of-repo website + ASC label PLUS the in-app Terms punch-list
above. The functional Local-Only opt-out toggle now exists in Settings → iCloud Sync.*
