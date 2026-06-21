# App Review Notes — paste into ASC

App Review Information field in ASC. Reduces back-and-forth with the
reviewer by pre-answering the three questions most likely to come up
for an inspection-app submission with auto-renewing subscriptions.

---

## Demo Credentials

Email: `appreview@nexgenspec.com`
Password: **‹not stored in repo — paste directly into App Store Connect ›**

> Do NOT commit the demo password to git. Enter it straight into the App
> Store Connect → App Review Information field, and keep the live copy in
> the password manager. The previous password was committed and has been
> rotated; never paste a real password back into this file.

This account is pre-flagged with full Pro entitlement so the reviewer can
test every paywalled feature without going through StoreKit. To test the
free-trial gate: any signed-in account starts with 3 free full
inspections (counted by `SubscriptionManager.freeInspectionsUsed` against `freeInspectionLimit = 3`, plus DeviceCheck).

To test the paywall purchase flow, the reviewer should use a sandbox
Apple ID — both subscriptions (`com.nexgenspec.annualv1` at $449/yr and
`com.nexgenspec.monthlyv1` at $49/mo) are configured in App Store Connect
and ready for sandbox purchase.

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
enabled (NSFileProtectionCompleteUnlessOpen). The only network usage is:

- **Firebase Auth** — for sign-in (email/password or Sign in with Apple)
- **Firebase Crashlytics** — anonymized crash reports
- **Open-Meteo** (open-meteo.com) — inspection weather stamp; the device
  sends only coarsened coordinates (~1 km, no account, no identifiers)
- **Apple location services (CLGeocoder)** — optional property-address
  auto-fill reverse-geocodes a precise (~100 m) coordinate via Apple; the
  coordinate goes to Apple only, is not retained, and the resulting address is
  stored as on-device user content. (This is why the App Privacy label declares
  Precise Location.)
- **StoreKit** — for subscription management (Apple-provided)

No analytics SDK is linked. No advertising. No third-party tracking.
NSPrivacyTracking is declared `false` in PrivacyInfo.xcprivacy.

---

## Account Deletion

Per Guideline 5.1.1(v), users can fully delete their account from within
the app: Settings → Account → Delete Account. The flow requires
reauthentication (password or Apple ID), then deletes the Firebase
account, wipes all local inspection data, and generates a deletion
receipt saved to the user's Files app for their records.

---

## Contact for Review Questions

`contact@nexgenspec.com`
Response time: same business day (US Mountain time).
