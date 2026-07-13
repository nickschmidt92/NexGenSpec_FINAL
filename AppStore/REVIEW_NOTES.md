# App Review Notes — paste into ASC

App Review Information field in ASC. Reduces back-and-forth with the
reviewer by pre-answering the three questions most likely to come up
for an inspection-app submission with auto-renewing subscriptions.

---

## Subscription Value (Guideline 3.1.2(a))

NexGenSpec Pro is an ongoing professional-software service: it provides
unlimited generation of branded, client-ready inspection reports across
iPhone, iPad, and Mac, supported by a continually updated app and live
inspection-day weather data fetched fresh for each report. The free tier
(3 full inspections) lets any reviewer or user evaluate the complete
workflow before subscribing, and Pro delivers continuous, repeated value
to working inspectors who generate reports on every job — it is not a
one-time feature unlock.

---

## Demo Credentials

Email: `appreview@nexgenspec.com`
Password: **‹not stored in repo — paste directly into App Store Connect ›**

> Do NOT commit the demo password to git. Enter it straight into the App
> Store Connect → App Review Information field, and keep the live copy in
> the password manager. The previous password was committed and has been
> rotated; never paste a real password back into this file.

> **First-run setup:** On first launch the app requires entering an
> Inspector / Full name. Enter something generic such as `App Reviewer` —
> this name (not the sign-in email) is what prints on generated reports, so
> using it keeps the demo email off the PDFs.

This account is pre-flagged with full Pro entitlement so the reviewer can
test every paywalled feature without going through StoreKit. To test the
free-trial gate: any signed-in account starts with 3 free full
inspections (counted by `SubscriptionManager.freeInspectionsUsed` against `freeInspectionLimit = 3`, plus DeviceCheck).

**Important — this demo account can never reach the paywall.** Because
Pro is pre-granted, no upgrade prompt or purchase gate will ever fire on
it (upgrade entry points are hidden for pre-entitled accounts). In a
prior submission the reviewer was unable to locate the in-app purchases
(Guideline 2.1) for exactly this reason. To locate and test the IAPs,
please create a fresh account (Sign Up with any email address): new
accounts start on the free tier, and the paywall presents from the
Dashboard upgrade prompt, from Settings, or automatically when starting
a new inspection once the 3 free inspections are used.

To test the paywall purchase flow, the reviewer should use a sandbox
Apple ID — both subscriptions (`com.nexgenspec.annualv1` at $449/yr and
`com.nexgenspec.monthlyv1` at $49/mo) are configured in App Store Connect
and ready for sandbox purchase.

---

## Marquee Features — where to find them

**LiDAR room capture.** Requires a LiDAR-equipped device (iPad Pro or a Pro
iPhone). The "Scan Room (LiDAR)" control is intentionally HIDDEN on
non-LiDAR devices and on Mac. On a supported device: open an inspection →
tap into a section → the "Scan Room (LiDAR)" button is at the bottom of that
section's item list. Each scan generates a top-down PER-ROOM floor plan
(spatial reference, not a measured architectural drawing) plus a 3D (USDZ)
model; the floor plan renders in the report's "Room Scans (LiDAR)" page
with the room's dimensions. Rooms are scanned and rendered one at a time —
the listing claims per-room plans only.

---

## Notes on Implementation Choices

A few design decisions that reviewers occasionally flag — pre-clarifying
here saves a round trip.

**DeviceCheck for trial-abuse prevention.**
After a user exhausts their 3 free inspections, the device is marked via
Apple's DeviceCheck framework. This prevents Delete App + Reinstall from
granting a fresh 3-pack. The check is fire-and-forget, non-blocking, and
does not collect or transmit user-identifying information — only an
opaque per-device bit owned by NexGenSpec. Implementation:
`NexGenSpec/Services/DeviceCheckTrialGate.swift`.

**7-day offline grace period for Pro entitlement.**
A user with an active Pro subscription who goes offline retains Pro
features for up to 7 days before the app re-validates entitlement with
StoreKit. This is intentional StoreKit best practice — losing
subscription benefits the moment a user enters an elevator or boards a
flight would be a poor user experience. After 7 days offline, or at the
first online check, real-time entitlement is restored. Implementation:
`NexGenSpec/Services/SubscriptionManager.swift:194-239`.

**"Mark Invoice as Paid" is record-keeping only.**
The Invoice & Send screen includes a "Mark Invoice as Paid" toggle.
NexGenSpec does NOT process payments — this is purely a record-keeping
aid for the inspector. The inspector collects payment from the client
outside the app via whatever method they choose. The screen includes an
explicit disclaimer to that effect. No financial information is
collected, transmitted, or stored.

---

## Privacy & Data

NexGenSpec stores inspection data on-device with iOS Data Protection
enabled (NSFileProtectionCompleteUnlessOpen). With iCloud Sync ON (the
default), a user's inspections — the inspection record, report PDF,
thumbnails, and LiDAR floor plans / scan data — sync across THAT user's own
Apple devices through their PRIVATE iCloud account (Apple CloudKit private
database). Full-resolution photos, videos, and 3D scan (USDZ) files do not
sync and remain only on the device that captured them. The data goes
only to the user's own iCloud; NexGenSpec never receives, stores, hosts,
or has access to it (there is no NexGenSpec server/backend). Users can turn
on Local-Only mode to keep inspections on a single device. iCloud Sync is
not a backup, and deletions sync across the user's devices. The network
usage is:

- **Apple iCloud / CloudKit (private DB)** — cross-device sync of the
  user's own inspections within their own iCloud account; never to a
  NexGenSpec server (Local-Only mode disables this)
- **Firebase Auth** — for sign-in (email/password or Sign in with Apple)
- **Firebase Crashlytics** — anonymized crash reports
- **Open-Meteo** (open-meteo.com) — inspection weather stamp; the device
  sends only coarsened coordinates (~1 km, no account, no identifiers)
- **Apple location services (CLGeocoder)** — optional property-address
  auto-fill reverse-geocodes a coordinate via Apple; the coordinate goes to
  Apple only, is not retained, and the resulting address is stored as
  on-device user content. (The App Privacy label declares **Coarse
  Location**: the only location data the app retains is the ~1 km-coarsened
  weather coordinate; the geocoding coordinate is transient.)
- **StoreKit** — for subscription management (Apple-provided)

No analytics SDK is linked. No advertising. No third-party tracking.
NSPrivacyTracking is declared `false` in PrivacyInfo.xcprivacy.

---

## Account Deletion

Per Guideline 5.1.1(v), users can fully delete their account from within
the app: Settings → Account → Delete Account. The flow requires
reauthentication (password or Apple ID), then deletes the Firebase
account, wipes all local inspection data, and generates a deletion
receipt the user can save (via the system share sheet — to Files, Mail,
etc.) for their records.

---

## Contact for Review Questions

`contact@nexgenspec.com`
Response time: same business day (US Mountain time).
